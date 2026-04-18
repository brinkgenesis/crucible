defmodule Crucible.ConfigTest do
  use ExUnit.Case, async: true

  alias Crucible.Config

  describe "load!/0" do
    test "returns validated config with defaults" do
      config = Config.load!()
      assert Keyword.get(config, :poll_interval_ms) == 2_000
      assert Keyword.get(config, :max_concurrent_runs) == 5
      assert Keyword.get(config, :daily_budget_usd) == 100.0
      assert Keyword.get(config, :agent_budget_usd) == 10.0
      assert Keyword.get(config, :task_budget_usd) == 50.0
      assert is_binary(Keyword.get(config, :repo_root))
    end
  end

  describe "schema/0" do
    test "returns NimbleOptions schema" do
      schema = Config.schema()
      assert is_struct(schema, NimbleOptions)
    end
  end
end
