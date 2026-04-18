defmodule Crucible.PrCounterTest do
  use ExUnit.Case, async: true

  alias Crucible.PrCounter

  setup do
    dir = Path.join(System.tmp_dir!(), "pr_counter_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, signals_dir: dir}
  end

  describe "read/2" do
    test "returns empty list when no signals exist", %{signals_dir: dir} do
      assert PrCounter.read("run-1", dir) == []
    end

    test "returns parsed signal data", %{signals_dir: dir} do
      write_signal(dir, "run-1", "coder-backend", "https://github.com/o/r/pull/1")
      write_signal(dir, "run-1", "coder-frontend", "https://github.com/o/r/pull/2")

      signals = PrCounter.read("run-1", dir)
      assert length(signals) == 2
      assert Enum.all?(signals, &is_map/1)
    end

    test "ignores malformed signal files", %{signals_dir: dir} do
      write_signal(dir, "run-2", "coder-backend", "https://github.com/o/r/pull/1")
      File.write!(Path.join(dir, "run-2.pr-bad.json"), "not json")

      assert length(PrCounter.read("run-2", dir)) == 1
    end

    test "only reads signals for the specified run", %{signals_dir: dir} do
      write_signal(dir, "run-a", "coder-backend", "https://github.com/o/r/pull/1")
      write_signal(dir, "run-b", "coder-backend", "https://github.com/o/r/pull/2")

      assert length(PrCounter.read("run-a", dir)) == 1
    end
  end

  describe "urls/2" do
    test "extracts pr_url values", %{signals_dir: dir} do
      write_signal(dir, "run-3", "coder-backend", "https://github.com/o/r/pull/10")
      write_signal(dir, "run-3", "coder-frontend", "https://github.com/o/r/pull/11")

      urls = PrCounter.urls("run-3", dir)
      assert length(urls) == 2
      assert "https://github.com/o/r/pull/10" in urls
      assert "https://github.com/o/r/pull/11" in urls
    end
  end

  describe "ready?/3" do
    test "returns false when not all signals present", %{signals_dir: dir} do
      write_signal(dir, "run-4", "coder-backend", "https://github.com/o/r/pull/1")

      refute PrCounter.ready?("run-4", 2, dir)
    end

    test "returns true when all signals present", %{signals_dir: dir} do
      write_signal(dir, "run-5", "coder-backend", "https://github.com/o/r/pull/1")
      write_signal(dir, "run-5", "coder-frontend", "https://github.com/o/r/pull/2")

      assert PrCounter.ready?("run-5", 2, dir)
    end

    test "returns true when more signals than expected", %{signals_dir: dir} do
      write_signal(dir, "run-6", "a", "url1")
      write_signal(dir, "run-6", "b", "url2")
      write_signal(dir, "run-6", "c", "url3")

      assert PrCounter.ready?("run-6", 2, dir)
    end
  end

  describe "cleanup/2" do
    test "removes all signal files for a run", %{signals_dir: dir} do
      write_signal(dir, "run-7", "coder-backend", "url1")
      write_signal(dir, "run-7", "coder-frontend", "url2")
      write_signal(dir, "run-other", "coder-backend", "url3")

      PrCounter.cleanup("run-7", dir)

      assert PrCounter.read("run-7", dir) == []
      assert length(PrCounter.read("run-other", dir)) == 1
    end
  end

  describe "signal_path/3" do
    test "builds correct path" do
      assert PrCounter.signal_path("run-1", "coder-backend", "/tmp/signals") ==
               "/tmp/signals/run-1.pr-coder-backend.json"
    end
  end

  defp write_signal(dir, run_id, role, pr_url) do
    path = PrCounter.signal_path(run_id, role, dir)
    data = Jason.encode!(%{"pr_url" => pr_url, "role" => role, "branch" => "branch-#{role}"})
    File.write!(path, data)
  end
end
