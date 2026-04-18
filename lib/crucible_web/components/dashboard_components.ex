defmodule CrucibleWeb.DashboardComponents do
  @moduledoc """
  Shared function components for dashboard-style LiveViews.
  NERV tactical HUD styling.
  """
  use Phoenix.Component

  @doc """
  Renders a mini stat card with NERV HUD styling.
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :subtitle, :string, default: nil

  attr :tone, :string,
    default: nil,
    values: [nil, "primary", "accent", "success", "info", "warning"]

  def mini_stat(assigns) do
    ~H"""
    <div class="bg-surface-container-low p-4 hud-border">
      <div class="text-[10px] font-label tracking-widest uppercase text-[#ffa44c]/60">{@title}</div>
      <div class={["text-lg font-headline font-bold font-mono", tone_class(@tone)]}>
        {@value}
      </div>
      <div :if={@subtitle} class="text-[10px] font-label text-[#adaaaa]/60 mt-1">
        {@subtitle}
      </div>
    </div>
    """
  end

  defp tone_class(nil), do: "text-[#ffa44c]"
  defp tone_class("primary"), do: "text-[#ffa44c]"
  defp tone_class("accent"), do: "text-[#fd9000]"
  defp tone_class("success"), do: "text-[#00FF41]"
  defp tone_class("info"), do: "text-[#00eefc]"
  defp tone_class("warning"), do: "text-[#ff725e]"

  @doc """
  Renders pagination controls with NERV tactical styling.
  """
  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :page_size, :integer, required: true
  attr :event, :string, required: true

  def pagination(assigns) do
    total_pages = max(1, ceil(assigns.total / assigns.page_size))
    first = min((assigns.page - 1) * assigns.page_size + 1, assigns.total)
    last = min(assigns.page * assigns.page_size, assigns.total)

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:first, first)
      |> assign(:last, last)

    ~H"""
    <div :if={@total > @page_size} class="flex items-center justify-between pt-2">
      <span class="text-[10px] font-label tracking-widest text-[#adaaaa]/60">
        SHOWING {@first}-{@last} OF {@total}
      </span>
      <div class="flex gap-1">
        <button
          phx-click={@event}
          phx-value-page={@page - 1}
          class="px-3 py-1 font-label text-[10px] tracking-widest border border-[#ffa44c]/20 text-[#ffa44c]/60 hover:text-[#00eefc] hover:border-[#00eefc]/30 transition-all disabled:opacity-30"
          disabled={@page <= 1}
        >
          PREV
        </button>
        <button
          phx-click={@event}
          phx-value-page={@page + 1}
          class="px-3 py-1 font-label text-[10px] tracking-widest border border-[#ffa44c]/20 text-[#ffa44c]/60 hover:text-[#00eefc] hover:border-[#00eefc]/30 transition-all disabled:opacity-30"
          disabled={@page >= @total_pages}
        >
          NEXT
        </button>
      </div>
    </div>
    """
  end
end
