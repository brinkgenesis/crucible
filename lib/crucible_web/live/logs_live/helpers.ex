defmodule CrucibleWeb.LogsLive.Helpers do
  @moduledoc """
  Formatting and classification helpers for the log viewer LiveView.

  Pure functions with no side-effects — every function takes a value and returns
  a string (usually a CSS class or formatted label). Extracted from `LogsLive`
  to keep the main module focused on LiveView lifecycle and event handling.
  """

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  @doc "Formats a timestamp value for display (HH:MM:SS)."
  @spec format_time(any()) :: String.t()
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  def format_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  def format_time(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  def format_time(_), do: "—"

  @doc "Human-readable file size (B / KB / MB)."
  @spec format_size(number()) :: String.t()
  def format_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  def format_size(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)}KB"
  def format_size(bytes), do: "#{bytes}B"

  @doc "Formats a savings ratio as a percentage string."
  @spec format_ratio(number() | nil) :: String.t()
  def format_ratio(nil), do: "—"
  def format_ratio(r) when is_number(r), do: "#{Float.round(r * 100.0, 1)}%"

  @doc "Truncates an args map/value to a short display string (max 40 chars)."
  @spec truncate_args(any()) :: String.t()
  def truncate_args(nil), do: "—"

  def truncate_args(args) when is_map(args) do
    s = inspect(args, limit: 5, printable_limit: 30)
    if String.length(s) > 40, do: String.slice(s, 0, 37) <> "...", else: s
  end

  def truncate_args(args), do: inspect(args) |> String.slice(0, 40)

  @doc "Extracts the last segment of a dotted module name."
  @spec short_module(String.t() | nil) :: String.t() | nil
  def short_module(nil), do: nil
  def short_module(mod) when is_binary(mod), do: mod |> String.split(".") |> List.last()

  # ---------------------------------------------------------------------------
  # HUD CSS class helpers
  # ---------------------------------------------------------------------------

  @doc "CSS classes for a tool badge in cost/audit rows."
  @spec tool_hud_class(String.t() | nil) :: String.t()
  def tool_hud_class(nil), do: "bg-[#494847]/10 text-[#494847]"
  def tool_hud_class("Read"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  def tool_hud_class("Edit"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
  def tool_hud_class("Write"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
  def tool_hud_class("Bash"), do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
  def tool_hud_class("Grep"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  def tool_hud_class("Glob"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  def tool_hud_class("Agent"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"

  def tool_hud_class("mcp__" <> _),
    do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  def tool_hud_class(_), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  @doc "CSS classes for audit status badges."
  @spec audit_hud_class(String.t() | nil) :: String.t()
  def audit_hud_class("success"), do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
  def audit_hud_class("error"), do: "bg-[#ff7351] text-black"
  def audit_hud_class(_), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  @doc "CSS classes for session event badges."
  @spec session_hud_class(String.t() | nil) :: String.t()
  def session_hud_class("session_start"),
    do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"

  def session_hud_class("session_end"),
    do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  def session_hud_class("session_stop"),
    do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  def session_hud_class(_), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  @doc "Color class for savings ratio display."
  @spec savings_hud_color(number() | nil) :: String.t()
  def savings_hud_color(nil), do: "text-[#494847]"
  def savings_hud_color(r) when is_number(r) and r >= 0.5, do: "text-[#ffa44c]"
  def savings_hud_color(r) when is_number(r) and r >= 0.2, do: "text-[#00eefc]"
  def savings_hud_color(_), do: "text-[#494847]"

  @doc "Left-border color class for server log level."
  @spec level_border(atom()) :: String.t()
  def level_border(:error), do: "border-[#ff7351]"
  def level_border(:warning), do: "border-[#ffa44c]"
  def level_border(:info), do: "border-[#00eefc]"
  def level_border(:debug), do: "border-[#494847]/20"
  def level_border(_), do: "border-[#494847]/10"

  @doc "Badge classes for server log level pills."
  @spec level_hud_badge(atom()) :: String.t()
  def level_hud_badge(:error), do: "bg-[#ff7351] text-black"
  def level_hud_badge(:warning), do: "bg-[#ffa44c] text-black"
  def level_hud_badge(:info), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  def level_hud_badge(:debug), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"
  def level_hud_badge(_), do: "bg-[#494847]/10 text-[#494847]"

  @doc "Returns {css_class, label} for an agent trace event badge."
  @spec agent_event_badge_attrs(String.t() | nil) :: {String.t(), String.t()}
  def agent_event_badge_attrs("subagent_start"),
    do: {"bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30", "START"}

  def agent_event_badge_attrs("subagent_stop"),
    do: {"bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30", "STOP"}

  def agent_event_badge_attrs("teammate_idle"),
    do: {"bg-[#494847]/10 text-[#494847] border border-[#494847]/30", "IDLE"}

  def agent_event_badge_attrs("ghost_agent_detected"), do: {"bg-[#ff7351] text-black", "GHOST"}

  def agent_event_badge_attrs(e) when is_binary(e),
    do: {"bg-[#494847]/10 text-[#494847] border border-[#494847]/30", String.upcase(e)}

  def agent_event_badge_attrs(_), do: {"bg-[#494847]/10 text-[#494847]", "—"}
end
