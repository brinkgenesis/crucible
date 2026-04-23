defmodule Crucible.ControlSession do
  @moduledoc """
  Manages interactive Claude Code sessions for the Control panel.

  Each slot (1-6) can have an independent Claude Code instance running in a
  detached tmux session. The user picks a codebase directory and model, and
  this GenServer spawns `claude --permission-mode bypassPermissions --model <model>`
  in a new tmux pane targeting that directory.

  State is held in ETS for fast reads from LiveView. PubSub broadcasts
  keep the UI reactive.

  Implementation details are delegated to submodules:
  - `ControlSession.TmuxManager` — tmux pane lifecycle and output capture
  - `ControlSession.CodebaseDiscovery` — scanning for available codebases
  - `ControlSession.SlotStore` — ETS read/write and PubSub broadcasting
  """
  use GenServer

  require Logger

  alias Crucible.ControlSession.{CodebaseDiscovery, SlotStore, TmuxManager}

  @max_slots 6

  # Explicit call timeouts — stop/spawn touch tmux (process kill), set_model is metadata-only,
  # list_codebases scans the filesystem.
  @call_timeout_write 15_000
  @call_timeout_read 5_000
  @call_timeout_fs 10_000

  @type model_option :: %{id: String.t(), name: String.t(), tier: String.t()}
  @type slot_id :: 1..6
  @type slot_status :: :empty | :starting | :ready | :error | :stopped

  @type slot :: %{
          id: slot_id(),
          status: slot_status(),
          cwd: String.t() | nil,
          model: String.t(),
          tmux_session: String.t() | nil,
          started_at: DateTime.t() | nil,
          last_output: String.t(),
          error: String.t() | nil
        }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all 6 slots."
  @spec list_slots() :: [slot()]
  def list_slots, do: SlotStore.list_all()

  @doc "Returns a single slot."
  @spec get_slot(slot_id()) :: slot()
  def get_slot(slot_id) when slot_id in 1..@max_slots, do: SlotStore.get(slot_id)

  @doc "Spawns a Claude Code session in the given slot."
  @spec spawn_session(slot_id(), String.t(), keyword()) :: :ok | {:error, term()}
  def spawn_session(slot_id, cwd, opts \\ []) when slot_id in 1..@max_slots do
    GenServer.call(__MODULE__, {:spawn, slot_id, cwd, opts}, 15_000)
  end

  @doc "Stops a running session in the given slot."
  @spec stop_session(slot_id()) :: :ok
  def stop_session(slot_id) when slot_id in 1..@max_slots do
    GenServer.call(__MODULE__, {:stop, slot_id}, @call_timeout_write)
  end

  @doc "Changes the model for a slot. Takes effect on next spawn."
  @spec set_model(slot_id(), String.t()) :: :ok
  def set_model(slot_id, model) when slot_id in 1..@max_slots do
    GenServer.call(__MODULE__, {:set_model, slot_id, model}, @call_timeout_read)
  end

  @doc "Captures the latest output from a slot's tmux pane."
  @spec capture_output(slot_id()) :: String.t()
  def capture_output(slot_id) when slot_id in 1..@max_slots do
    case SlotStore.get(slot_id) do
      %{tmux_session: nil} -> ""
      %{tmux_session: session_name} -> TmuxManager.capture_pane(session_name)
    end
  end

  @doc "Lists available codebases (recent git repos and configured projects)."
  @spec list_codebases() :: [map()]
  def list_codebases do
    GenServer.call(__MODULE__, :list_codebases, @call_timeout_fs)
  end

  @doc "Sends text input to a running session's tmux pane."
  @spec send_input(slot_id(), String.t()) :: :ok | {:error, term()}
  def send_input(slot_id, text) when slot_id in 1..@max_slots do
    case SlotStore.get(slot_id) do
      %{status: :ready, tmux_session: session} when is_binary(session) ->
        System.cmd("tmux", ["send-keys", "-t", session, text, "Enter"], stderr_to_stdout: true)

        :ok

      _ ->
        {:error, :not_running}
    end
  end

  @doc "Available models for the model selector. First entry is the default."
  @spec available_models() :: [model_option()]
  def available_models do
    [
      %{id: "claude-opus-4-7", name: "Opus 4.7", tier: "highest"},
      %{id: "claude-sonnet-4-6", name: "Sonnet 4.6", tier: "high"},
      %{id: "claude-haiku-4-5-20251001", name: "Haiku 4.5", tier: "fast"}
    ]
  end

  @doc "Default model id — the initial selection in the spawn modal."
  @spec default_model() :: String.t()
  def default_model do
    [%{id: id} | _] = available_models()
    id
  end

  @doc """
  Returns `true` if the host has the binaries Control needs (`tmux` and `claude`).
  Used by the UI to show a setup banner instead of silently failing to spawn.
  """
  @spec host_supported?() :: boolean()
  def host_supported? do
    System.find_executable("tmux") != nil and System.find_executable("claude") != nil
  end

  @doc "Returns a map describing which required binaries are present."
  @spec host_status() :: %{tmux: boolean(), claude: boolean()}
  def host_status do
    %{
      tmux: System.find_executable("tmux") != nil,
      claude: System.find_executable("claude") != nil
    }
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = SlotStore.init_table()
    reconnect_orphaned_sessions()
    SlotStore.schedule_output_poll()
    {:ok, %{table: table, timers: %{}}}
  end

  # Scans for existing ctrl-* tmux sessions and re-adopts them into ETS slots.
  # This lets sessions survive server restarts — tmux outlives the BEAM.
  # No-op in environments without tmux (e.g. container deployments).
  defp reconnect_orphaned_sessions do
    cond do
      not reconnect_orphaned_sessions?() ->
        Logger.info("ControlSession: orphan session reconnect disabled")
        :ok

      System.find_executable("tmux") ->
        do_reconnect_orphaned_sessions()

      true ->
        Logger.info("ControlSession: tmux not available, skipping orphan session reconnect")
        :ok
    end
  end

  defp reconnect_orphaned_sessions? do
    Application.get_env(:crucible, :control_session, [])
    |> Keyword.get(:reconnect_orphaned_sessions, true)
  end

  defp do_reconnect_orphaned_sessions do
    case System.cmd("tmux", ["list-sessions", "-F", "\#{session_name}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn name ->
          case Regex.run(~r/^ctrl-(\d+)$/, String.trim(name)) do
            [_, slot_str] ->
              slot_id = String.to_integer(slot_str)

              if slot_id in 1..@max_slots and TmuxManager.session_alive?(name) do
                cwd = detect_session_cwd(name)
                model = detect_session_model(name)

                SlotStore.update(slot_id, %{
                  status: :ready,
                  cwd: cwd,
                  model: model,
                  tmux_session: name,
                  started_at: DateTime.utc_now(),
                  last_output: TmuxManager.capture_pane_tail(name, 30),
                  error: nil
                })

                Logger.info("ControlSession: reconnected orphaned session #{name} (cwd=#{cwd})")
              end

            _ ->
              :ok
          end
        end)

        SlotStore.broadcast_update()

      _ ->
        :ok
    end
  end

  # Extracts the working directory from a tmux session's pane
  defp detect_session_cwd(session_name) do
    case System.cmd(
           "tmux",
           ["display-message", "-t", session_name, "-p", "\#{pane_current_path}"],
           stderr_to_stdout: true
         ) do
      {path, 0} -> String.trim(path)
      _ -> nil
    end
  end

  # Tries to extract the model from the command that launched claude
  defp detect_session_model(session_name) do
    output = TmuxManager.capture_pane(session_name)

    case Regex.run(~r/--model\s+([\w\-\.]+)/, output) do
      [_, model] -> model
      _ -> "claude-sonnet-4-6"
    end
  end

  @impl true
  def handle_call({:spawn, slot_id, cwd, opts}, _from, state) do
    slot = SlotStore.get(slot_id)

    if slot.status in [:starting, :ready] do
      {:reply, {:error, :already_running}, state}
    else
      model = Keyword.get(opts, :model, slot.model)
      session_name = "ctrl-#{slot_id}"

      TmuxManager.kill(session_name)

      SlotStore.update(slot_id, %{
        status: :starting,
        cwd: cwd,
        model: model,
        tmux_session: session_name,
        started_at: DateTime.utc_now(),
        last_output: "",
        error: nil
      })

      SlotStore.broadcast_update()

      self_pid = self()

      Task.Supervisor.start_child(Crucible.TaskSupervisor, fn ->
        result = TmuxManager.spawn(session_name, cwd, model)
        send(self_pid, {:spawn_result, slot_id, result})
      end)

      {:reply, :ok, state}
    end
  end

  def handle_call({:stop, slot_id}, _from, state) do
    slot = SlotStore.get(slot_id)

    if slot.tmux_session, do: TmuxManager.kill(slot.tmux_session)

    SlotStore.reset(slot_id)
    SlotStore.broadcast_update()
    {:reply, :ok, state}
  end

  def handle_call({:set_model, slot_id, model}, _from, state) do
    slot = SlotStore.get(slot_id)
    SlotStore.update(slot_id, %{model: model})
    SlotStore.broadcast_update()

    if slot.status == :ready and slot.tmux_session do
      TmuxManager.kill(slot.tmux_session)
      SlotStore.update(slot_id, %{status: :starting, last_output: ""})
      SlotStore.broadcast_update()

      session_name = slot.tmux_session
      cwd = slot.cwd
      self_pid = self()

      Task.Supervisor.start_child(Crucible.TaskSupervisor, fn ->
        result = TmuxManager.spawn(session_name, cwd, model)
        send(self_pid, {:spawn_result, slot_id, result})
      end)
    end

    {:reply, :ok, state}
  end

  def handle_call(:list_codebases, _from, state) do
    {:reply, CodebaseDiscovery.discover(), state}
  end

  @impl true
  def handle_info({:spawn_result, slot_id, :ok}, state) do
    SlotStore.update(slot_id, %{status: :ready, error: nil})
    SlotStore.broadcast_update()
    Logger.info("ControlSession: slot #{slot_id} ready")
    {:noreply, state}
  end

  def handle_info({:spawn_result, slot_id, {:error, reason}}, state) do
    SlotStore.reset(slot_id)
    SlotStore.broadcast_update()
    Logger.error("ControlSession: slot #{slot_id} spawn failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(:poll_output, state) do
    for slot_id <- 1..@max_slots do
      slot = SlotStore.get(slot_id)

      cond do
        slot.status == :ready and slot.tmux_session ->
          if TmuxManager.session_alive?(slot.tmux_session) do
            output = TmuxManager.capture_pane_tail(slot.tmux_session, 30)

            if output != slot.last_output do
              SlotStore.update(slot_id, %{last_output: output})
              SlotStore.broadcast_update()
            end
          else
            SlotStore.reset(slot_id)
            SlotStore.broadcast_update()
            Logger.warning("ControlSession: slot #{slot_id} tmux session died, resetting")
          end

        slot.status not in [:empty, :starting] ->
          SlotStore.reset(slot_id)
          SlotStore.broadcast_update()

        true ->
          :ok
      end
    end

    SlotStore.schedule_output_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
