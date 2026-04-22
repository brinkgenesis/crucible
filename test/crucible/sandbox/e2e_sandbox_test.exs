defmodule Crucible.Sandbox.E2ESandboxTest do
  @moduledoc """
  End-to-end sandbox tests exercising the full Manager → DockerProvider → Backend flow.
  Simulates what happens during a real API workflow phase. Run with: mix test --include docker
  """
  use ExUnit.Case, async: false

  alias Crucible.Sandbox.{Manager, DockerProvider, Policy}
  alias Crucible.Workspace.DockerBackend
  alias Crucible.{FeatureFlags, ExternalCircuitBreaker}

  @moduletag :docker
  @moduletag timeout: 120_000

  setup do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> flunk("Docker not available")
    end

    prev_sandbox = Application.get_env(:crucible, :sandbox)

    Application.put_env(:crucible, :sandbox,
      mode: :docker,
      pool_size: 0,
      image: "alpine:latest",
      policy_preset: :standard,
      network_allowlist: nil
    )

    # Enable sandbox feature flag
    FeatureFlags.enable(:sandbox_enabled)

    {:ok, pid} = Manager.start_link(name: :test_e2e_manager)

    workspace = Path.join(System.tmp_dir!(), "e2e-sandbox-#{:rand.uniform(100_000)}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      FeatureFlags.disable(:sandbox_enabled)
      if prev_sandbox, do: Application.put_env(:crucible, :sandbox, prev_sandbox)
      File.rm_rf!(workspace)
      # Clean up any orphaned containers
      System.cmd("docker", ["ps", "-q", "--filter", "label=managed-by=infra-sandbox-manager"],
        stderr_to_stdout: true
      )
      |> case do
        {ids, 0} ->
          ids
          |> String.split("\n", trim: true)
          |> Enum.each(fn id -> System.cmd("docker", ["rm", "-f", id]) end)

        _ ->
          :ok
      end
    end)

    %{workspace: workspace}
  end

  describe "full lifecycle: acquire → use → release" do
    test "manager acquires Docker sandbox, backend reads/writes, manager releases", %{
      workspace: workspace
    } do
      run_id = "e2e-run-#{:rand.uniform(100_000)}"

      # Step 1: Acquire sandbox through the Manager
      assert {:ok, sandbox_id} =
               Manager.acquire(run_id, [workspace_path: workspace], :test_e2e_manager)

      assert is_binary(sandbox_id)

      status = Manager.status(:test_e2e_manager)
      assert status.active_sandboxes == 1
      assert status.active_runs == 1

      # Step 2: Use DockerBackend to write a file (simulates write_file tool)
      assert :ok =
               DockerBackend.write("result.json", ~s({"status": "ok"}), container_id: sandbox_id)

      # Step 3: Verify file exists in container
      assert DockerBackend.exists?("result.json", container_id: sandbox_id)

      # Step 4: Read it back
      assert {:ok, content} = DockerBackend.read("result.json", container_id: sandbox_id)
      assert String.contains?(content, "ok")

      # Step 5: Verify file landed on host filesystem
      host_path = Path.join(workspace, "result.json")
      assert File.exists?(host_path)
      assert File.read!(host_path) |> String.contains?("ok")

      # Step 6: Execute a command (simulates run_command tool)
      assert {:ok, output} = DockerBackend.exec("ls /sandbox", container_id: sandbox_id)
      assert String.contains?(output, "result.json")

      # Step 7: Release sandbox
      Manager.release_for_run(run_id, :test_e2e_manager)
      Process.sleep(500)

      status = Manager.status(:test_e2e_manager)
      assert status.active_sandboxes == 0
      assert status.active_runs == 0
    end

    test "multiple phases for same run share run tracking", %{workspace: workspace} do
      run_id = "e2e-multi-#{:rand.uniform(100_000)}"

      {:ok, id1} = Manager.acquire(run_id, [workspace_path: workspace], :test_e2e_manager)
      {:ok, id2} = Manager.acquire(run_id, [workspace_path: workspace], :test_e2e_manager)

      status = Manager.status(:test_e2e_manager)
      assert status.active_sandboxes == 2
      assert status.active_runs == 1

      # Release all at once
      Manager.release_for_run(run_id, :test_e2e_manager)
      Process.sleep(500)

      status = Manager.status(:test_e2e_manager)
      assert status.active_sandboxes == 0

      # Both containers should be stopped
      assert :unknown = DockerProvider.status(id1)
      assert :unknown = DockerProvider.status(id2)
    end
  end

  describe "circuit breaker fallback" do
    test "falls back to local provider when Docker circuit is open", %{workspace: workspace} do
      run_id = "e2e-fallback-#{:rand.uniform(100_000)}"

      # Force the Docker circuit breaker open
      Enum.each(1..5, fn _ -> ExternalCircuitBreaker.record_failure(:docker_daemon) end)

      # Acquire should succeed with local provider fallback
      assert {:ok, sandbox_id} =
               Manager.acquire(run_id, [workspace_path: workspace], :test_e2e_manager)

      assert String.starts_with?(sandbox_id, "local-")

      # Cleanup
      Manager.release_for_run(run_id, :test_e2e_manager)

      # Reset circuit breaker for other tests
      ExternalCircuitBreaker.record_success(:docker_daemon)
      ExternalCircuitBreaker.record_success(:docker_daemon)
    end
  end

  describe "strict policy enforcement" do
    test "strict sandbox blocks network access", %{workspace: workspace} do
      prev = Application.get_env(:crucible, :sandbox)
      Application.put_env(:crucible, :sandbox, Keyword.put(prev, :policy_preset, :strict))

      {:ok, pid2} = Manager.start_link(name: :test_strict_manager)

      run_id = "e2e-strict-#{:rand.uniform(100_000)}"

      {:ok, sandbox_id} =
        Manager.acquire(run_id, [workspace_path: workspace], :test_strict_manager)

      # Network should be blocked
      assert {:error, _} =
               DockerProvider.exec(sandbox_id, "wget -q -T 2 -O- http://example.com 2>&1",
                 timeout_ms: 5_000
               )

      Manager.release_for_run(run_id, :test_strict_manager)
      GenServer.stop(pid2)
      Application.put_env(:crucible, :sandbox, prev)
    end
  end

  describe "container isolation" do
    test "file written in container is NOT visible to other containers", %{workspace: workspace} do
      run_id = "e2e-iso-#{:rand.uniform(100_000)}"
      ws2 = Path.join(System.tmp_dir!(), "e2e-iso-ws2-#{:rand.uniform(100_000)}")
      File.mkdir_p!(ws2)

      {:ok, id1} = Manager.acquire(run_id, [workspace_path: workspace], :test_e2e_manager)
      {:ok, id2} = Manager.acquire(run_id, [workspace_path: ws2], :test_e2e_manager)

      # Write in container 1
      DockerBackend.write("secret.txt", "container-1-only", container_id: id1)

      # Container 2 should NOT see it (different workspace mount)
      refute DockerBackend.exists?("secret.txt", container_id: id2)

      Manager.release_for_run(run_id, :test_e2e_manager)
      File.rm_rf!(ws2)
    end
  end
end
