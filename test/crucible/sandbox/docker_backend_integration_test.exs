defmodule Crucible.Workspace.DockerBackendIntegrationTest do
  @moduledoc """
  Integration tests for DockerBackend — exercises the Workspace.Backend
  contract through real Docker containers. Run with: mix test --include docker
  """
  use ExUnit.Case, async: false

  alias Crucible.Workspace.DockerBackend
  alias Crucible.Sandbox.{DockerProvider, Policy}

  @moduletag :docker
  @moduletag timeout: 120_000

  @test_image "alpine:latest"

  setup_all do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> flunk("Docker not available")
    end

    workspace = Path.join(System.tmp_dir!(), "backend-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "existing.txt"), "pre-existing content")

    policy = Policy.from_preset(:standard)

    {:ok, sandbox_id} =
      DockerProvider.start_sandbox(%{
        workspace_path: workspace,
        policy: policy,
        image: @test_image,
        labels: %{"test" => "backend"}
      })

    on_exit(fn ->
      DockerProvider.stop_sandbox(sandbox_id)
      File.rm_rf!(workspace)
    end)

    %{sandbox_id: sandbox_id, workspace: workspace}
  end

  setup %{sandbox_id: sandbox_id, workspace: workspace} do
    %{sandbox_id: sandbox_id, workspace: workspace}
  end

  describe "read/2" do
    test "reads file from container", %{sandbox_id: sandbox_id} do
      assert {:ok, content} = DockerBackend.read("existing.txt", container_id: sandbox_id)
      assert String.trim(content) == "pre-existing content"
    end

    test "returns error for missing file", %{sandbox_id: sandbox_id} do
      assert {:error, _} = DockerBackend.read("nonexistent.txt", container_id: sandbox_id)
    end
  end

  describe "write/3" do
    test "writes file inside container", %{sandbox_id: sandbox_id, workspace: workspace} do
      assert :ok =
               DockerBackend.write("new-file.txt", "sandbox content", container_id: sandbox_id)

      # Verify through docker exec
      assert {:ok, output} = DockerProvider.exec(sandbox_id, "cat /sandbox/new-file.txt")
      assert String.trim(output) == "sandbox content"

      # Verify on host
      assert File.read!(Path.join(workspace, "new-file.txt")) |> String.trim() ==
               "sandbox content"
    end

    test "creates parent directories", %{sandbox_id: sandbox_id} do
      assert :ok =
               DockerBackend.write("deep/nested/dir/file.txt", "nested", container_id: sandbox_id)

      assert {:ok, output} =
               DockerProvider.exec(sandbox_id, "cat /sandbox/deep/nested/dir/file.txt")

      assert String.trim(output) == "nested"
    end

    test "handles special characters in content", %{sandbox_id: sandbox_id} do
      content = "line1\nline2\n\"quotes\" and 'singles' and $vars"
      assert :ok = DockerBackend.write("special.txt", content, container_id: sandbox_id)
      assert {:ok, output} = DockerBackend.read("special.txt", container_id: sandbox_id)
      assert output == content
    end
  end

  describe "exec/2" do
    test "executes command and returns output", %{sandbox_id: sandbox_id} do
      assert {:ok, output} = DockerBackend.exec("echo 'exec works'", container_id: sandbox_id)
      assert String.trim(output) == "exec works"
    end

    test "returns error on non-zero exit", %{sandbox_id: sandbox_id} do
      assert {:error, {:exit_code, _, _}} = DockerBackend.exec("exit 1", container_id: sandbox_id)
    end
  end

  describe "list/2" do
    test "lists files in directory", %{sandbox_id: sandbox_id} do
      DockerBackend.write("a.txt", "a", container_id: sandbox_id)
      DockerBackend.write("b.txt", "b", container_id: sandbox_id)

      assert {:ok, files} = DockerBackend.list(".", container_id: sandbox_id)
      assert "a.txt" in files
      assert "b.txt" in files
      assert "existing.txt" in files
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{sandbox_id: sandbox_id} do
      assert DockerBackend.exists?("existing.txt", container_id: sandbox_id)
    end

    test "returns false for missing file", %{sandbox_id: sandbox_id} do
      refute DockerBackend.exists?("nope.txt", container_id: sandbox_id)
    end
  end

  describe "delete/2" do
    test "removes a file", %{sandbox_id: sandbox_id} do
      DockerBackend.write("to-delete.txt", "bye", container_id: sandbox_id)
      assert DockerBackend.exists?("to-delete.txt", container_id: sandbox_id)
      assert :ok = DockerBackend.delete("to-delete.txt", container_id: sandbox_id)
      refute DockerBackend.exists?("to-delete.txt", container_id: sandbox_id)
    end
  end

  describe "mkdir_p/2" do
    test "creates nested directories", %{sandbox_id: sandbox_id} do
      assert :ok = DockerBackend.mkdir_p("a/b/c", container_id: sandbox_id)
      assert {:ok, _} = DockerProvider.exec(sandbox_id, "test -d /sandbox/a/b/c && echo yes")
    end
  end

  describe "path traversal protection" do
    test "resolves ../.. to stay within /sandbox", %{sandbox_id: sandbox_id} do
      # Attempt to read /etc/passwd via traversal
      result = DockerBackend.read("../../etc/passwd", container_id: sandbox_id)
      # Should either fail or read a sandbox-relative path, NOT the real /etc/passwd
      case result do
        {:error, _} -> :ok
        {:ok, content} -> refute String.contains?(content, "root:x:")
      end
    end
  end
end
