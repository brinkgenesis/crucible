defmodule Crucible.WorkflowStore do
  @moduledoc """
  GenServer that caches parsed workflow YAMLs from workflows/*.yml.
  Polls for file changes periodically. Mirrors Symphony's WorkflowStore.
  """
  use GenServer

  require Logger

  @poll_interval 2_000

  # Explicit call timeout — reads from in-memory cache; pass explicitly for consistency.
  @call_timeout 5_000

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a parsed workflow config by name."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(workflow_name) do
    GenServer.call(__MODULE__, {:get, workflow_name}, @call_timeout)
  end

  @doc "Returns all loaded workflow names."
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list, @call_timeout)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    workflows_dir = Keyword.get(opts, :workflows_dir, "workflows")
    state = %{workflows_dir: workflows_dir, cache: %{}, mtimes: %{}}

    state = load_workflows(state)
    schedule_poll()

    Logger.info("WorkflowStore started, loaded #{map_size(state.cache)} workflows")
    {:ok, state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.cache, name) do
      {:ok, workflow} -> {:reply, {:ok, workflow}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.cache), state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = load_workflows(state)
    schedule_poll()
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp load_workflows(state) do
    dir = state.workflows_dir

    if File.dir?(dir) do
      dir
      |> Path.join("*.yml")
      |> Path.wildcard()
      |> Enum.reduce(state, fn path, acc ->
        name = Path.basename(path, ".yml")
        mtime = File.stat!(path).mtime

        if Map.get(acc.mtimes, path) != mtime do
          case YamlElixir.read_from_file(path) do
            {:ok, parsed} ->
              %{
                acc
                | cache: Map.put(acc.cache, name, parsed),
                  mtimes: Map.put(acc.mtimes, path, mtime)
              }

            {:error, reason} ->
              Logger.warning("Failed to parse #{path}: #{inspect(reason)}")
              acc
          end
        else
          acc
        end
      end)
    else
      state
    end
  end
end
