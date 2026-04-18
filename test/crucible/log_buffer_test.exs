defmodule Crucible.LogBufferTest do
  use ExUnit.Case, async: true

  alias Crucible.LogBuffer

  setup do
    name = :"log_buffer_test_#{:rand.uniform(100_000)}"
    {:ok, pid} = LogBuffer.start_link(name: name, max_entries: 10)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{name: name}
  end

  test "recent returns empty list initially", %{name: name} do
    assert LogBuffer.recent(10, name) == []
  end

  test "push and recent round-trip", %{name: name} do
    LogBuffer.push(%{level: :info, message: "hello"}, name)
    LogBuffer.push(%{level: :debug, message: "world"}, name)
    # Give cast time to process
    :timer.sleep(10)

    entries = LogBuffer.recent(10, name)
    assert length(entries) == 2
    assert hd(entries).message == "hello"
    assert List.last(entries).message == "world"
  end

  test "respects max_entries cap", %{name: name} do
    for i <- 1..15 do
      LogBuffer.push(%{level: :info, message: "msg-#{i}"}, name)
    end

    :timer.sleep(20)

    entries = LogBuffer.recent(20, name)
    assert length(entries) == 10
    # Should have entries 6-15 (oldest 5 dropped)
    assert hd(entries).message == "msg-6"
    assert List.last(entries).message == "msg-15"
  end

  test "recent respects n parameter", %{name: name} do
    for i <- 1..5 do
      LogBuffer.push(%{level: :info, message: "msg-#{i}"}, name)
    end

    :timer.sleep(10)

    entries = LogBuffer.recent(3, name)
    assert length(entries) == 3
    assert hd(entries).message == "msg-3"
  end
end
