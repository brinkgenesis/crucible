defmodule Crucible.ControlSessionTest do
  use ExUnit.Case, async: false

  alias Crucible.ControlSession

  # App supervisor already starts ControlSession

  describe "list_slots/0" do
    test "returns 6 slots" do
      slots = ControlSession.list_slots()
      assert length(slots) == 6
    end

    test "slots have expected structure" do
      slots = ControlSession.list_slots()

      for slot <- slots do
        assert Map.has_key?(slot, :id)
        assert Map.has_key?(slot, :status)
        assert Map.has_key?(slot, :model)
        assert slot.status in [:empty, :ready, :starting, :stopped, :error]
      end
    end

    test "slots have sequential IDs 1-6" do
      ids = ControlSession.list_slots() |> Enum.map(& &1.id)
      assert ids == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "get_slot/1" do
    test "returns slot by ID" do
      slot = ControlSession.get_slot(1)
      assert slot.id == 1
      assert is_binary(slot.model)
    end

    test "returns slot for any valid ID" do
      for id <- 1..6 do
        slot = ControlSession.get_slot(id)
        assert slot.id == id
      end
    end
  end

  describe "available_models/0" do
    test "returns list of models" do
      models = ControlSession.available_models()
      assert length(models) >= 3
      assert Enum.all?(models, &Map.has_key?(&1, :id))
      assert Enum.all?(models, &Map.has_key?(&1, :name))
    end

    test "includes opus and sonnet" do
      models = ControlSession.available_models()
      ids = Enum.map(models, & &1.id)
      assert "claude-opus-4-6" in ids
      assert "claude-sonnet-4-6" in ids
    end
  end

  describe "list_codebases/0" do
    test "returns list of codebases" do
      codebases = ControlSession.list_codebases()
      assert is_list(codebases)
      # Should at least have the current infra project
      assert length(codebases) >= 1
      assert Enum.all?(codebases, &Map.has_key?(&1, :path))
      assert Enum.all?(codebases, &Map.has_key?(&1, :name))
    end
  end

  describe "spawn_session/3" do
    test "rejects invalid cwd" do
      result = ControlSession.spawn_session(6, "/nonexistent/path/that/doesnt/exist")
      # It returns :ok because spawn is async, but status will be :error after
      assert result == :ok
      # Give async task time to fail
      Process.sleep(500)
      slot = ControlSession.get_slot(6)
      # Error resets to empty now (no stale error panels)
      assert slot.status in [:starting, :error, :empty]
    end

    test "non-existent cwd resolves to error or empty within 15s" do
      result = ControlSession.spawn_session(2, "/tmp/crucible_nonexistent_#{System.unique_integer([:positive])}")
      assert result == :ok

      # Poll up to 15s for the async task to settle
      final_status =
        Enum.reduce_while(1..150, nil, fn _, _acc ->
          slot = ControlSession.get_slot(2)

          if slot.status in [:error, :empty] do
            {:halt, slot.status}
          else
            Process.sleep(100)
            {:cont, slot.status}
          end
        end)

      assert final_status in [:error, :empty],
             "Expected slot 2 to settle to :error or :empty within 15s, got: #{inspect(final_status)}"
    end

    test "cwd that is a regular file (not a directory) produces clean error, not crash" do
      # Create a temp file to use as the bogus cwd
      tmp_file = Path.join(System.tmp_dir!(), "crucible_file_cwd_#{System.unique_integer([:positive])}.txt")
      File.write!(tmp_file, "not a directory")

      on_exit(fn -> File.rm(tmp_file) end)

      result = ControlSession.spawn_session(3, tmp_file)
      assert result == :ok

      # Slot should not crash the GenServer — it should settle cleanly
      final_status =
        Enum.reduce_while(1..150, nil, fn _, _acc ->
          slot = ControlSession.get_slot(3)

          if slot.status in [:error, :empty] do
            {:halt, slot.status}
          else
            Process.sleep(100)
            {:cont, slot.status}
          end
        end)

      assert final_status in [:error, :empty],
             "Expected slot 3 to settle cleanly for file cwd, got: #{inspect(final_status)}"

      # GenServer must still be alive
      assert Process.alive?(Process.whereis(ControlSession))
    end
  end

  describe "stop_session/1" do
    test "stops and resets slot to empty" do
      ControlSession.stop_session(5)
      slot = ControlSession.get_slot(5)
      assert slot.status == :empty
    end

    test "stop_session on already-stopped slot is idempotent — returns :ok, no crash" do
      # Stop once
      assert :ok = ControlSession.stop_session(1)
      assert ControlSession.get_slot(1).status == :empty

      # Stop again — must not crash and must return :ok
      assert :ok = ControlSession.stop_session(1)
      assert ControlSession.get_slot(1).status == :empty

      # GenServer must still be alive
      assert Process.alive?(Process.whereis(ControlSession))
    end

    test "stop_session on out-of-range slot raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        ControlSession.stop_session(99)
      end
    end
  end

  describe "set_model/2" do
    test "updates model on idle slot" do
      ControlSession.set_model(4, "claude-opus-4-6")
      slot = ControlSession.get_slot(4)
      assert slot.model == "claude-opus-4-6"
    end
  end

  describe "capture_output/1" do
    test "returns empty string for empty slot" do
      output = ControlSession.capture_output(3)
      assert output == ""
    end
  end

  describe "send_input/2" do
    test "returns error for non-running slot" do
      assert {:error, :not_running} = ControlSession.send_input(3, "hello")
    end
  end
end
