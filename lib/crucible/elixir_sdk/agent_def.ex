defmodule Crucible.ElixirSdk.AgentDef do
  @moduledoc """
  Custom-agent definitions (first-class subagent types).

  Mirrors the Claude Agent SDK's `agents` configuration. An AgentDef
  captures the fields needed to spawn a focused subagent:

    * `name` — stable identifier (matches the `subagent_type` argument to the
      `Task` tool).
    * `description` — 1-2 sentence summary of the agent's role.
    * `model` — model override for this subagent (falls through to the
      parent's model if nil).
    * `tools` — list of tool names the subagent is allowed to call. Nil
      means "inherit from parent's registry".
    * `system_prompt` — base system prompt injected before the parent's
      prompt.
    * `permission_mode` — defaults to parent's mode.

  Definitions are loaded from workflow YAML (`agents:` block) or
  registered programmatically via `register/1`.
  """

  require Logger

  @registry_key {__MODULE__, :registry}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          model: String.t() | nil,
          tools: [String.t()] | nil,
          system_prompt: String.t() | nil,
          permission_mode: atom() | nil,
          max_turns: pos_integer() | nil
        }

  defstruct name: nil,
            description: "",
            model: nil,
            tools: nil,
            system_prompt: nil,
            permission_mode: nil,
            max_turns: nil

  @doc "Register an agent definition."
  @spec register(t() | map()) :: :ok
  def register(%__MODULE__{} = def), do: put(def.name, def)
  def register(%{} = raw), do: put(raw[:name] || raw["name"], struct_from_map(raw))

  @doc "Look up by name, or return nil."
  @spec lookup(String.t() | nil) :: t() | nil
  def lookup(nil), do: nil
  def lookup(name), do: Map.get(registry(), name)

  @doc "Load definitions from a workflow `agents:` YAML block."
  @spec load_from_yaml([map()]) :: :ok
  def load_from_yaml(list) when is_list(list) do
    Enum.each(list, fn entry ->
      register(%__MODULE__{
        name: fetch(entry, :name),
        description: fetch(entry, :description) || "",
        model: fetch(entry, :model),
        tools: fetch(entry, :tools),
        system_prompt: fetch(entry, :prompt) || fetch(entry, :system),
        permission_mode: fetch(entry, :permission_mode) |> to_mode(),
        max_turns: fetch(entry, :max_turns)
      })
    end)
  end

  def load_from_yaml(_), do: :ok

  @doc "Clear all registered definitions. Useful between tests."
  def clear, do: :persistent_term.put(@registry_key, %{})

  # --- private ---

  defp registry do
    case :persistent_term.get(@registry_key, nil) do
      nil -> %{}
      %{} = m -> m
    end
  end

  defp put(nil, _def), do: :ok

  defp put(name, def) when is_binary(name) do
    current = registry()
    :persistent_term.put(@registry_key, Map.put(current, name, def))
    :ok
  end

  defp struct_from_map(map) do
    %__MODULE__{
      name: fetch(map, :name),
      description: fetch(map, :description) || "",
      model: fetch(map, :model),
      tools: fetch(map, :tools),
      system_prompt: fetch(map, :prompt) || fetch(map, :system),
      permission_mode: fetch(map, :permission_mode) |> to_mode(),
      max_turns: fetch(map, :max_turns)
    }
  end

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp to_mode(nil), do: nil
  defp to_mode(atom) when is_atom(atom), do: atom
  defp to_mode("default"), do: :default
  defp to_mode("accept_edits"), do: :accept_edits
  defp to_mode("bypass_permissions"), do: :bypass_permissions
  defp to_mode("plan"), do: :plan
  defp to_mode(_), do: :default
end
