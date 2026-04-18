defmodule Crucible.Claude.SessionTest do
  use ExUnit.Case, async: true

  alias Crucible.Claude.Session

  describe "clean_env/0" do
    test "unsets CLAUDECODE env var" do
      env = Session.clean_env()
      assert {~c"CLAUDECODE", false} in env
    end

    test "unsets MIX_ prefixed vars" do
      env = Session.clean_env()
      mix_vars = Enum.filter(env, fn {k, _v} -> to_string(k) |> String.starts_with?("MIX_") end)

      Enum.each(mix_vars, fn {_k, v} ->
        assert v == false, "MIX_ vars should be unset (false)"
      end)
    end

    test "unsets ERL_ prefixed vars" do
      env = Session.clean_env()
      erl_vars = Enum.filter(env, fn {k, _v} -> to_string(k) |> String.starts_with?("ERL_") end)

      Enum.each(erl_vars, fn {_k, v} ->
        assert v == false, "ERL_ vars should be unset (false)"
      end)
    end

    test "returns charlist keys" do
      env = Session.clean_env()

      Enum.each(env, fn {k, v} ->
        assert is_list(k), "key should be charlist"
        assert v == false or is_list(v), "value should be charlist or false"
      end)
    end

    test "does not include full parent env (only deltas)" do
      env = Session.clean_env()
      keys = Enum.map(env, fn {k, _v} -> to_string(k) end)
      refute "PATH" in keys
    end
  end

  describe "claude_ready?/1" do
    test "detects ready state with prompt and cost display" do
      pane = """
      Claude Code v2.1.51
      Some output here
      $0.03
      ❯
      """

      assert Session.claude_ready?(pane)
    end

    test "detects ready state with bare > prompt" do
      pane = """
      Claude Code v2.1.51
      bypassPermissions
      >
      """

      assert Session.claude_ready?(pane)
    end

    test "rejects empty pane" do
      refute Session.claude_ready?("")
    end

    test "rejects pane without prompt character" do
      pane = """
      Claude Code v2.1.51
      Processing...
      $0.03
      """

      refute Session.claude_ready?(pane)
    end

    test "rejects pane with prompt but no corroborating signal" do
      pane = """
      some random output
      ❯
      """

      refute Session.claude_ready?(pane)
    end

    test "rejects teammate prompt (prefixed with @)" do
      pane = """
      Claude Code v2.1.51
      $0.03
      @coder-backend❯
      """

      refute Session.claude_ready?(pane)
    end
  end
end
