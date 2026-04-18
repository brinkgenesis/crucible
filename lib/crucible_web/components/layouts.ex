defmodule CrucibleWeb.Layouts do
  @moduledoc """
  Layouts for the NERV Command OS orchestrator dashboard.
  Provides a tactical HUD-style app shell.
  """
  use CrucibleWeb, :html

  @doc """
  NERV-style sidebar navigation link with Material Symbol icon.
  """
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, required: true

  def nerv_nav_link(assigns) do
    active =
      assigns.current == assigns.path or
        (assigns.path != "/" and String.starts_with?(assigns.current, assigns.path))

    assigns = assign(assigns, :active, active)

    ~H"""
    <a
      href={@path}
      aria-current={@active && "page"}
      class={[
        "w-full flex items-center gap-3 px-3 py-2 font-label text-[10px] uppercase tracking-widest transition-all",
        @active && "bg-[#ffa44c] text-[#000000] font-bold",
        !@active && "text-[#ffa44c]/60 hover:bg-[#00eefc]/10 hover:text-[#00eefc]"
      ]}
    >
      <span class="material-symbols-outlined text-sm" aria-hidden="true">{@icon}</span>
      {@label}
    </a>
    """
  end

  @doc """
  Legacy sidebar navigation link — kept for compatibility.
  """
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, required: true

  def nav_link(assigns) do
    active =
      assigns.current == assigns.path or
        (assigns.path != "/" and String.starts_with?(assigns.current, assigns.path))

    assigns = assign(assigns, :active, active)

    ~H"""
    <a href={@path} class={["gap-3", @active && "active"]}>
      <.icon name={@icon} class="size-4" />
      {@label}
    </a>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("CONNECTION_LOST")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("RECONNECTING")}
        <span class="material-symbols-outlined text-sm ml-1 animate-spin">sync</span>
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("SYSTEM_ERROR")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("RECONNECTING")}
        <span class="material-symbols-outlined text-sm ml-1 animate-spin">sync</span>
      </.flash>
    </div>
    """
  end

  @doc """
  Theme toggle — simplified for NERV (dark-only, kept for compatibility).
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="text-[9px] font-label text-[#ffa44c]/30 tracking-widest text-center">
      NERV_OS v2.6
    </div>
    """
  end

  embed_templates "layouts/*"
end
