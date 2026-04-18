defmodule Crucible.ElixirSdk.Hook do
  @moduledoc """
  Behaviour for PreToolUse / PostToolUse hooks in the native SDK.

  Hooks are configured via `Application.put_env(:crucible, :elixir_sdk_hooks,
  [{Crucible.ElixirSdk.Hooks.MyHook, :pre_tool_use}, ...])` — each entry is
  a `{module, event}` pair where `event` is `:pre_tool_use` or
  `:post_tool_use`.

  Hooks can:
    * Mutate the tool input (pre) or output (post)
    * Deny a tool call (pre) — return `{:deny, reason}` to short-circuit
    * Fire telemetry, record audit entries, etc.

  Unlike the Claude Agent SDK's Node hooks (which run as async callbacks),
  these are synchronous — a hook that blocks will hold up the turn.
  """

  @type ctx :: %{
          cwd: String.t(),
          permission_mode: atom(),
          run_id: String.t() | nil,
          phase_id: String.t() | nil
        }

  @type pre_result ::
          {:allow, input :: map()}
          | {:deny, reason :: String.t()}
          | :skip

  @type post_result ::
          {:ok, output :: String.t()}
          | :skip

  @callback pre_tool_use(tool_name :: String.t(), input :: map(), ctx :: ctx()) :: pre_result
  @callback post_tool_use(
              tool_name :: String.t(),
              input :: map(),
              output :: String.t(),
              ctx :: ctx()
            ) :: post_result

  @optional_callbacks pre_tool_use: 3, post_tool_use: 4

  # ── Dispatch helpers (used from Query) ───────────────────────────────────

  @doc "Apply all registered pre-tool-use hooks. Returns the possibly-modified input or `{:deny, reason}`."
  @spec apply_pre(String.t(), map(), map()) :: {:allow, map()} | {:deny, String.t()}
  def apply_pre(tool_name, input, ctx) do
    hooks(:pre_tool_use)
    |> Enum.reduce_while({:allow, input}, fn module, {:allow, current_input} ->
      if function_exported?(module, :pre_tool_use, 3) do
        case module.pre_tool_use(tool_name, current_input, ctx) do
          {:allow, next_input} -> {:cont, {:allow, next_input}}
          {:deny, reason} -> {:halt, {:deny, reason}}
          :skip -> {:cont, {:allow, current_input}}
        end
      else
        {:cont, {:allow, current_input}}
      end
    end)
  end

  @doc "Apply all registered post-tool-use hooks. Returns the final output string."
  @spec apply_post(String.t(), map(), String.t(), map()) :: String.t()
  def apply_post(tool_name, input, output, ctx) do
    hooks(:post_tool_use)
    |> Enum.reduce(output, fn module, acc ->
      if function_exported?(module, :post_tool_use, 4) do
        case module.post_tool_use(tool_name, input, acc, ctx) do
          {:ok, mutated} -> mutated
          :skip -> acc
        end
      else
        acc
      end
    end)
  end

  defp hooks(event) do
    Application.get_env(:crucible, :elixir_sdk_hooks, [])
    |> Enum.filter(fn
      {_mod, ^event} -> true
      _ -> false
    end)
    |> Enum.map(fn {mod, _} -> mod end)
  end
end
