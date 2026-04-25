defmodule CrucibleWeb.WorkspacesLive do
  use CrucibleWeb, :live_view

  alias Crucible.WorkspaceProfiles
  alias Crucible.Schema.WorkspaceProfile

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Workspaces",
       current_path: "/workspaces",
       workspaces: WorkspaceProfiles.list_workspaces(),
       show_form: false,
       editing: nil,
       form: new_form(),
       browser_open: false,
       browser_cwd: nil,
       browser_entries: []
     )}
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply,
     assign(socket, show_form: !socket.assigns.show_form, editing: nil, form: new_form())}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case WorkspaceProfiles.get_workspace(id) do
      %WorkspaceProfile{} = ws ->
        form =
          %{
            "name" => ws.name,
            "slug" => ws.slug,
            "repo_path" => ws.repo_path,
            "tech_context" => ws.tech_context,
            "default_workflow" => ws.default_workflow,
            "default_branch" => ws.default_branch || "main"
          }
          |> to_form()

        {:noreply, assign(socket, editing: ws, show_form: true, form: form)}

      _ ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}
    end
  end

  def handle_event("save", %{"name" => _, "slug" => _} = params, socket) do
    case socket.assigns.editing do
      %WorkspaceProfile{} = ws ->
        case WorkspaceProfiles.update_workspace(ws, params) do
          {:ok, _ws} ->
            {:noreply,
             socket
             |> assign(
               workspaces: WorkspaceProfiles.list_workspaces(),
               show_form: false,
               editing: nil,
               form: new_form()
             )
             |> put_flash(:info, "Workspace updated")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset.changes))}
        end

      nil ->
        case WorkspaceProfiles.create_workspace(params) do
          {:ok, _ws} ->
            {:noreply,
             socket
             |> assign(
               workspaces: WorkspaceProfiles.list_workspaces(),
               show_form: false,
               form: new_form()
             )
             |> put_flash(:info, "Workspace created")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset.changes))}
        end
    end
  end

  def handle_event("open_browser", _params, socket) do
    start = browser_start_dir(socket.assigns.form[:repo_path].value)
    {:noreply, open_browser(socket, start)}
  end

  def handle_event("close_browser", _params, socket) do
    {:noreply, assign(socket, browser_open: false, browser_entries: [])}
  end

  def handle_event("browse_to", %{"path" => path}, socket) do
    {:noreply, open_browser(socket, path)}
  end

  def handle_event("select_dir", %{"path" => path}, socket) do
    form =
      socket.assigns.form
      |> form_with(:repo_path, path)

    {:noreply,
     assign(socket, form: form, browser_open: false, browser_entries: [], browser_cwd: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case WorkspaceProfiles.get_workspace(id) do
      %WorkspaceProfile{} = ws ->
        case WorkspaceProfiles.delete_workspace(ws) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(workspaces: WorkspaceProfiles.list_workspaces())
             |> put_flash(:info, "Workspace deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete workspace")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_path={@current_path} flash={@flash}>
      <div class="min-h-screen bg-[#0a0a0a] text-[#e0e0e0] p-6">
        <div class="max-w-4xl mx-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-6">
            <div>
              <h1 class="text-lg font-headline text-[#ffa44c] tracking-widest">WORKSPACE_PROFILES</h1>
              <p class="text-[10px] text-[#b0b0b0] font-label tracking-wider mt-1">
                TARGET CODEBASE FOR INBOX → CARD PIPELINE
              </p>
            </div>
            <button
              phx-click="toggle_form"
              class="px-4 py-2 bg-[#ffa44c] text-black font-label text-[10px] font-bold uppercase tracking-widest hover:brightness-110 transition-all"
            >
              {if @show_form, do: "CANCEL", else: "NEW_WORKSPACE"}
            </button>
          </div>

          <%!-- Create/Edit Form --%>
          <div :if={@show_form} class="mb-6 p-4 border border-[#ffa44c]/20 bg-[#111111]">
            <h2 class="text-[11px] font-headline text-[#ffa44c] tracking-widest mb-4">
              {if @editing, do: "EDIT_WORKSPACE", else: "NEW_WORKSPACE"}
            </h2>
            <form phx-submit="save" class="space-y-3">
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="block text-[9px] text-[#b0b0b0] font-label uppercase tracking-widest mb-1">
                    NAME
                  </label>
                  <input
                    type="text"
                    name="name"
                    value={@form[:name].value}
                    required
                    class="w-full bg-[#1a1a1a] border border-[#494847]/30 text-[#e0e0e0] text-xs px-3 py-2 focus:border-[#ffa44c]/50 focus:outline-none"
                  />
                </div>
                <div>
                  <label class="block text-[9px] text-[#b0b0b0] font-label uppercase tracking-widest mb-1">
                    SLUG
                  </label>
                  <input
                    type="text"
                    name="slug"
                    value={@form[:slug].value}
                    required
                    pattern="[a-z0-9_-]+"
                    class="w-full bg-[#1a1a1a] border border-[#494847]/30 text-[#e0e0e0] text-xs px-3 py-2 focus:border-[#ffa44c]/50 focus:outline-none"
                  />
                </div>
              </div>
              <div>
                <label class="block text-[9px] text-[#b0b0b0] font-label uppercase tracking-widest mb-1">
                  REPO_PATH
                </label>
                <div class="flex gap-2">
                  <input
                    type="text"
                    name="repo_path"
                    value={@form[:repo_path].value}
                    required
                    class="flex-1 bg-[#1a1a1a] border border-[#494847]/30 text-[#e0e0e0] text-xs px-3 py-2 focus:border-[#ffa44c]/50 focus:outline-none"
                    placeholder="/path/to/your/repo"
                  />
                  <button
                    type="button"
                    phx-click="open_browser"
                    class="px-3 py-2 border border-[#ffa44c]/30 text-[#ffa44c] font-label text-[10px] uppercase tracking-widest hover:bg-[#ffa44c]/10 transition-all"
                  >
                    BROWSE
                  </button>
                </div>
              </div>
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <label class="block text-[9px] text-[#b0b0b0] font-label uppercase tracking-widest mb-1">
                    DEFAULT_WORKFLOW
                  </label>
                  <input
                    type="text"
                    name="default_workflow"
                    value={@form[:default_workflow].value || "coding-sprint"}
                    class="w-full bg-[#1a1a1a] border border-[#494847]/30 text-[#e0e0e0] text-xs px-3 py-2 focus:border-[#ffa44c]/50 focus:outline-none"
                  />
                </div>
                <div>
                  <label class="block text-[9px] text-[#b0b0b0] font-label uppercase tracking-widest mb-1">
                    DEFAULT_BRANCH
                  </label>
                  <input
                    type="text"
                    name="default_branch"
                    value={@form[:default_branch].value || "main"}
                    class="w-full bg-[#1a1a1a] border border-[#494847]/30 text-[#e0e0e0] text-xs px-3 py-2 focus:border-[#ffa44c]/50 focus:outline-none"
                    placeholder="main"
                  />
                </div>
              </div>
              <div>
                <label class="block text-[9px] text-[#b0b0b0] font-label uppercase tracking-widest mb-1">
                  TECH_CONTEXT
                </label>
                <textarea
                  name="tech_context"
                  rows="6"
                  class="w-full bg-[#1a1a1a] border border-[#494847]/30 text-[#e0e0e0] text-xs px-3 py-2 focus:border-[#ffa44c]/50 focus:outline-none font-mono"
                  placeholder="Describe the tech stack, key directories, and architecture..."
                ><%= @form[:tech_context].value %></textarea>
              </div>
              <button
                type="submit"
                class="px-6 py-2 bg-[#00FF41] text-black font-label text-[10px] font-bold uppercase tracking-widest hover:brightness-110 transition-all"
              >
                {if @editing, do: "UPDATE", else: "CREATE"}
              </button>
            </form>
          </div>

          <%!-- Workspace List --%>
          <div class="space-y-2">
            <div
              :for={ws <- @workspaces}
              class="p-4 border border-[#494847]/20 bg-[#111111] hover:border-[#ffa44c]/30 transition-all"
            >
              <div class="flex items-start justify-between">
                <div class="flex-1">
                  <div class="flex items-center gap-3 mb-1">
                    <span class="text-sm font-headline text-[#ffa44c]">{ws.name}</span>
                    <span class="text-[9px] font-label text-[#00eefc] bg-[#00eefc]/10 px-2 py-0.5 tracking-wider">
                      {ws.slug}
                    </span>
                    <span class="text-[9px] font-label text-[#b0b0b0] tracking-wider">
                      {ws.default_workflow}
                    </span>
                    <span
                      :if={ws.default_branch && ws.default_branch != "main"}
                      class="text-[9px] font-label text-[#ff725e] bg-[#ff725e]/10 px-2 py-0.5 tracking-wider"
                    >
                      {ws.default_branch}
                    </span>
                  </div>
                  <div class="text-[10px] text-[#adaaaa] font-mono">{ws.repo_path}</div>
                  <div
                    :if={ws.tech_context != ""}
                    class="text-[10px] text-[#808080] mt-2 line-clamp-2"
                  >
                    {String.slice(ws.tech_context, 0, 200)}{if String.length(ws.tech_context) > 200,
                      do: "..."}
                  </div>
                </div>
                <div class="flex gap-2 ml-4">
                  <button
                    phx-click="edit"
                    phx-value-id={ws.id}
                    class="px-3 py-1 border border-[#494847] text-[#adaaaa] font-label text-[9px] uppercase tracking-widest hover:border-[#ffa44c]/50 hover:text-[#ffa44c] transition-all"
                  >
                    EDIT
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-id={ws.id}
                    data-confirm="Delete workspace '#{ws.name}'?"
                    class="px-3 py-1 border border-[#494847] text-[#ff725e] font-label text-[9px] uppercase tracking-widest hover:border-[#ff725e]/50 transition-all"
                  >
                    DELETE
                  </button>
                </div>
              </div>
            </div>

            <div :if={@workspaces == []} class="text-center py-12 text-[#494847]">
              <p class="text-[11px] font-label uppercase tracking-widest">NO_WORKSPACES_CONFIGURED</p>
              <p class="text-[10px] mt-2">CLICK_NEW_WORKSPACE_TO_ADD_PROFILE</p>
            </div>
          </div>

          <%!-- Directory browser modal --%>
          <div
            :if={@browser_open}
            class="fixed inset-0 z-[120] flex items-center justify-center p-8 backdrop-blur-md bg-black/60"
            phx-window-keydown="close_browser"
            phx-key="Escape"
          >
            <div
              class="w-full max-w-2xl bg-[#0a0a0a] border border-[#ffa44c]/30 flex flex-col max-h-[80vh]"
              phx-click-away="close_browser"
            >
              <div class="flex items-center justify-between px-4 py-3 border-b border-[#494847]/30 bg-[#111]">
                <div class="text-[10px] font-headline text-[#ffa44c] tracking-[0.3em] uppercase">
                  PICK_DIRECTORY
                </div>
                <button
                  type="button"
                  phx-click="close_browser"
                  class="text-[#ffa44c]/60 hover:text-[#ffa44c] text-xs font-label uppercase tracking-widest"
                >
                  CLOSE
                </button>
              </div>

              <%!-- Breadcrumb --%>
              <div class="px-4 py-2 border-b border-[#494847]/20 flex items-center gap-1 flex-wrap text-[11px] font-mono">
                <button
                  type="button"
                  phx-click="browse_to"
                  phx-value-path="/"
                  class="text-[#00eefc] hover:text-white transition-colors"
                >
                  /
                </button>
                <span :for={crumb <- breadcrumbs(@browser_cwd)} class="flex items-center gap-1">
                  <button
                    type="button"
                    phx-click="browse_to"
                    phx-value-path={crumb.path}
                    class="text-[#00eefc] hover:text-white transition-colors"
                  >
                    {crumb.name}
                  </button>
                  <span class="text-[#494847]">/</span>
                </span>
              </div>

              <%!-- Entry list --%>
              <div class="flex-1 overflow-y-auto">
                <button
                  :if={@browser_cwd && @browser_cwd != "/"}
                  type="button"
                  phx-click="browse_to"
                  phx-value-path={Path.dirname(@browser_cwd)}
                  class="w-full flex items-center gap-3 px-4 py-2 text-left border-b border-[#494847]/10 hover:bg-[#ffa44c]/5 transition-all"
                >
                  <span class="material-symbols-outlined text-[#777] text-base">arrow_upward</span>
                  <span class="text-xs font-mono text-[#adaaaa]">..</span>
                </button>

                <button
                  :for={entry <- @browser_entries}
                  type="button"
                  phx-click="browse_to"
                  phx-value-path={entry.full}
                  class="w-full flex items-center gap-3 px-4 py-2 text-left border-b border-[#494847]/10 hover:bg-[#ffa44c]/5 transition-all"
                >
                  <span class="material-symbols-outlined text-[#ffa44c]/60 text-base">folder</span>
                  <span class="text-xs font-mono text-[#e0e0e0]">{entry.name}</span>
                </button>

                <div
                  :if={@browser_entries == [] && @browser_cwd}
                  class="px-4 py-6 text-center text-[10px] font-label text-[#494847] uppercase tracking-widest"
                >
                  EMPTY_OR_UNREADABLE
                </div>
              </div>

              <%!-- Footer with current path + select --%>
              <div class="px-4 py-3 border-t border-[#494847]/30 bg-[#111] flex items-center gap-3">
                <span class="text-[10px] font-label text-[#b0b0b0] uppercase tracking-widest">
                  SELECTED:
                </span>
                <span class="flex-1 text-[11px] font-mono text-[#00eefc] truncate">
                  {@browser_cwd}
                </span>
                <button
                  type="button"
                  phx-click="select_dir"
                  phx-value-path={@browser_cwd}
                  class="px-4 py-2 bg-[#00FF41] text-black font-label text-[10px] font-bold uppercase tracking-widest hover:brightness-110 transition-all"
                >
                  USE_THIS
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Build breadcrumb segments for the browser modal — pure list of
  # %{name, path} entries from root to the current dir.
  defp breadcrumbs(nil), do: []

  defp breadcrumbs(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/", trim: true)
    |> Enum.reduce({[], "/"}, fn part, {acc, prefix} ->
      next = Path.join(prefix, part)
      {acc ++ [%{name: part, path: next}], next}
    end)
    |> elem(0)
  end

  defp new_form do
    %{
      "name" => "",
      "slug" => "",
      "repo_path" => "",
      "tech_context" => "",
      "default_workflow" => "coding-sprint",
      "default_branch" => "main"
    }
    |> to_form()
  end

  # Open the directory browser at `path`, snapping to a real directory if
  # the requested one is missing or unreadable.
  defp open_browser(socket, path) do
    cwd = resolve_dir(path)

    assign(socket,
      browser_open: true,
      browser_cwd: cwd,
      browser_entries: list_subdirs(cwd)
    )
  end

  defp browser_start_dir(""), do: System.user_home!() || "/"
  defp browser_start_dir(nil), do: System.user_home!() || "/"
  defp browser_start_dir(path) when is_binary(path), do: path

  defp resolve_dir(nil), do: System.user_home!() || "/"

  defp resolve_dir(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) -> expanded
      File.dir?(Path.dirname(expanded)) -> Path.dirname(expanded)
      true -> System.user_home!() || "/"
    end
  end

  # Return a stable list of subdirectories for the given path. Hides dotfiles
  # so the picker isn't drowned in `.git`/`.cache` etc.
  defp list_subdirs(path) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(fn name ->
          full = Path.join(path, name)
          %{name: name, full: full, is_dir: File.dir?(full)}
        end)
        |> Enum.filter(& &1.is_dir)
        |> Enum.sort_by(&String.downcase(&1.name))

      _ ->
        []
    end
  end

  # Rebuild the form keeping existing values for every other field.
  # We don't lean on `form.params` here — accessing `form[:k].value` works
  # whether the form was built from a map or a changeset.
  defp form_with(form, key, value) do
    %{
      "name" => form[:name].value || "",
      "slug" => form[:slug].value || "",
      "repo_path" => form[:repo_path].value || "",
      "tech_context" => form[:tech_context].value || "",
      "default_workflow" => form[:default_workflow].value || "coding-sprint",
      "default_branch" => form[:default_branch].value || "main"
    }
    |> Map.put(to_string(key), value)
    |> to_form()
  end
end
