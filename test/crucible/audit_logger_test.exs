defmodule Crucible.AuditLoggerTest do
  use ExUnit.Case, async: false

  alias Crucible.AuditLogger

  @log_dir Path.join(System.tmp_dir!(), "audit_logger_test_#{:rand.uniform(100_000)}")
  @log_file Path.join(@log_dir, "audit.jsonl")
  @test_prefix "audit-logger-test"

  setup do
    File.rm_rf!(@log_dir)

    # Start a test instance with a unique name and handler prefix
    # (leave the app-level AuditLogger alone)
    {:ok, pid} =
      AuditLogger.start_link(
        log_dir: @log_dir,
        name: :test_audit_logger,
        handler_prefix: @test_prefix
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(@log_dir)
    end)

    %{pid: pid}
  end

  test "log/2 writes a valid JSON line", %{pid: pid} do
    AuditLogger.log(pid, :test_event, %{ip: "127.0.0.1", path: "/api/test"})
    Process.sleep(50)

    assert File.exists?(@log_file)
    content = File.read!(@log_file)
    {:ok, entry} = Jason.decode(String.trim(content))

    assert entry["event"] == "test_event"
    assert entry["metadata"]["ip"] == "127.0.0.1"
    assert entry["metadata"]["path"] == "/api/test"
    assert Map.has_key?(entry, "timestamp")
  end

  test "telemetry handler fires on auth failure event" do
    :telemetry.execute(
      [:crucible, :auth, :failure],
      %{count: 1},
      %{ip: "10.0.0.1", path: "/api/budget/status", method: "GET"}
    )

    Process.sleep(100)

    assert File.exists?(@log_file)
    lines = @log_file |> File.read!() |> String.trim() |> String.split("\n")
    # May have entries from both app-level and test instance; find ours
    auth_entries =
      lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "auth_failure"))

    assert length(auth_entries) >= 1
    assert hd(auth_entries)["metadata"]["ip"] == "10.0.0.1"
    assert hd(auth_entries)["metadata"]["raw_event"] == "crucible.auth.failure"
  end

  test "telemetry handler fires on rate limit hit" do
    :telemetry.execute(
      [:crucible, :rate_limit, :hit],
      %{count: 1},
      %{ip: "10.0.0.2", path: "/api/runs", method: "GET"}
    )

    Process.sleep(100)

    lines = @log_file |> File.read!() |> String.trim() |> String.split("\n")

    rate_entries =
      lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "rate_limit_hit"))

    assert length(rate_entries) >= 1
  end

  test "multiple log entries are appended", %{pid: pid} do
    AuditLogger.log(pid, :event_a, %{a: 1})
    AuditLogger.log(pid, :event_b, %{b: 2})
    Process.sleep(50)

    lines =
      @log_file
      |> File.read!()
      |> String.trim()
      |> String.split("\n")

    assert length(lines) >= 2
  end
end
