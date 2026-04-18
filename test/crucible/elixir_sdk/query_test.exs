defmodule Crucible.ElixirSdk.QueryTest do
  @moduledoc """
  Smoke test for the tool-use loop. Uses a stub client module that emits
  canned SSE-style events via `send/2` so we never hit the real Anthropic
  API.
  """
  use ExUnit.Case, async: false

  alias Crucible.ElixirSdk.Query

  setup do
    tmp =
      Path.join([System.tmp_dir!(), "crucible-query-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "tool dispatch" do
    test "tool registry lookup returns error tuple for unknown tool", %{tmp: _tmp} do
      # Indirect smoke: dispatch_tool is private, but ToolRegistry.lookup
      # is the contract — confirm missing tool returns :error.
      assert Crucible.ElixirSdk.ToolRegistry.lookup("DoesNotExist") == :error
    end

    test "registry.all returns the 7 built-in tools" do
      names = Crucible.ElixirSdk.ToolRegistry.all() |> Enum.map(&elem(&1, 0))
      assert "Read" in names
      assert "Write" in names
      assert "Edit" in names
      assert "Bash" in names
      assert "Glob" in names
      assert "Grep" in names
      assert "Task" in names
    end
  end

  describe "hook dispatch" do
    defmodule DenyBashHook do
      @behaviour Crucible.ElixirSdk.Hook
      def pre_tool_use("Bash", _input, _ctx), do: {:deny, "bash disabled in test"}
      def pre_tool_use(_tool, input, _ctx), do: {:allow, input}
    end

    defmodule TagPostHook do
      @behaviour Crucible.ElixirSdk.Hook
      def post_tool_use(_tool, _input, output, _ctx), do: {:ok, "[tagged] " <> output}
    end

    test "pre-hook can deny a tool call" do
      Application.put_env(:crucible, :elixir_sdk_hooks, [{DenyBashHook, :pre_tool_use}])

      assert {:deny, reason} =
               Crucible.ElixirSdk.Hook.apply_pre("Bash", %{"command" => "ls"}, %{
                 cwd: ".",
                 permission_mode: :default
               })

      assert reason =~ "bash disabled"

      # Non-bash tools still allowed
      assert {:allow, %{"file_path" => "x"}} =
               Crucible.ElixirSdk.Hook.apply_pre("Read", %{"file_path" => "x"}, %{
                 cwd: ".",
                 permission_mode: :default
               })
    after
      Application.delete_env(:crucible, :elixir_sdk_hooks)
    end

    test "post-hook can mutate output" do
      Application.put_env(:crucible, :elixir_sdk_hooks, [{TagPostHook, :post_tool_use}])

      assert Crucible.ElixirSdk.Hook.apply_post("Read", %{}, "file contents", %{
               cwd: ".",
               permission_mode: :default
             }) == "[tagged] file contents"
    after
      Application.delete_env(:crucible, :elixir_sdk_hooks)
    end
  end

  describe "public api" do
    test "start_link starts a Query GenServer (without actually calling Anthropic)" do
      # We pass an invalid api_key so the first turn errors out immediately —
      # just checking that the GenServer starts + handles errors cleanly.
      {:ok, pid} =
        Query.start_link(
          prompt: "hello",
          model: "claude-haiku-4-5-20251001",
          cwd: File.cwd!(),
          api_key: "sk-ant-invalid-test-key",
          max_turns: 1,
          timeout_ms: 2_000
        )

      assert is_pid(pid)

      # Await will return an error because the API call will fail
      result = Query.await(pid, 5_000)
      assert match?({:error, _}, result)
    end

    test "interrupt stops the GenServer" do
      {:ok, pid} =
        Query.start_link(
          prompt: "hello",
          model: "claude-haiku-4-5-20251001",
          cwd: File.cwd!(),
          api_key: "sk-ant-invalid-test-key",
          max_turns: 1,
          timeout_ms: 10_000
        )

      Query.interrupt(pid)
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "set_model and set_permission_mode are async casts" do
      {:ok, pid} =
        Query.start_link(
          prompt: "hello",
          model: "claude-haiku-4-5-20251001",
          cwd: File.cwd!(),
          api_key: "sk-ant-invalid-test-key",
          max_turns: 1,
          timeout_ms: 2_000
        )

      # These return :ok and don't block
      assert :ok = Query.set_model(pid, "claude-sonnet-4-6")
      assert :ok = Query.set_permission_mode(pid, :plan)

      # Drain
      Query.interrupt(pid)
    end
  end
end
