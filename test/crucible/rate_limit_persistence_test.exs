defmodule Crucible.RateLimitPersistenceTest do
  use ExUnit.Case, async: false

  alias Crucible.RateLimitPersistence

  @dets_path Path.join(System.tmp_dir!(), "rl_persist_test_#{:rand.uniform(100_000)}.dets")
  @test_dets_name :rate_limit_dets_test

  setup do
    File.rm(@dets_path)

    # Ensure ETS table exists and is clean
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ets.delete_all_objects(:rate_limit)

    on_exit(fn ->
      try do
        :dets.close(@test_dets_name)
      catch
        _, _ -> :ok
      end

      File.rm(@dets_path)
    end)

    :ok
  end

  test "snapshots ETS to DETS and restores on startup" do
    now = System.monotonic_time(:millisecond)
    :ets.insert(:rate_limit, {{"192.168.1.1", :read}, now})
    :ets.insert(:rate_limit, {{"192.168.1.1", :read}, now - 10_000})
    :ets.insert(:rate_limit, {{"10.0.0.1", :write}, now - 5_000})
    assert :ets.info(:rate_limit, :size) == 3

    {:ok, pid} =
      RateLimitPersistence.start_link(
        dets_path: @dets_path,
        name: :test_rl_persistence,
        dets_name: @test_dets_name
      )

    send(pid, :snapshot)
    Process.sleep(50)

    # Stop BEFORE clearing ETS — terminate will snapshot current (3-entry) state
    GenServer.stop(pid)

    # NOW clear ETS to simulate a fresh restart
    :ets.delete_all_objects(:rate_limit)
    assert :ets.info(:rate_limit, :size) == 0

    # Restart — should seed from DETS
    {:ok, pid2} =
      RateLimitPersistence.start_link(
        dets_path: @dets_path,
        name: :test_rl_persistence,
        dets_name: @test_dets_name
      )

    assert :ets.info(:rate_limit, :size) == 3
    GenServer.stop(pid2)
  end

  test "prunes expired entries on seed" do
    now = System.monotonic_time(:millisecond)

    dets_path = String.to_charlist(@dets_path)
    {:ok, _} = :dets.open_file(@test_dets_name, file: dets_path, type: :duplicate_bag)
    :dets.insert(@test_dets_name, {{"old_ip", :read}, now - 120_000})
    :dets.insert(@test_dets_name, {{"new_ip", :read}, now - 10_000})
    :dets.close(@test_dets_name)

    {:ok, pid} =
      RateLimitPersistence.start_link(
        dets_path: @dets_path,
        name: :test_rl_persistence,
        dets_name: @test_dets_name
      )

    assert :ets.info(:rate_limit, :size) == 1
    GenServer.stop(pid)
  end
end
