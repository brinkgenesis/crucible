defmodule Mix.Tasks.Crucible.DoctorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Convenience alias
  alias Mix.Tasks.Crucible.Doctor

  # ---------------------------------------------------------------------------
  # Human-readable (default) output
  # ---------------------------------------------------------------------------

  describe "run/1 — text output (default)" do
    test "output contains all check names" do
      output = capture_mix_shell(fn -> safe_run([]) end)

      assert output =~ "elixir_version"
      assert output =~ "mix_env"
      assert output =~ "database_config"
      assert output =~ "config_validator"
      assert output =~ "node_name"
    end

    test "output contains status indicators in bracket form" do
      output = capture_mix_shell(fn -> safe_run([]) end)

      # At least one status indicator must appear
      assert output =~ ~r/\[(OK|FAIL|SKIP)\]/
    end

    test "elixir_version check reports the current version" do
      output = capture_mix_shell(fn -> safe_run([]) end)
      assert output =~ System.version()
    end

    test "mix_env check reports the current env" do
      output = capture_mix_shell(fn -> safe_run([]) end)
      assert output =~ to_string(Mix.env())
    end

    test "output has one line per check" do
      output = capture_mix_shell(fn -> safe_run([]) end)
      lines = output |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

      # We have exactly 5 checks defined
      assert length(lines) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # JSON output (--json flag)
  # ---------------------------------------------------------------------------

  describe "run/1 — JSON output (--json)" do
    test "--json flag produces parseable JSON" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      assert {:ok, _decoded} = Jason.decode(output)
    end

    test "JSON has top-level 'status' key with value 'ok' or 'error'" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)
      assert decoded["status"] in ["ok", "error"]
    end

    test "JSON has top-level 'checks' key that is a list" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)
      assert is_list(decoded["checks"])
    end

    test "JSON checks list has exactly 5 entries" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)
      assert length(decoded["checks"]) == 5
    end

    test "each JSON check has 'name', 'status', and 'message' keys" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)

      Enum.each(decoded["checks"], fn check ->
        assert Map.has_key?(check, "name"), "missing 'name': #{inspect(check)}"
        assert Map.has_key?(check, "status"), "missing 'status': #{inspect(check)}"
        assert Map.has_key?(check, "message"), "missing 'message': #{inspect(check)}"
      end)
    end

    test "each check 'status' is one of pass / fail / skip" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)

      Enum.each(decoded["checks"], fn check ->
        assert check["status"] in ["pass", "fail", "skip"],
               "unexpected status '#{check["status"]}' in #{inspect(check)}"
      end)
    end

    test "JSON contains check named 'elixir_version' with current version in message" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)

      ev = Enum.find(decoded["checks"], &(&1["name"] == "elixir_version"))
      assert ev != nil
      assert ev["message"] =~ System.version()
    end

    test "JSON contains check named 'mix_env' reporting the current env" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)

      me = Enum.find(decoded["checks"], &(&1["name"] == "mix_env"))
      assert me != nil
      assert me["message"] =~ to_string(Mix.env())
    end

    test "top-level status is 'error' when any check has status 'fail'" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)

      any_fail = Enum.any?(decoded["checks"], &(&1["status"] == "fail"))
      if any_fail do
        assert decoded["status"] == "error"
      end
    end

    test "top-level status is 'ok' when no check has status 'fail'" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)

      any_fail = Enum.any?(decoded["checks"], &(&1["status"] == "fail"))
      unless any_fail do
        assert decoded["status"] == "ok"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Unit-level check helpers (white-box)
  # ---------------------------------------------------------------------------

  describe "internal check logic" do
    test "elixir_version check passes on this system (Elixir >= 1.15)" do
      # If the test suite runs, Elixir must be >= 1.15 per mix.exs requirement
      output = capture_mix_shell(fn -> safe_run([]) end)
      assert output =~ ~r/\[OK\]\s+elixir_version/
    end

    test "mix_env check always passes" do
      output = capture_mix_shell(fn -> safe_run(["--json"]) end)
      {:ok, decoded} = Jason.decode(output)
      me = Enum.find(decoded["checks"], &(&1["name"] == "mix_env"))
      assert me["status"] == "pass"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Run the task, catching System.halt/1 so the test process isn't killed
  defp safe_run(args) do
    try do
      Doctor.run(args)
    catch
      :exit, _ -> :halted
    end
  end

  # Captures output emitted through Mix.shell().info/1
  defp capture_mix_shell(fun) do
    capture_io(fn ->
      Mix.shell(Mix.Shell.IO)
      fun.()
    end)
  end
end
