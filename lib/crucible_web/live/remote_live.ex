defmodule CrucibleWeb.RemoteLive do
  @moduledoc """
  LiveView for launching and managing remote Claude Code sessions.

  Provides a UI to start, monitor, and stop `claude --remote` sessions backed by
  tmux processes. The user selects a codebase directory (repo root, known project,
  or custom path) and launches a session via `RemoteSessionTracker`. Once running,
  the page displays the session URL (with QR code), a live terminal output stream,
  and basic session metrics.

  ## Session lifecycle

  1. **Start** — `"start_remote"` event resolves the selected codebase path, then
     delegates to `RemoteSessionTracker.start_session/1` which spawns a tmux process.
     If a session is already running the tracker reconnects to it.
  2. **Poll** — a `RefreshTimer` fires every 3 000 ms to reload
     status, output lines, and the QR code URL.
  3. **Stop** — `"stop_remote"` event calls `RemoteSessionTracker.stop_session/0`
     to terminate the tmux process and clean up.

  ## Assigns

  | Key                 | Description                                      |
  |---------------------|--------------------------------------------------|
  | `remote`            | Map with `:running`, `:url`, `:pid`, `:startedAt`|
  | `output_lines`      | Raw output lines from the remote session          |
  | `output_entries`    | Collapsed output (consecutive duplicates merged)  |
  | `qr_code_url`       | URL for a QR code image pointing to the session   |
  | `codebase_options`  | List of selectable codebase directories            |
  | `selected_codebase` | Currently chosen codebase option id                |
  | `custom_codebase`   | User-entered custom path (when option is "custom") |
  """

  use CrucibleWeb, :live_view

  alias CrucibleWeb.Live.RefreshTimer

  alias Crucible.CodebaseReader
  alias Crucible.RemoteSessionTracker

  @refresh_interval 3_000

  @doc """
  Mounts the LiveView, initializing assigns with default remote state and
  starting a periodic refresh timer for connected clients.
  """
  @impl true
  def mount(_params, _session, socket) do
    timer = if connected?(socket), do: RefreshTimer.start(@refresh_interval)

    {:ok,
     assign(socket,
       page_title: "Remote",
       refresh_timer: timer,
       current_path: "/remote",
       remote: %{running: false, url: nil, pid: nil, startedAt: nil},
       output_lines: [],
       output_entries: [],
       qr_code_url: nil,
       codebase_options: codebase_options(),
       selected_codebase: "repo_root",
       custom_codebase: ""
     )
     |> load_data()}
  end

  @doc """
  Cancels the refresh timer when the LiveView process terminates.
  """
  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @doc """
  Handles the periodic `:refresh` tick by reloading session status and output
  from `RemoteSessionTracker`, then rescheduling the next tick.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  @doc """
  Starts a new remote Claude Code session in the selected codebase directory.

  Resolves the codebase path from form params, validates it exists, then calls
  `RemoteSessionTracker.start_session/1` to spawn a tmux-backed `claude --remote`
  process. Handles reconnection to an already-running session and missing
  `claude` binary errors.
  """
  @impl true
  def handle_event("start_remote", params, socket) do
    socket =
      socket
      |> assign(
        :selected_codebase,
        params["selected_codebase"] || socket.assigns.selected_codebase
      )
      |> assign(:custom_codebase, params["custom_codebase"] || socket.assigns.custom_codebase)

    cwd = resolve_codebase_path(socket.assigns.selected_codebase, socket.assigns.custom_codebase)

    if cwd == nil or not File.dir?(cwd) do
      {:noreply, put_flash(socket, :error, "Choose a valid codebase path before launching")}
    else
      case RemoteSessionTracker.start_session(cwd: cwd, permission_mode: "bypassPermissions") do
        {:ok, %{alreadyRunning: true}} ->
          {:noreply,
           socket |> put_flash(:info, "Reconnected to active remote session") |> load_data()}

        {:ok, _payload} ->
          {:noreply, socket |> put_flash(:info, "Remote session started") |> load_data()}

        {:error, :claude_not_found} ->
          {:noreply, put_flash(socket, :error, "`claude` executable not found in PATH")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start remote session")}
      end
    end
  end

  @doc false
  def handle_event("set_codebase", params, socket) do
    {:noreply,
     assign(socket,
       selected_codebase: params["selected_codebase"] || socket.assigns.selected_codebase,
       custom_codebase: params["custom_codebase"] || socket.assigns.custom_codebase
     )}
  end

  @doc false
  def handle_event("stop_remote", _params, socket) do
    _ = RemoteSessionTracker.stop_session()
    {:noreply, socket |> put_flash(:info, "Remote session stopped") |> load_data()}
  end

  # Reloads session status, output lines, collapsed entries, and QR code URL
  # from RemoteSessionTracker into socket assigns.
  defp load_data(socket) do
    remote = RemoteSessionTracker.status()
    output_lines = RemoteSessionTracker.output(200)

    assign(socket,
      remote: remote,
      output_lines: output_lines,
      output_entries: collapse_output_lines(output_lines),
      qr_code_url: qr_code_url(remote.url)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="grid grid-cols-12 gap-6">
        <!-- Header Row -->
        <div class="col-span-12 flex items-end justify-between py-4">
          <div>
            <h1 class="text-4xl font-headline font-black text-[#ffa44c] uppercase tracking-tighter">REMOTE_LAUNCHER</h1>
            <div class="flex items-center gap-2 mt-2">
              <span :if={@remote.running} class="w-2 h-2 rounded-full bg-[#00eefc] animate-pulse"></span>
              <span :if={!@remote.running} class="w-2 h-2 rounded-full bg-[#777575]"></span>
              <span class={"font-label text-xs uppercase tracking-widest #{if @remote.running, do: "text-[#00eefc]/80", else: "text-[#777575]"}"}>
                STATUS: {if @remote.running, do: "SESSION_ACTIVE", else: "AWAITING_LAUNCH"}
              </span>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <button
              :if={@remote.running}
              phx-click="stop_remote"
              class="border border-[#ff725e]/40 text-[#ff725e] px-4 py-2 font-label text-[10px] tracking-widest hover:bg-[#ff725e]/10 transition-all"
            >
              TERMINATE_SESSION
            </button>
          </div>
        </div>

        <!-- Left Column: Control & Access -->
        <div class="col-span-12 lg:col-span-4 space-y-6">
          <!-- Start Form -->
          <div class="bg-surface-container-low border-l-4 border-[#ffa44c] p-6 relative overflow-hidden">
            <div class="absolute top-0 right-0 p-2 opacity-10">
              <span class="material-symbols-outlined text-6xl text-[#ffa44c]">rocket_launch</span>
            </div>
            <h3 class="font-headline font-bold text-[#ffa44c] mb-6 flex items-center gap-2">
              <span class="material-symbols-outlined text-sm">settings</span>
              START_FORM
            </h3>
            <form phx-submit="start_remote" phx-change="set_codebase" class="space-y-6">
              <div>
                <label class="block font-label text-[10px] text-[#494847] mb-2 uppercase">CODEBASE_ROOT_DIRECTORY</label>
                <div class="relative">
                  <select
                    name="selected_codebase"
                    class="w-full bg-surface-container-high border-b border-[#ffa44c] text-white font-label text-xs py-3 px-4 appearance-none focus:ring-0 focus:outline-none focus:border-[#00eefc] transition-colors"
                  >
                    <option
                      :for={opt <- @codebase_options}
                      value={opt.id}
                      selected={opt.id == @selected_codebase}
                    >
                      {opt.label}
                    </option>
                  </select>
                  <span class="material-symbols-outlined absolute right-3 top-1/2 -translate-y-1/2 text-[#ffa44c] pointer-events-none">expand_more</span>
                </div>
              </div>
              <div :if={@selected_codebase == "custom"}>
                <label class="block font-label text-[10px] text-[#494847] mb-2 uppercase">CUSTOM_PATH</label>
                <input
                  type="text"
                  name="custom_codebase"
                  value={@custom_codebase}
                  placeholder="/absolute/path/to/codebase"
                  class="w-full bg-surface-container-high border-b border-[#ffa44c] text-white font-label text-xs py-3 px-4 focus:ring-0 focus:outline-none focus:border-[#00eefc]"
                />
              </div>
              <div>
                <label class="block font-label text-[10px] text-[#494847] mb-2 uppercase">SESSION_PARAMETERS</label>
                <div class="flex gap-2">
                  <span class="bg-[#ffa44c]/10 text-[#ffa44c] font-label text-[9px] px-2 py-1 border border-[#ffa44c]/20">BYPASS_PERMS</span>
                  <span class="bg-[#00eefc]/10 text-[#00eefc] font-label text-[9px] px-2 py-1 border border-[#00eefc]/20">REMOTE_CTRL</span>
                </div>
              </div>
              <button
                :if={!@remote.running}
                type="submit"
                class="w-full bg-[#ffa44c] hover:brightness-110 text-black font-headline font-black py-4 flex justify-center items-center gap-3 transition-all active:scale-95"
              >
                <span class="material-symbols-outlined">bolt</span>
                LAUNCH_SESSION
              </button>
            </form>
          </div>

          <!-- Session URL & QR -->
          <div :if={@remote.running} class="bg-surface-container-low p-6 flex gap-6">
            <div class="flex-1 space-y-4">
              <h3 class="font-headline font-bold text-[#00eefc] text-sm flex items-center gap-2">
                <span class="material-symbols-outlined text-sm">link</span>
                SESSION_URL
              </h3>
              <div class="bg-black border border-[#494847]/20 p-3 font-label text-[11px] text-[#00eefc] flex items-center justify-between">
                <span class="truncate">{@remote.url || "waiting..."}</span>
                <button
                  :if={@remote.url}
                  id="copy-remote-url"
                  phx-hook="CopyToClipboard"
                  data-clipboard-text={@remote.url}
                  class="hover:text-[#ffa44c] transition-colors"
                  title="Copy URL"
                >
                  <span class="material-symbols-outlined text-sm">content_copy</span>
                </button>
              </div>
              <div class="flex justify-between items-center">
                <span class="font-label text-[10px] text-[#494847]">PID: {to_string(@remote.pid || "—")}</span>
                <span class="font-label text-[10px] text-[#00eefc]">MODE: {to_string(@remote.permissionMode || "bypassPermissions")}</span>
              </div>
            </div>
            <div :if={@qr_code_url} class="w-24 h-24 bg-white p-1 shrink-0 flex items-center justify-center">
              <a href={@remote.url} target="_blank" rel="noopener noreferrer">
                <img src={@qr_code_url} alt="Remote Session QR Code" class="w-full h-full" />
              </a>
            </div>
          </div>

          <!-- Empty state -->
          <div :if={!@remote.running} class="bg-surface-container-low p-8 hud-border text-center">
            <span class="material-symbols-outlined text-4xl text-[#ffa44c]/20 mb-3 block">memory</span>
            <p class="font-label text-[10px] text-[#adaaaa]/40 uppercase tracking-widest mb-2">NO_ACTIVE_SESSION</p>
            <p class="font-label text-[9px] text-[#ffa44c]/30">Launch a session to generate an access URL and live output stream</p>
          </div>
        </div>

        <!-- Right Column: Terminal & Monitoring -->
        <div class="col-span-12 lg:col-span-8 flex flex-col gap-6">
          <!-- Live Terminal -->
          <div class="flex-1 bg-black border border-[#494847]/30 relative flex flex-col min-h-[400px]">
            <div class="bg-surface-container-high px-4 py-2 flex items-center justify-between border-b border-[#494847]/20">
              <div class="flex items-center gap-2">
                <span class="material-symbols-outlined text-[#00eefc] text-sm">terminal</span>
                <span class="font-label text-[10px] text-white uppercase tracking-widest">LIVE_OUTPUT_STREAM</span>
              </div>
              <div class="flex gap-2">
                <div class="w-2 h-2 bg-[#ff725e]"></div>
                <div class="w-2 h-2 bg-[#ffa44c]"></div>
                <div class="w-2 h-2 bg-[#00eefc]"></div>
              </div>
            </div>
            <div class="flex-1 p-4 font-label text-[12px] leading-relaxed text-[#00FF41] overflow-y-auto">
              <div :if={@output_entries == []} class="text-[#00FF41]/30 space-y-1">
                <p>[SYSTEM] AWAITING_SESSION_OUTPUT...</p>
                <p class="animate-pulse">_</p>
              </div>
              <div :if={@output_entries != []} class="space-y-1">
                <div :for={entry <- @output_entries} class="flex items-start gap-2">
                  <span class="flex-1 whitespace-pre-wrap break-words leading-5">
                    {entry.line}
                  </span>
                  <span :if={entry.count > 1} class="text-[#ffa44c] text-[9px] shrink-0">x{entry.count}</span>
                </div>
              </div>
            </div>
          </div>

          <!-- Metrics -->
          <div :if={@remote.running} class="grid grid-cols-3 gap-4">
            <div class="bg-surface-container-low p-4 border-t-2 border-[#00eefc]">
              <p class="font-label text-[9px] text-[#494847] mb-1">SESSION_STATUS</p>
              <p class="font-headline font-bold text-[#00eefc] text-xl">ACTIVE</p>
            </div>
            <div class="bg-surface-container-low p-4 border-t-2 border-[#ffa44c]">
              <p class="font-label text-[9px] text-[#494847] mb-1">OUTPUT_LINES</p>
              <p class="font-headline font-bold text-[#ffa44c] text-xl">{length(@output_lines)}</p>
            </div>
            <div class="bg-surface-container-low p-4 border-t-2 border-[#00FF41]">
              <p class="font-label text-[9px] text-[#494847] mb-1">STARTED_AT</p>
              <p class="font-headline font-bold text-[#00FF41] text-sm">{format_started_at(@remote.startedAt)}</p>
            </div>
          </div>

          <div :if={@remote.running} class="text-[10px] font-label text-[#adaaaa]/40 uppercase tracking-widest">
            CWD: {to_string(@remote.cwd || "—")}
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Formats an ISO 8601 timestamp string for display, or returns "—" if nil.
  defp format_started_at(nil), do: "—"

  defp format_started_at(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

      _ ->
        ts
    end
  end

  # Deduplicates consecutive identical output lines, returning a list of
  # `%{line: String.t(), count: pos_integer()}` maps for display.
  defp collapse_output_lines(lines) do
    {counts, order} =
      Enum.reduce(lines, {%{}, []}, fn line, {counts, order} ->
        if Map.has_key?(counts, line) do
          {Map.update!(counts, line, &(&1 + 1)), order}
        else
          {Map.put(counts, line, 1), [line | order]}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn line -> %{line: line, count: Map.get(counts, line, 1)} end)
  end

  # Generates a QR code image URL via quickchart.io for the given session URL.
  # Returns nil when no URL is available.
  defp qr_code_url(nil), do: nil
  defp qr_code_url(""), do: nil

  defp qr_code_url(url) when is_binary(url) do
    "https://quickchart.io/qr?size=220&dark=000000&light=FFFFFF&text=#{URI.encode_www_form(url)}"
  end

  # Builds the list of selectable codebase directories for the launch form.
  # Includes "Repo Root", "Custom Path", inferred subdirectories, and projects
  # discovered by `CodebaseReader.list_projects/0`.
  defp codebase_options do
    repo_root = repo_root()

    inferred =
      [repo_root, Path.join(repo_root, "orchestrator"), Path.join(repo_root, "dashboard")]
      |> Enum.filter(&File.dir?/1)
      |> Enum.uniq()
      |> Enum.map(fn path -> %{id: path, label: path} end)

    project_options =
      CodebaseReader.list_projects()
      |> Enum.map(fn project ->
        case project_path(repo_root, project) do
          nil -> nil
          path -> %{id: path, label: "#{project} — #{path}"}
        end
      end)
      |> Enum.reject(&is_nil/1)

    ([%{id: "repo_root", label: "Repo Root"}, %{id: "custom", label: "Custom Path"}] ++
       inferred ++ project_options)
    |> Enum.uniq_by(& &1.id)
  end

  # Maps the selected codebase option to an absolute filesystem path.
  defp resolve_codebase_path("repo_root", _custom), do: repo_root()
  defp resolve_codebase_path("custom", custom) when is_binary(custom), do: String.trim(custom)
  defp resolve_codebase_path(path, _custom) when is_binary(path), do: path
  defp resolve_codebase_path(_, _), do: repo_root()

  defp repo_root do
    orchestrator_opts = Application.get_env(:crucible, :orchestrator, [])
    Keyword.get(orchestrator_opts, :repo_root, File.cwd!())
  end

  defp project_path(repo_root, "infra"), do: repo_root

  defp project_path(repo_root, project) do
    path = Path.join(repo_root, project)
    if File.dir?(path), do: path, else: nil
  end
end
