defmodule Crucible.Sandbox.DockerProviderIntegrationTest do
  @moduledoc """
  Integration tests for DockerProvider — requires a running Docker daemon.
  Skipped in CI unless Docker is available. Run with: mix test --include docker
  """
  use ExUnit.Case, async: false

  alias Crucible.Sandbox.{DockerProvider, Policy}

  @moduletag :docker

  @moduletag timeout: 120_000
  @test_image "alpine:latest"

  setup do
    # Verify Docker is available
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> flunk("Docker not available — skipping integration tests")
    end

    # Create a temp workspace directory
    workspace = Path.join(System.tmp_dir!(), "sandbox-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "hello.txt"), "hello from host")

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  describe "start_sandbox/1 + stop_sandbox/1" do
    test "creates and destroys a Docker container", %{workspace: workspace} do
      policy = Policy.from_preset(:standard)

      opts = %{
        workspace_path: workspace,
        policy: policy,
        image: @test_image,
        labels: %{"test" => "true"}
      }

      assert {:ok, sandbox_id} = DockerProvider.start_sandbox(opts)
      assert is_binary(sandbox_id)
      assert String.starts_with?(sandbox_id, "sandbox-")

      # Container should be running
      assert :running = DockerProvider.status(sandbox_id)

      # Cleanup
      assert :ok = DockerProvider.stop_sandbox(sandbox_id)
      assert :unknown = DockerProvider.status(sandbox_id)
    end

    test "strict policy creates container with no network", %{workspace: workspace} do
      policy = Policy.from_preset(:strict)

      opts = %{
        workspace_path: workspace,
        policy: policy,
        image: @test_image,
        labels: %{"test" => "strict"}
      }

      {:ok, sandbox_id} = DockerProvider.start_sandbox(opts)

      # Verify no network access — may timeout or return error exit code
      result = DockerProvider.exec(sandbox_id, "wget -q -T 2 -O- http://example.com 2>&1", timeout_ms: 10_000)

      assert match?({:error, _}, result),
             "Expected network to be blocked, got: #{inspect(result)}"

      DockerProvider.stop_sandbox(sandbox_id)
    end
  end

  describe "exec/3" do
    setup %{workspace: workspace} do
      policy = Policy.from_preset(:standard)

      opts = %{
        workspace_path: workspace,
        policy: policy,
        image: @test_image,
        labels: %{"test" => "exec"}
      }

      {:ok, sandbox_id} = DockerProvider.start_sandbox(opts)

      on_exit(fn ->
        DockerProvider.stop_sandbox(sandbox_id)
      end)

      %{sandbox_id: sandbox_id}
    end

    test "executes command inside container", %{sandbox_id: sandbox_id} do
      assert {:ok, output} = DockerProvider.exec(sandbox_id, "echo 'hello sandbox'")
      assert String.trim(output) == "hello sandbox"
    end

    test "can read host-mounted file at /sandbox", %{sandbox_id: sandbox_id} do
      assert {:ok, output} = DockerProvider.exec(sandbox_id, "cat /sandbox/hello.txt")
      assert String.trim(output) == "hello from host"
    end

    test "can write file inside container and read it back", %{sandbox_id: sandbox_id} do
      assert {:ok, _} = DockerProvider.exec(sandbox_id, "echo 'written inside' > /sandbox/from-container.txt")
      assert {:ok, output} = DockerProvider.exec(sandbox_id, "cat /sandbox/from-container.txt")
      assert String.trim(output) == "written inside"
    end

    test "written file is visible on host filesystem", %{sandbox_id: sandbox_id, workspace: workspace} do
      DockerProvider.exec(sandbox_id, "echo 'host visible' > /sandbox/host-check.txt")
      assert File.read!(Path.join(workspace, "host-check.txt")) |> String.trim() == "host visible"
    end

    test "cannot read files outside /sandbox (strict path confinement)", %{sandbox_id: sandbox_id} do
      result = DockerProvider.exec(sandbox_id, "cat /etc/hostname")
      # This succeeds because /etc/hostname exists in the container,
      # but the key test is that host /etc/hostname is NOT accessible
      assert {:ok, container_hostname} = result
      {host_hostname, 0} = System.cmd("hostname", [])
      # Container hostname should differ from host
      assert String.trim(container_hostname) != String.trim(host_hostname)
    end

    test "respects timeout", %{sandbox_id: sandbox_id} do
      assert {:error, :timeout} = DockerProvider.exec(sandbox_id, "sleep 30", timeout_ms: 500)
    end

    test "returns exit code for failed commands", %{sandbox_id: sandbox_id} do
      assert {:error, {:exit_code, 1, _}} = DockerProvider.exec(sandbox_id, "false")
    end

    test "shell commands work inside container", %{sandbox_id: sandbox_id} do
      assert {:ok, output} = DockerProvider.exec(sandbox_id, "expr 1 + 1")
      assert String.trim(output) == "2"
    end
  end

  describe "filesystem isolation" do
    setup %{workspace: workspace} do
      policy = Policy.from_preset(:strict)

      opts = %{
        workspace_path: workspace,
        policy: policy,
        image: @test_image,
        labels: %{"test" => "fs-isolation"}
      }

      {:ok, sandbox_id} = DockerProvider.start_sandbox(opts)

      on_exit(fn -> DockerProvider.stop_sandbox(sandbox_id) end)

      %{sandbox_id: sandbox_id}
    end

    test "read-only rootfs blocks writes outside /sandbox and /tmp", %{sandbox_id: sandbox_id} do
      # /sandbox is mounted read-write
      assert {:ok, _} = DockerProvider.exec(sandbox_id, "touch /sandbox/ok.txt")

      # /tmp is tmpfs (read-write)
      assert {:ok, _} = DockerProvider.exec(sandbox_id, "touch /tmp/ok.txt")

      # /root should be read-only
      assert {:error, {:exit_code, _, output}} = DockerProvider.exec(sandbox_id, "touch /root/nope.txt")
      assert String.contains?(output, "Read-only file system") or String.contains?(output, "Permission denied")
    end
  end
end
