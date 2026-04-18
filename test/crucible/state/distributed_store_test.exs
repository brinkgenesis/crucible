defmodule Crucible.State.DistributedStoreTest do
  use ExUnit.Case, async: false

  alias Crucible.State.DistributedStore
  alias Crucible.State.Schema

  @moduletag :mnesia

  setup_all do
    # Use a test-specific Mnesia directory to avoid polluting dev data
    mnesia_dir = Path.join(System.tmp_dir!(), "mnesia_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(mnesia_dir)

    :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(mnesia_dir))
    :mnesia.create_schema([node()])
    :mnesia.start()
    Schema.create_tables()
    Schema.wait_for_tables(5_000)

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)
    end)

    :ok
  end

  setup do
    # Clear all tables between tests
    for table <- Schema.tables() do
      :mnesia.clear_table(table)
    end

    :ok
  end

  # --- Schema ---

  describe "schema creation" do
    test "tables exist with correct attributes" do
      for table <- Schema.tables() do
        info = :mnesia.table_info(table, :attributes)
        assert info == Schema.attributes(table)
      end
    end

    test "tables use disc_copies on local node" do
      for table <- Schema.tables() do
        copies = :mnesia.table_info(table, :disc_copies)
        assert node() in copies
      end
    end

    test "tables are set type" do
      for table <- Schema.tables() do
        assert :mnesia.table_info(table, :type) == :set
      end
    end
  end

  # --- Runs CRUD ---

  describe "runs CRUD" do
    test "put_run/2 and get_run/1" do
      attrs = %{
        workflow_type: "deploy",
        status: :pending,
        phases: [],
        workspace_path: "/tmp/ws",
        branch: "main",
        plan_note: nil,
        plan_summary: "test plan",
        budget_usd: 10.0,
        client_id: "client-1",
        started_at: nil,
        completed_at: nil,
        error: nil,
        data: %{}
      }

      assert :ok = DistributedStore.put_run("run-1", attrs)
      assert {:ok, run} = DistributedStore.get_run("run-1")
      assert run.id == "run-1"
      assert run.workflow_type == "deploy"
      assert run.status == :pending
      assert run.branch == "main"
      assert %DateTime{} = run.updated_at
      assert run.version == 1
    end

    test "get_run/1 returns not_found for missing key" do
      assert {:error, :not_found} = DistributedStore.get_run("nonexistent")
    end

    test "list_runs/0 returns all stored runs" do
      for i <- 1..3 do
        DistributedStore.put_run("run-#{i}", %{status: :pending, workflow_type: "test"})
      end

      runs = DistributedStore.list_runs()
      assert length(runs) == 3
      ids = Enum.map(runs, & &1.id) |> Enum.sort()
      assert ids == ["run-1", "run-2", "run-3"]
    end

    test "list_runs/0 returns empty list when no runs exist" do
      assert DistributedStore.list_runs() == []
    end

    test "delete_run/1 removes the run" do
      DistributedStore.put_run("run-del", %{status: :pending})
      assert {:ok, _} = DistributedStore.get_run("run-del")

      assert :ok = DistributedStore.delete_run("run-del")
      assert {:error, :not_found} = DistributedStore.get_run("run-del")
    end

    test "put_run/2 overwrites existing run" do
      DistributedStore.put_run("run-ow", %{status: :pending, workflow_type: "v1"})
      DistributedStore.put_run("run-ow", %{status: :running, workflow_type: "v2"})

      assert {:ok, run} = DistributedStore.get_run("run-ow")
      assert run.status == :running
      assert run.workflow_type == "v2"
    end
  end

  # --- Phases CRUD ---

  describe "phases CRUD" do
    test "put_phase/2 and get_phase/1" do
      attrs = %{
        run_id: "run-1",
        name: "build",
        type: :api,
        status: :pending,
        prompt: "Build the thing",
        phase_index: 0,
        data: %{}
      }

      assert :ok = DistributedStore.put_phase("phase-1", attrs)
      assert {:ok, phase} = DistributedStore.get_phase("phase-1")
      assert phase.id == "phase-1"
      assert phase.run_id == "run-1"
      assert phase.name == "build"
      assert phase.version == 1
    end

    test "get_phase/1 returns not_found for missing key" do
      assert {:error, :not_found} = DistributedStore.get_phase("no-phase")
    end

    test "list_phases/0 returns all phases" do
      DistributedStore.put_phase("p-1", %{run_id: "r1", name: "plan"})
      DistributedStore.put_phase("p-2", %{run_id: "r1", name: "execute"})

      phases = DistributedStore.list_phases()
      assert length(phases) == 2
    end

    test "delete_phase/1 removes the phase" do
      DistributedStore.put_phase("p-del", %{run_id: "r1", name: "test"})
      assert :ok = DistributedStore.delete_phase("p-del")
      assert {:error, :not_found} = DistributedStore.get_phase("p-del")
    end
  end

  # --- Results CRUD ---

  describe "results CRUD" do
    test "put_result/2 and get_result/1" do
      attrs = %{
        run_id: "run-1",
        phase_id: "phase-1",
        exit_code: 0,
        output: "success",
        data: %{duration_ms: 1234}
      }

      assert :ok = DistributedStore.put_result("result-1", attrs)
      assert {:ok, result} = DistributedStore.get_result("result-1")
      assert result.id == "result-1"
      assert result.exit_code == 0
      assert result.output == "success"
      assert result.version == 1
    end

    test "get_result/1 returns not_found for missing key" do
      assert {:error, :not_found} = DistributedStore.get_result("no-result")
    end

    test "list_results/0 returns all results" do
      DistributedStore.put_result("r-1", %{run_id: "r1", phase_id: "p1", exit_code: 0})
      DistributedStore.put_result("r-2", %{run_id: "r1", phase_id: "p2", exit_code: 1})

      results = DistributedStore.list_results()
      assert length(results) == 2
    end

    test "delete_result/1 removes the result" do
      DistributedStore.put_result("r-del", %{run_id: "r1", phase_id: "p1", exit_code: 0})
      assert :ok = DistributedStore.delete_result("r-del")
      assert {:error, :not_found} = DistributedStore.get_result("r-del")
    end
  end

  # --- Circuit Breakers CRUD ---

  describe "circuit breakers CRUD" do
    test "put_circuit_breaker/2 and get_circuit_breaker/1" do
      attrs = %{
        state: :closed,
        consecutive_failures: 0,
        opened_at: nil,
        cooldown_ms: 30_000,
        last_failed_at: nil
      }

      assert :ok = DistributedStore.put_circuit_breaker("deploy-wf", attrs)
      assert {:ok, cb} = DistributedStore.get_circuit_breaker("deploy-wf")
      assert cb.workflow_name == "deploy-wf"
      assert cb.state == :closed
      assert cb.consecutive_failures == 0
      assert cb.version == 1
    end

    test "get_circuit_breaker/1 returns not_found for missing key" do
      assert {:error, :not_found} = DistributedStore.get_circuit_breaker("missing-wf")
    end

    test "update circuit breaker state" do
      DistributedStore.put_circuit_breaker("wf-update", %{
        state: :closed,
        consecutive_failures: 0,
        cooldown_ms: 30_000
      })

      DistributedStore.put_circuit_breaker("wf-update", %{
        state: :open,
        consecutive_failures: 3,
        opened_at: DateTime.utc_now(),
        cooldown_ms: 30_000,
        last_failed_at: DateTime.utc_now()
      })

      assert {:ok, cb} = DistributedStore.get_circuit_breaker("wf-update")
      assert cb.state == :open
      assert cb.consecutive_failures == 3
    end

    test "list_circuit_breakers/0 returns all breakers" do
      DistributedStore.put_circuit_breaker("wf-a", %{state: :closed})
      DistributedStore.put_circuit_breaker("wf-b", %{state: :open})

      breakers = DistributedStore.list_circuit_breakers()
      assert length(breakers) == 2
    end

    test "delete_circuit_breaker/1 removes the breaker" do
      DistributedStore.put_circuit_breaker("wf-del", %{state: :closed})
      assert :ok = DistributedStore.delete_circuit_breaker("wf-del")
      assert {:error, :not_found} = DistributedStore.get_circuit_breaker("wf-del")
    end
  end

  # --- scan_pending_runs ---

  describe "scan_pending_runs/0" do
    test "returns only pending and running runs" do
      DistributedStore.put_run("pending-1", %{status: :pending, workflow_type: "test"})
      DistributedStore.put_run("running-1", %{status: :running, workflow_type: "test"})
      DistributedStore.put_run("completed-1", %{status: :completed, workflow_type: "test"})
      DistributedStore.put_run("failed-1", %{status: :failed, workflow_type: "test"})

      pending = DistributedStore.scan_pending_runs()
      ids = Enum.map(pending, & &1.id) |> Enum.sort()

      assert length(pending) == 2
      assert ids == ["pending-1", "running-1"]
    end

    test "returns empty list when no pending/running runs" do
      DistributedStore.put_run("done-1", %{status: :completed})
      assert DistributedStore.scan_pending_runs() == []
    end

    test "returns empty list when no runs exist" do
      assert DistributedStore.scan_pending_runs() == []
    end
  end

  # --- Conflict Resolution ---

  describe "conflict resolution (last-write-wins)" do
    test "later write overwrites earlier write" do
      DistributedStore.put_run("conflict-1", %{status: :pending, workflow_type: "v1"})
      Process.sleep(10)
      DistributedStore.put_run("conflict-1", %{status: :running, workflow_type: "v2"})

      assert {:ok, run} = DistributedStore.get_run("conflict-1")
      assert run.status == :running
      assert run.workflow_type == "v2"
    end

    test "first write stores correct version" do
      DistributedStore.put_run("ver-1", %{status: :pending, version: 0})
      assert {:ok, run} = DistributedStore.get_run("ver-1")
      assert run.version == 1
    end

    test "concurrent writes from multiple processes all succeed" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            DistributedStore.put_run("race-1", %{
              status: :running,
              workflow_type: "writer-#{i}"
            })
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :ok))

      assert {:ok, run} = DistributedStore.get_run("race-1")
      assert run.id == "race-1"
    end
  end

  # --- Transaction Atomicity ---

  describe "transaction atomicity" do
    test "failed transaction does not leave partial data" do
      DistributedStore.put_run("atomic-1", %{status: :pending})

      result =
        :mnesia.transaction(fn ->
          :mnesia.read(:distributed_runs, "atomic-1")
          :mnesia.abort(:intentional_abort)
        end)

      assert {:aborted, :intentional_abort} = result

      # Original data should be intact
      assert {:ok, run} = DistributedStore.get_run("atomic-1")
      assert run.status == :pending
    end

    test "writes within a transaction are all-or-nothing" do
      result =
        :mnesia.transaction(fn ->
          now = DateTime.utc_now()

          run_attrs = Schema.attributes(:distributed_runs)

          run_values =
            Enum.map(run_attrs, fn
              :id -> "txn-run"
              :status -> :pending
              :updated_at -> now
              :version -> 1
              _name -> nil
            end)

          run_record = List.to_tuple([:distributed_runs | run_values])
          :mnesia.write(run_record)

          phase_attrs = Schema.attributes(:distributed_phases)

          phase_values =
            Enum.map(phase_attrs, fn
              :id -> "txn-phase"
              :run_id -> "txn-run"
              :name -> "plan"
              :updated_at -> now
              :version -> 1
              _name -> nil
            end)

          phase_record = List.to_tuple([:distributed_phases | phase_values])
          :mnesia.write(phase_record)
        end)

      assert {:atomic, :ok} = result
      assert {:ok, _} = DistributedStore.get_run("txn-run")
      assert {:ok, _} = DistributedStore.get_phase("txn-phase")
    end

    test "aborted multi-table transaction writes nothing" do
      result =
        :mnesia.transaction(fn ->
          now = DateTime.utc_now()
          run_attrs = Schema.attributes(:distributed_runs)

          run_values =
            Enum.map(run_attrs, fn
              :id -> "abort-run"
              :status -> :pending
              :updated_at -> now
              :version -> 1
              _name -> nil
            end)

          run_record = List.to_tuple([:distributed_runs | run_values])
          :mnesia.write(run_record)

          :mnesia.abort(:rollback_test)
        end)

      assert {:aborted, :rollback_test} = result
      assert {:error, :not_found} = DistributedStore.get_run("abort-run")
    end
  end

  # --- Graceful Degradation ---

  describe "graceful degradation" do
    test "list functions return empty list on table error" do
      result =
        :mnesia.transaction(fn ->
          :mnesia.foldl(fn record, acc -> [record | acc] end, [], :nonexistent_table)
        end)

      assert {:aborted, _reason} = result
    end

    test "scan_pending_runs returns empty list when table is empty" do
      assert DistributedStore.scan_pending_runs() == []
    end

    test "delete on nonexistent key returns ok" do
      assert :ok = DistributedStore.delete_run("never-existed")
      assert :ok = DistributedStore.delete_phase("never-existed")
      assert :ok = DistributedStore.delete_result("never-existed")
      assert :ok = DistributedStore.delete_circuit_breaker("never-existed")
    end
  end
end
