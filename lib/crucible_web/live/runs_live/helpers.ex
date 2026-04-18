defmodule CrucibleWeb.RunsLive.Helpers do
  @moduledoc """
  Pure helper functions for RunsLive: status formatting, badge CSS classes,
  run filtering, sidebar styling, URL construction, and duration display utilities.

  All functions are side-effect-free — no socket or assign manipulation.
  """

  alias CrucibleWeb.Live.ScopeFilters

  @terminal_statuses ~w(done failed cancelled orphaned completed)

  # ---------------------------------------------------------------------------
  # Status Normalization
  # ---------------------------------------------------------------------------

  @doc """
  Normalize a status value (atom, string, or nil) to a consistent lowercase string.

  ## Examples

      iex> normalize_status(:running)
      "running"

      iex> normalize_status(nil)
      "unknown"
  """
  @spec normalize_status(atom() | String.t() | nil) :: String.t()
  def normalize_status(nil), do: "unknown"
  def normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  def normalize_status(status) when is_binary(status), do: status
  def normalize_status(_), do: "unknown"

  # ---------------------------------------------------------------------------
  # Status Display Labels
  # ---------------------------------------------------------------------------

  @doc """
  Convert a raw status to a human-readable display label.

  ## Examples

      iex> status_label("in_progress")
      "Running"

      iex> status_label("budget_paused")
      "Paused"
  """
  @spec status_label(atom() | String.t() | nil) :: String.t()
  def status_label(status) do
    case normalize_status(status) do
      s when s in ["running", "in_progress"] -> "Running"
      "pending" -> "Pending"
      s when s in ["done", "completed"] -> "Done"
      "failed" -> "Failed"
      "cancelled" -> "Cancelled"
      "orphaned" -> "Orphaned"
      "review" -> "Review"
      "timeout" -> "Timeout"
      "budget_paused" -> "Paused"
      "unknown" -> "Unknown"
      other -> String.capitalize(other)
    end
  end

  # ---------------------------------------------------------------------------
  # Status Badge CSS Classes
  # ---------------------------------------------------------------------------

  @doc """
  Return the badge CSS class for a given status, matching the design system
  classes used in `CoreComponents.status_badge/1`.

  ## Examples

      iex> status_badge_class("running")
      "badge-info"

      iex> status_badge_class("failed")
      "badge-error"
  """
  @spec status_badge_class(atom() | String.t() | nil) :: String.t()
  def status_badge_class(status) do
    case normalize_status(status) do
      s when s in ["running", "in_progress"] -> "badge-info"
      "pending" -> "badge-warning"
      s when s in ["done", "completed"] -> "badge-success"
      "failed" -> "badge-error"
      "review" -> "badge-secondary"
      "cancelled" -> "badge-ghost"
      "orphaned" -> "badge-warning"
      "timeout" -> "badge-warning"
      "budget_paused" -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  @doc """
  Return the inline text color class for a run status, used in sidebar cards.

  ## Examples

      iex> run_status_color("running")
      "text-[#00eefc]"

      iex> run_status_color("done")
      "text-[#ffa44c]"
  """
  @spec run_status_color(atom() | String.t() | nil) :: String.t()
  def run_status_color(status) do
    case normalize_status(status) do
      s when s in ["running", "in_progress"] -> "text-[#00eefc]"
      s when s in ["done", "completed"] -> "text-[#ffa44c]"
      "failed" -> "text-[#ff725e]"
      "pending" -> "text-[#ffa44c]/60"
      _ -> "text-white/40"
    end
  end

  @doc """
  Return the text color class for a phase status.
  """
  @spec phase_status_color(atom() | String.t()) :: String.t()
  def phase_status_color(status) do
    case to_string(status) do
      s when s in ["done", "completed"] -> "text-[#ffa44c]"
      s when s in ["running", "in_progress"] -> "text-[#00eefc]"
      "failed" -> "text-[#ff725e]"
      _ -> "text-white/40"
    end
  end

  @doc """
  Return the phase progress bar background class.
  """
  @spec phase_bar_class(atom() | String.t()) :: String.t()
  def phase_bar_class(status) do
    case to_string(status) do
      s when s in ["done", "completed"] ->
        "bg-[#ffa44c] shadow-[0_0_8px_rgba(255,164,76,0.5)]"

      s when s in ["running", "in_progress"] ->
        "bg-[#00eefc] shadow-[0_0_8px_rgba(0,238,252,0.5)] animate-pulse"

      "failed" ->
        "bg-[#ff725e] shadow-[0_0_8px_rgba(255,114,94,0.5)]"

      _ ->
        "bg-surface-container-high"
    end
  end

  @doc """
  Return the left-border class for a phase card.
  """
  @spec phase_card_border(atom() | String.t()) :: String.t()
  def phase_card_border(status) do
    case to_string(status) do
      s when s in ["done", "completed"] -> "border-l-2 border-l-[#00eefc]"
      s when s in ["running", "in_progress"] -> "border-l-2 border-l-[#00eefc]"
      "failed" -> "border-l-2 border-l-[#ff725e]"
      _ -> "border-l-2 border-l-white/10 opacity-50"
    end
  end

  # ---------------------------------------------------------------------------
  # Run Filtering
  # ---------------------------------------------------------------------------

  @doc """
  Return true if a status is terminal (the run has finished in some way).

  ## Examples

      iex> terminal?("done")
      true

      iex> terminal?("running")
      false
  """
  @spec terminal?(atom() | String.t() | nil) :: boolean()
  def terminal?(status), do: normalize_status(status) in @terminal_statuses

  @doc """
  Return true if a run can be cancelled (pending, running, or in_progress).
  """
  @spec cancellable?(atom() | String.t() | nil) :: boolean()
  def cancellable?(status), do: normalize_status(status) in ["pending", "running", "in_progress"]

  @doc """
  Filter a list of runs by status.

  ## Examples

      iex> filter_by_status(runs, "running")
      [%{status: "running", ...}]

      iex> filter_by_status(runs, :all)
      runs
  """
  @spec filter_by_status([map()], atom() | String.t()) :: [map()]
  def filter_by_status(runs, :all), do: runs
  def filter_by_status(runs, "all"), do: runs

  def filter_by_status(runs, status) do
    target = normalize_status(status)
    Enum.filter(runs, &(normalize_status(&1.status) == target))
  end

  @doc """
  Split runs into `{active, completed}` based on terminal status.
  """
  @spec partition_runs([map()]) :: {active :: [map()], completed :: [map()]}
  def partition_runs(runs) do
    Enum.split_with(runs, &(not terminal?(&1.status)))
  end

  # ---------------------------------------------------------------------------
  # Duration & Cost Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Format a duration in milliseconds to a human-readable string.

  Delegates to `CrucibleWeb.FormatHelpers.format_duration_ms/1` for
  consistency, but provides a standalone entry point for callers that don't
  import FormatHelpers.

  ## Examples

      iex> format_duration(65_000)
      "1m 5s"

      iex> format_duration(nil)
      "\u2014"
  """
  @spec format_duration(number() | nil) :: String.t()
  def format_duration(ms) when is_number(ms) and ms > 0 do
    s = div(trunc(ms), 1000)

    cond do
      s < 1 -> "<1s"
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      true -> "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
    end
  end

  def format_duration(_), do: "\u2014"

  @doc """
  Format a USD cost value to a two-decimal string.

  ## Examples

      iex> format_usd(1.5)
      "1.50"

      iex> format_usd(nil)
      "0.00"
  """
  @spec format_usd(number() | nil) :: String.t()
  def format_usd(value) when is_number(value),
    do: (value * 1.0) |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

  def format_usd(_), do: "0.00"

  # ---------------------------------------------------------------------------
  # Phase Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Calculate the completion percentage for a list of phases.
  Returns 0 when phases is empty.
  """
  @spec phase_completion_pct([map()]) :: non_neg_integer()
  def phase_completion_pct([]), do: 0

  def phase_completion_pct(phases) when is_list(phases) do
    total = length(phases)
    done = Enum.count(phases, &(to_string(&1.status) in ["done", "completed"]))
    round(done / total * 100)
  end

  @doc """
  Return the phase count for a run, preferring the `:phase_count` field
  and falling back to the length of `:phases`.
  """
  @spec run_phase_count(map()) :: non_neg_integer()
  def run_phase_count(run) do
    case Map.get(run, :phase_count) do
      count when is_integer(count) and count >= 0 -> count
      _ -> length(Map.get(run, :phases, []))
    end
  end

  # ---------------------------------------------------------------------------
  # Run Metadata Accessors
  # ---------------------------------------------------------------------------

  @doc """
  Extract the workspace path from a run map.
  """
  @spec run_workspace(map()) :: String.t() | nil
  def run_workspace(run) do
    Map.get(run, :workspace_path)
  end

  # ---------------------------------------------------------------------------
  # Sidebar Styling
  # ---------------------------------------------------------------------------

  @doc """
  Return Tailwind classes for a run entry in the detail-view sidebar.

  Styling depends on whether the run is selected and on its status:
  - Selected + running: cyan accent with overflow hidden
  - Selected + other: amber accent
  - Running (not selected): cyan hover border
  - Failed (not selected): red hover border
  - Default: amber hover border
  """
  @spec run_sidebar_class(map(), map() | nil) :: String.t()
  def run_sidebar_class(run, selected) do
    is_selected = selected && selected.id == run.id
    status = normalize_status(run.status)

    cond do
      is_selected && status in ["running", "in_progress"] ->
        "bg-surface-container-high border-[#00eefc]/30 relative overflow-hidden"

      is_selected ->
        "bg-surface-container-high border-[#ffa44c]/30"

      status in ["running", "in_progress"] ->
        "bg-surface-container-low border-[#00eefc]/10 hover:border-[#00eefc]"

      status == "failed" ->
        "bg-surface-container-low border-white/5 hover:border-[#ff725e]/50"

      true ->
        "bg-surface-container-low border-white/5 hover:border-[#ffa44c]/50"
    end
  end

  # ---------------------------------------------------------------------------
  # Scope Filtering
  # ---------------------------------------------------------------------------

  @doc """
  Filter runs by client and workspace scope filters.

  Delegates matching to `ScopeFilters.matches_client?/2` and
  `ScopeFilters.matches_workspace?/2`.
  """
  @spec apply_scope_filters([map()], String.t(), String.t()) :: [map()]
  def apply_scope_filters(runs, client_filter, workspace_filter) do
    Enum.filter(runs, fn run ->
      ScopeFilters.matches_client?(Map.get(run, :client_id), client_filter) and
        ScopeFilters.matches_workspace?(run_workspace(run), workspace_filter)
    end)
  end

  @doc """
  Build the client dropdown options from a list of runs.
  """
  @spec build_client_options([map()]) :: list()
  def build_client_options(runs) do
    runs
    |> Enum.map(&Map.get(&1, :client_id))
    |> ScopeFilters.client_options()
  end

  @doc """
  Build the workspace dropdown options from a list of runs.
  """
  @spec build_workspace_options([map()]) :: list()
  def build_workspace_options(runs) do
    runs
    |> Enum.map(&run_workspace/1)
    |> ScopeFilters.workspace_options()
  end

  # ---------------------------------------------------------------------------
  # URL Construction
  # ---------------------------------------------------------------------------

  @doc """
  Build the `/runs` or `/runs/:id` path with optional scope query params.
  """
  @spec runs_path(String.t() | nil, String.t(), String.t()) :: String.t()
  def runs_path(nil, client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/runs" <> encode_query(query)
  end

  def runs_path(id, client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/runs/#{id}" <> encode_query(query)
  end

  defp encode_query(query) when map_size(query) == 0, do: ""
  defp encode_query(query), do: "?" <> URI.encode_query(query)
end
