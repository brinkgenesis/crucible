defmodule CrucibleWeb.TeamsLive.Helpers do
  @moduledoc """
  Pure helper functions extracted from `TeamsLive`.

  Contains formatting, classification, and data-transformation utilities used by
  the Teams Activity LiveView. All functions are side-effect-free and operate on
  plain data (maps, strings, datetimes) so they are easy to test in isolation.
  """

  # ---------------------------------------------------------------------------
  # Time / Duration formatting
  # ---------------------------------------------------------------------------

  @doc """
  Converts a UTC timestamp to US Eastern Time (EDT, UTC-4) and formats as `HH:MM:SS`.

  Accepts ISO-8601 strings, `DateTime`, and `NaiveDateTime` structs.
  Returns `""` for `nil`, empty, or unparseable values.
  """
  # March–November is EDT (UTC-4)
  @eastern_offset_seconds -4 * 3600

  @spec format_event_time_eastern(term()) :: String.t()
  def format_event_time_eastern(nil), do: ""
  def format_event_time_eastern(""), do: ""

  def format_event_time_eastern(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        DateTime.add(dt, @eastern_offset_seconds, :second)
        |> Calendar.strftime("%H:%M:%S")

      _ ->
        String.slice(ts, 11, 8)
    end
  end

  def format_event_time_eastern(%DateTime{} = dt) do
    DateTime.add(dt, @eastern_offset_seconds, :second)
    |> Calendar.strftime("%H:%M:%S")
  end

  def format_event_time_eastern(%NaiveDateTime{} = ndt) do
    NaiveDateTime.add(ndt, @eastern_offset_seconds, :second)
    |> NaiveDateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 8)
  end

  def format_event_time_eastern(_), do: ""

  @doc """
  Formats a session's elapsed time from `first_seen` to `last_seen` as a compact
  human-readable string (e.g. `"42s"`, `"3m"`, `"1h 12m"`). Returns `"—"` on
  missing or unparseable timestamps.
  """
  @spec session_duration(map()) :: String.t()
  def session_duration(session) do
    with first when is_binary(first) <- session.first_seen,
         last when is_binary(last) <- session.last_seen,
         {:ok, d1, _} <- DateTime.from_iso8601(first),
         {:ok, d2, _} <- DateTime.from_iso8601(last) do
      secs = DateTime.diff(d2, d1)

      cond do
        secs < 60 -> "#{secs}s"
        secs < 3600 -> "#{div(secs, 60)}m"
        true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      end
    else
      _ -> "—"
    end
  end

  # ---------------------------------------------------------------------------
  # Event helpers
  # ---------------------------------------------------------------------------

  @doc """
  Extracts a field from an event map that may use atom or string keys.

  Events originating from Ecto/CostEventReader use atom keys while transcript-
  derived events use string keys.
  """
  @spec event_field(map(), atom()) :: term()
  def event_field(ev, key) when is_atom(key) do
    Map.get(ev, key) || Map.get(ev, to_string(key))
  end

  # ---------------------------------------------------------------------------
  # Session helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` when the session's `last_seen` timestamp is less than 5 minutes old.
  """
  @spec session_active?(map()) :: boolean()
  def session_active?(session) do
    case DateTime.from_iso8601(session.last_seen || "") do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt) < 300
      _ -> false
    end
  end

  @doc """
  Returns a short label for the session's workspace (the basename of its path),
  or `""` when no workspace path is set.
  """
  @spec workspace_label(map()) :: String.t()
  def workspace_label(session) do
    path = Map.get(session, :workspace_path) || ""
    if path == "", do: "", else: Path.basename(path)
  end

  # ---------------------------------------------------------------------------
  # CSS / UI classification
  # ---------------------------------------------------------------------------

  @doc """
  Returns Tailwind CSS classes for an agent-type badge in the HUD theme.
  """
  @spec agent_type_hud_class(String.t()) :: String.t()
  def agent_type_hud_class(type) do
    case type do
      t when t in ["coder", "coder-backend", "coder-runtime", "coder-frontend"] ->
        "bg-[#00eefc]/10 border-[#00eefc] text-[#00eefc]"

      "reviewer" ->
        "bg-[#ffa44c]/10 border-[#ffa44c] text-[#ffa44c]"

      "architect" ->
        "bg-[#ff725e]/10 border-[#ff725e] text-[#ff725e]"

      "tester" ->
        "bg-[#00FF41]/10 border-[#00FF41] text-[#00FF41]"

      "team-lead" ->
        "bg-[#ffa44c]/10 border-[#ffa44c] text-[#ffa44c]"

      _ ->
        "bg-[#494847]/10 border-[#494847] text-[#494847]"
    end
  end

  # ---------------------------------------------------------------------------
  # Team name / display
  # ---------------------------------------------------------------------------

  @doc """
  Converts a machine-generated team slug (e.g. `"coding-sprint-20b74058-p0"`)
  into a human-readable title (`"Coding Sprint"`).
  """
  @spec humanize_team_name(String.t()) :: String.t()
  def humanize_team_name(name) do
    result =
      cond do
        # Format: {workflow}-{8+ hex/alphanum}-p{N}
        match = Regex.run(~r/^(.+)-[a-z0-9]{6,12}-p\d+$/, name) ->
          Enum.at(match, 1)

        # Format: {workflow}-{8+ alphanum}-{N}
        match = Regex.run(~r/^(.+)-[a-z0-9]{6,12}-\d+$/, name) ->
          Enum.at(match, 1)

        true ->
          name
      end

    result
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  @doc """
  Picks the best human-readable display name for a team.

  Priority: first task subject → config description → humanized slug.
  """
  @spec team_display_name(map()) :: String.t()
  def team_display_name(team) do
    cond do
      match?(%{task_subjects: [s | _]} when is_binary(s) and s != "", team) ->
        hd(team.task_subjects)

      is_binary(Map.get(team, :description)) and Map.get(team, :description) != "" ->
        team.description

      true ->
        humanize_team_name(team.name)
    end
  end

  # ---------------------------------------------------------------------------
  # Codebase filtering
  # ---------------------------------------------------------------------------

  @doc """
  Builds the codebase dropdown options from a list of sessions.
  Always includes an "All Codebases" entry first.
  """
  @spec build_codebase_options([map()]) :: [%{value: String.t(), label: String.t()}]
  def build_codebase_options(sessions) do
    codebases =
      sessions
      |> Enum.map(&extract_codebase/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    [%{value: "all", label: "All Codebases"}] ++
      Enum.map(codebases, fn cb -> %{value: cb, label: cb} end)
  end

  @doc """
  Filters sessions to those matching the given codebase name.
  Passing `"all"` returns the list unchanged.
  """
  @spec filter_by_codebase([map()], String.t()) :: [map()]
  def filter_by_codebase(sessions, "all"), do: sessions

  def filter_by_codebase(sessions, codebase) do
    Enum.filter(sessions, fn sess -> extract_codebase(sess) == codebase end)
  end

  @doc """
  Extracts the codebase name (basename of `workspace_path`) from a session map.
  Returns `nil` when the path is missing or empty.
  """
  @spec extract_codebase(map()) :: String.t() | nil
  def extract_codebase(%{workspace_path: path}) when is_binary(path) and path != "" do
    Path.basename(path)
  end

  def extract_codebase(_), do: nil

  # ---------------------------------------------------------------------------
  # URL query encoding
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a map as a `?key=value&...` query string. Returns `""` for empty maps.
  """
  @spec encode_query(map()) :: String.t()
  def encode_query(query) when map_size(query) == 0, do: ""
  def encode_query(query), do: "?" <> URI.encode_query(query)
end
