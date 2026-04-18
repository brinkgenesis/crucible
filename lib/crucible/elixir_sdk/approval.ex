defmodule Crucible.ElixirSdk.Approval do
  @moduledoc """
  Optional interactive approval for tool calls.

  When a Query runs with `permission_mode: :ask`, every write-capable tool
  call goes through the approval callback before executing. The callback
  is synchronous and must return `:allow | {:allow, new_input} | :deny`.

  Register a callback via `Application.put_env/3` or pass `:on_approval`
  directly in the Query opts. The default callback denies everything so
  `permission_mode: :ask` fails closed if no approver is wired in.

  The callback runs in the calling process, so if you need a dashboard
  prompt, the callback must block on `GenServer.call/3` to whatever
  LiveView mailbox is handling approvals.
  """

  @type decision :: :allow | {:allow, map()} | {:deny, String.t()}

  @type callback :: (String.t(), map(), map() -> decision())

  @mutating_tools ~w(Write Edit Bash NotebookEdit)

  @doc """
  Decide whether a tool call is allowed under the current context.

  For non-mutating tools (Read / Glob / Grep / WebFetch / WebSearch / Task)
  this always returns `:allow` regardless of mode — reading is always
  safe. For mutating tools it dispatches based on `ctx.permission_mode`.
  """
  @spec decide(String.t(), map(), map(), keyword()) :: decision()
  def decide(tool_name, input, ctx, opts \\ []) do
    cond do
      tool_name not in @mutating_tools ->
        :allow

      # Bash always goes through the command classifier first — safe commands
      # skip the rest of the pipeline, critical commands deny immediately.
      tool_name == "Bash" and Keyword.get(opts, :classify_bash?, true) ->
        classify_bash(input, ctx, opts)

      ctx.permission_mode == :bypass_permissions ->
        :allow

      ctx.permission_mode == :accept_edits and tool_name in ["Edit", "Write", "NotebookEdit"] ->
        :allow

      ctx.permission_mode == :accept_edits ->
        ask(tool_name, input, ctx, opts)

      ctx.permission_mode == :plan ->
        {:deny, "plan mode is read-only"}

      ctx.permission_mode == :ask ->
        ask(tool_name, input, ctx, opts)

      ctx.permission_mode == :default ->
        # Default allows mutations without asking — matches SDK behaviour.
        :allow

      true ->
        :allow
    end
  end

  defp ask(tool_name, input, ctx, opts) do
    callback =
      Keyword.get(opts, :on_approval) ||
        Application.get_env(:crucible, :elixir_sdk_approval_callback, &default_deny/3)

    try do
      case callback.(tool_name, input, ctx) do
        :allow -> :allow
        {:allow, new_input} when is_map(new_input) -> {:allow, new_input}
        {:deny, reason} when is_binary(reason) -> {:deny, reason}
        :deny -> {:deny, "denied by approver"}
        other -> {:deny, "invalid approval callback result: #{inspect(other)}"}
      end
    rescue
      e -> {:deny, "approval callback crashed: #{Exception.message(e)}"}
    end
  end

  @doc "Default callback when `:ask` is set but no approver is registered."
  def default_deny(_tool, _input, _ctx), do: {:deny, "no approval handler registered"}

  # Bash-specific classifier hop. Keeps the main cond chain readable.
  defp classify_bash(input, ctx, opts) do
    command = Map.get(input, "command", "")
    cwd = Map.get(ctx, :cwd, ".")

    case Crucible.Safety.CommandClassifier.classify(command, cwd, opts) do
      %{verdict: :deny, reason: reason} ->
        {:deny, "Bash denied: #{reason}"}

      %{verdict: :allow} ->
        # Classifier passed — fall through to normal mode handling.
        decide("Bash", input, ctx, Keyword.put(opts, :classify_bash?, false))

      %{verdict: :ask, reason: reason} ->
        case ctx.permission_mode do
          :bypass_permissions -> :allow
          :plan -> {:deny, "plan mode is read-only"}
          _ -> ask("Bash", input, Map.put(ctx, :classifier_reason, reason), opts)
        end
    end
  end
end
