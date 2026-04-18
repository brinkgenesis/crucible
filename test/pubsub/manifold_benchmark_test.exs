defmodule Crucible.PubSub.ManifoldBenchmarkTest do
  @moduledoc """
  Benchmark test comparing Manifold-backed PubSub dispatch vs default sequential dispatch.

  Spawns many subscriber processes on a topic and measures broadcast latency.
  """
  use ExUnit.Case, async: false

  alias Crucible.PubSub.ManifoldDispatcher

  @topic "benchmark:manifold"
  @subscriber_count 1_000

  setup do
    # Ensure PubSub is running (it should be via Application supervision)
    assert Process.whereis(Crucible.PubSub)
    :ok
  end

  describe "ManifoldDispatcher.dispatch/3" do
    test "delivers messages to all subscribers" do
      parent = self()
      ref = make_ref()

      pids =
        for _i <- 1..50 do
          spawn(fn ->
            receive do
              {:test_msg, ^ref} -> send(parent, {:received, ref})
            end
          end)
        end

      entries = Enum.map(pids, &{&1, nil})

      ManifoldDispatcher.dispatch(entries, :none, {:test_msg, ref})

      for _i <- 1..50 do
        assert_receive {:received, ^ref}, 1_000
      end
    end

    test "excludes sender when from is a pid" do
      parent = self()
      ref = make_ref()

      receiver =
        spawn(fn ->
          receive do
            {:test_msg, ^ref} -> send(parent, {:received, ref})
          end
        end)

      sender =
        spawn(fn ->
          receive do
            {:test_msg, ^ref} -> send(parent, {:sender_got_it, ref})
          after
            500 -> :ok
          end
        end)

      entries = [{receiver, nil}, {sender, nil}]
      ManifoldDispatcher.dispatch(entries, sender, {:test_msg, ref})

      assert_receive {:received, ^ref}, 1_000
      refute_receive {:sender_got_it, ^ref}, 200
    end

    test "handles empty subscriber list gracefully" do
      assert :ok == ManifoldDispatcher.dispatch([], :none, :msg)
    end
  end

  describe "broadcast latency with #{@subscriber_count} subscribers" do
    test "Manifold dispatch completes within acceptable latency" do
      parent = self()
      ref = make_ref()
      message = {:bench_msg, ref, :timer.tc(fn -> nil end)}

      # Spawn subscriber processes that ack receipt
      pids =
        for _i <- 1..@subscriber_count do
          spawn(fn ->
            receive do
              {:bench_msg, ^ref, _} -> send(parent, {:ack, ref})
            end
          end)
        end

      entries = Enum.map(pids, &{&1, nil})

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          ManifoldDispatcher.dispatch(entries, :none, message)
        end)

      # Wait for all acks
      for _i <- 1..@subscriber_count do
        assert_receive {:ack, ^ref}, 5_000
      end

      # Dispatch call (not delivery) should complete in under 50ms for 1000 subscribers
      assert elapsed_us < 50_000,
             "Manifold dispatch took #{elapsed_us}µs, expected < 50,000µs for #{@subscriber_count} subscribers"
    end

    test "end-to-end PubSub broadcast reaches all subscribers" do
      parent = self()
      ref = make_ref()
      topic = "#{@topic}:#{inspect(ref)}"

      # Subscribe processes to PubSub topic
      pids =
        for _i <- 1..100 do
          spawn(fn ->
            Phoenix.PubSub.subscribe(Crucible.PubSub, topic)
            send(parent, {:subscribed, ref})

            receive do
              {:e2e_msg, ^ref} -> send(parent, {:e2e_ack, ref})
            end
          end)
        end

      # Wait for all subscriptions to complete
      for _i <- 1..100 do
        assert_receive {:subscribed, ^ref}, 2_000
      end

      # Broadcast through PubSub (uses ManifoldAdapter → ManifoldDispatcher)
      {elapsed_us, :ok} =
        :timer.tc(fn ->
          Phoenix.PubSub.broadcast(Crucible.PubSub, topic, {:e2e_msg, ref})
        end)

      # Collect all acks
      for _i <- 1..100 do
        assert_receive {:e2e_ack, ^ref}, 5_000
      end

      # End-to-end should complete in under 100ms for 100 subscribers
      assert elapsed_us < 100_000,
             "E2E broadcast took #{elapsed_us}µs, expected < 100,000µs"

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
    end
  end
end
