defmodule Crucible.Load.BottleneckTest do
  @moduledoc """
  Measures GenServer response times under load to catch performance regressions.

  Tests verify that GenServer call latency stays under 100ms (p99) even with
  50+ concurrent callers hammering the same process. This isolates GenServer
  mailbox throughput from adapter execution time — tasks run in separate
  processes, so the GenServer should always respond promptly to :get_info,
  :get_status, and :get_run_state calls.

  Tagged with :load for CI isolation — run with: mix test --only load
  """

  use ExUnit.Case, async: false

  @moduletag :load

  alias Crucible.Orchestrator.RunServer
  alias Crucible.Orchestrator.RunSupervisor

  @p99_threshold_us 100_000

  # --- Helpers ---

  defp make_run(id) do
    %Crucible.Types.Run{
      id: id,
      workflow_type: "load-test",
      status: :pending,
      phases: []
    }
  end

  defp start_run_server(run_id, opts \\ []) do
    run = make_run(run_id)
    max_retries = Keyword.get(opts, :max_retries, 5)

    {:ok, pid} =
      RunSupervisor.start_run(
        run: run,
        run_opts: [],
        max_retries: max_retries,
        orchestrator_pid: self()
      )

    # Let init + handle_continue complete so the server is in a callable state
    Process.sleep(20)
    pid
  end

  defp measure_call_us(fun) do
    {elapsed_us, result} = :timer.tc(fun)
    {elapsed_us, result}
  end

  defp percentile(sorted_list, p) when p >= 0 and p <= 100 do
    n = length(sorted_list)
    rank = max(0, ceil(n * p / 100) - 1)
    Enum.at(sorted_list, rank)
  end

  defp concurrent_timed_calls(pid, call_fn, concurrency) do
    tasks =
      for _ <- 1..concurrency do
        Task.async(fn ->
          {us, _result} = measure_call_us(fn -> call_fn.(pid) end)
          us
        end)
      end

    Task.await_many(tasks, 10_000)
  end

  # --- Tests ---

  describe "single RunServer under normal load" do
    @tag :load
    test "get_info responds under p99 threshold with sequential calls" do
      run_id = "bottleneck-seq-#{:rand.uniform(100_000)}"
      pid = start_run_server(run_id)

      timings =
        for _ <- 1..100 do
          {us, _result} = measure_call_us(fn -> RunServer.get_info(run_id) end)
          us
        end

      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us exceeds #{@p99_threshold_us}us threshold " <>
               "(median=#{median}us, min=#{Enum.min(sorted)}us, max=#{Enum.max(sorted)}us)"

      # Clean up
      if Process.alive?(pid), do: RunServer.cancel(run_id)
    end
  end

  describe "RunServer under concurrent load (50+ callers)" do
    @tag :load
    test "get_info responds under p99 threshold with 50 concurrent callers" do
      run_id = "bottleneck-conc50-#{:rand.uniform(100_000)}"
      pid = start_run_server(run_id)

      timings = concurrent_timed_calls(pid, fn _pid -> RunServer.get_info(run_id) end, 50)

      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us exceeds #{@p99_threshold_us}us threshold " <>
               "with 50 concurrent callers (median=#{median}us)"

      if Process.alive?(pid), do: RunServer.cancel(run_id)
    end

    @tag :load
    test "get_status responds under p99 threshold with 75 concurrent callers" do
      run_id = "bottleneck-conc75-#{:rand.uniform(100_000)}"
      pid = start_run_server(run_id)

      timings = concurrent_timed_calls(pid, fn _pid -> RunServer.get_status(run_id) end, 75)

      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us exceeds #{@p99_threshold_us}us threshold " <>
               "with 75 concurrent callers (median=#{median}us)"

      if Process.alive?(pid), do: RunServer.cancel(run_id)
    end

    @tag :load
    test "get_run_state responds under p99 threshold with 100 concurrent callers" do
      run_id = "bottleneck-conc100-#{:rand.uniform(100_000)}"
      pid = start_run_server(run_id)

      timings = concurrent_timed_calls(pid, fn _pid -> RunServer.get_run_state(run_id) end, 100)

      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us exceeds #{@p99_threshold_us}us threshold " <>
               "with 100 concurrent callers (median=#{median}us)"

      if Process.alive?(pid), do: RunServer.cancel(run_id)
    end
  end

  describe "RunServer during phase transitions" do
    @tag :load
    test "response time stays low during starting -> running transition" do
      run_id = "bottleneck-transition-#{:rand.uniform(100_000)}"
      run = make_run(run_id)

      # Start the server and immediately fire calls to catch the transition window
      {:ok, pid} =
        RunSupervisor.start_run(
          run: run,
          run_opts: [],
          max_retries: 5,
          orchestrator_pid: self()
        )

      # Fire calls immediately — no sleep — to hit the :starting -> :running transition
      timings =
        for _ <- 1..50 do
          {us, _result} = measure_call_us(fn -> RunServer.get_info(run_id) end)
          us
        end

      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us during phase transition exceeds threshold " <>
               "(median=#{median}us, max=#{Enum.max(sorted)}us)"

      if Process.alive?(pid), do: RunServer.cancel(run_id)
    end

    @tag :load
    test "concurrent calls during rapid status changes stay under threshold" do
      run_id = "bottleneck-rapid-#{:rand.uniform(100_000)}"
      pid = start_run_server(run_id)

      # Mix of different call types to simulate realistic load patterns
      tasks =
        for i <- 1..60 do
          Task.async(fn ->
            call_fn =
              case rem(i, 3) do
                0 -> fn -> RunServer.get_info(run_id) end
                1 -> fn -> RunServer.get_status(run_id) end
                2 -> fn -> RunServer.get_run_state(run_id) end
              end

            {us, _result} = measure_call_us(call_fn)
            us
          end)
        end

      timings = Task.await_many(tasks, 10_000)
      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us with mixed concurrent calls exceeds threshold " <>
               "(median=#{median}us)"

      if Process.alive?(pid), do: RunServer.cancel(run_id)
    end
  end

  describe "multiple RunServers under simultaneous load" do
    @tag :load
    test "10 servers each handling 10 concurrent callers stay under threshold" do
      server_count = 10
      callers_per_server = 10

      run_ids =
        for i <- 1..server_count do
          "bottleneck-multi-#{i}-#{:rand.uniform(100_000)}"
        end

      pids = Enum.map(run_ids, fn id -> start_run_server(id) end)

      # Fire concurrent calls across all servers simultaneously
      tasks =
        for run_id <- run_ids, _ <- 1..callers_per_server do
          Task.async(fn ->
            {us, _result} = measure_call_us(fn -> RunServer.get_info(run_id) end)
            us
          end)
        end

      timings = Task.await_many(tasks, 15_000)
      sorted = Enum.sort(timings)
      p99 = percentile(sorted, 99)
      median = percentile(sorted, 50)

      assert p99 < @p99_threshold_us,
             "p99 latency #{p99}us across #{server_count} servers with " <>
               "#{callers_per_server} callers each exceeds threshold (median=#{median}us)"

      # Clean up all servers
      Enum.zip(run_ids, pids)
      |> Enum.each(fn {run_id, pid} ->
        if Process.alive?(pid), do: RunServer.cancel(run_id)
      end)
    end
  end
end
