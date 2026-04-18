defmodule Crucible.TraceExtractors do
  @moduledoc """
  Pure extraction functions for trace event analysis.

  Extracts phases, tools, costs, files, tasks, and agents from
  trace event lists. No DB or file I/O — operates on in-memory data only.

  Extracted from TraceReader to reduce the 2400-line monolith.
  """

  # ── Phases ──────────────────────────────────────────────────────────────────

  @doc "Extract phase timeline from trace events."
  def extract_phases(events) do
    starts =
      events
      |> Enum.filter(&(&1["eventType"] == "phase_start"))
      |> Enum.group_by(&(&1["phaseId"]))
      |> Enum.map(fn {_id, group} -> List.last(group) end)
      |> Enum.sort_by(&phase_index_from_id(&1["phaseId"]))

    if starts != [] do
      extract_phases_from_start_end(events, starts)
    else
      synthesize_phases_from_costs(events)
    end
  end

  defp extract_phases_from_start_end(events, starts) do
    ends = Enum.filter(events, &(&1["eventType"] == "phase_end"))
    end_map = Map.new(ends, &{&1["phaseId"], &1})

    phases =
      Enum.map(starts, fn s ->
        phase_id = s["phaseId"]
        e = Map.get(end_map, phase_id)
        meta = s["metadata"] || %{}
        end_meta = if is_map(e), do: e["metadata"] || %{}, else: %{}

        started_at = s["timestamp"]
        ended_at = if is_map(e), do: e["timestamp"], else: nil

        %{
          phase_id: phase_id,
          phase_name: format_phase_name(meta["phaseName"] || s["detail"] || phase_id),
          phase_type: meta["phaseType"] || "session",
          phase_index: phase_index_from_id(phase_id),
          status: end_meta["status"] || (if(e, do: "done", else: "running")),
          started_at: started_at,
          ended_at: ended_at,
          duration_ms: phase_duration_ms(%{started_at: started_at, ended_at: ended_at}),
          agents: meta["agents"] || [],
          adapter: meta["adapter"] || end_meta["adapter"],
          structured_output: end_meta["structuredOutput"]
        }
      end)

    rebase_phase_timestamps(phases)
    |> Enum.uniq_by(& &1.phase_id)
  end

  def rebase_phase_timestamps([]), do: []

  def rebase_phase_timestamps([first | rest]) do
    {rebased, _} =
      Enum.map_reduce(rest, first, fn phase, prev ->
        if phase.started_at && prev.ended_at && phase.started_at < prev.ended_at do
          gap_ms = phase_duration_ms(%{started_at: prev.ended_at, ended_at: phase.started_at})

          if gap_ms < 0 do
            offset = abs(gap_ms) + 1000
            shifted = %{
              phase
              | started_at: shift_iso(phase.started_at, offset),
                ended_at:
                  if(phase.ended_at, do: shift_iso(phase.ended_at, offset), else: nil)
            }

            {shifted, shifted}
          else
            {phase, phase}
          end
        else
          {phase, phase}
        end
      end)

    [first | rebased]
  end

  defp synthesize_phases_from_costs(events) do
    events
    |> Enum.filter(&(&1["eventType"] == "token_efficiency"))
    |> Enum.group_by(&(&1["phaseId"]))
    |> Enum.map(fn {phase_id, group} ->
      sorted = Enum.sort_by(group, & &1["timestamp"])
      first = List.first(sorted)
      last = List.last(sorted)
      meta = (first && first["metadata"]) || %{}

      %{
        phase_id: phase_id,
        phase_name: format_phase_name(phase_id),
        phase_type: "session",
        phase_index: phase_index_from_id(phase_id),
        status: if(meta["result"] == "success", do: "done", else: meta["result"] || "unknown"),
        started_at: first && first["timestamp"],
        ended_at: last && last["timestamp"],
        duration_ms:
          phase_duration_ms(%{
            started_at: first && first["timestamp"],
            ended_at: last && last["timestamp"]
          }),
        agents: [],
        adapter: nil,
        structured_output: nil
      }
    end)
    |> Enum.sort_by(& &1.phase_index)
  end

  # ── Tools ───────────────────────────────────────────────────────────────────

  @doc "Extract tool usage distribution from events."
  def extract_tool_distribution(events) do
    events
    |> Enum.filter(&(&1["eventType"] == "tool_call"))
    |> Enum.group_by(& &1["tool"])
    |> Enum.map(fn {tool, calls} -> %{tool: tool || "unknown", count: length(calls)} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  # ── Costs ───────────────────────────────────────────────────────────────────

  @doc "Extract cost information from token_efficiency events."
  def extract_costs(events) do
    events
    |> Enum.filter(&(&1["eventType"] == "token_efficiency"))
    |> Enum.map(fn e ->
      meta = e["metadata"] || %{}

      %{
        phase_id: e["phaseId"],
        cost_usd: safe_float(meta["budget_usd"]),
        input_tokens: safe_int(meta["input_tokens"]),
        output_tokens: safe_int(meta["output_tokens"]),
        cache_read_tokens: safe_int(meta["cache_read_tokens"]),
        result: meta["result"],
        retry_count: safe_int(meta["retry_count"]),
        duration_ms: metadata_duration_ms(meta)
      }
    end)
  end

  # ── Files ───────────────────────────────────────────────────────────────────

  @doc "Extract file modifications from events."
  def extract_files(events) do
    tool_files =
      events
      |> Enum.filter(fn e ->
        e["eventType"] == "tool_call" and e["tool"] in ["Write", "Edit", "write_file", "edit_file"]
      end)
      |> Enum.map(fn e ->
        meta = e["metadata"] || %{}
        %{file: meta["filePath"] || e["detail"], action: e["tool"], phase_id: e["phaseId"]}
      end)
      |> Enum.reject(&is_nil(&1.file))

    sdk_files =
      events
      |> Enum.filter(&(&1["eventType"] in ["phase_end", "checkpoint"]))
      |> Enum.flat_map(fn e ->
        meta = e["metadata"] || %{}
        so = meta["structuredOutput"] || %{}
        exec = so["execution"] || %{}
        modified = exec["filesModified"] || []
        created = exec["filesCreated"] || []

        Enum.map(modified, &%{file: &1, action: "Edit", phase_id: e["phaseId"]}) ++
          Enum.map(created, &%{file: &1, action: "Write", phase_id: e["phaseId"]})
      end)

    (tool_files ++ sdk_files) |> Enum.uniq_by(&{&1.file, &1.action})
  end

  # ── Tasks ───────────────────────────────────────────────────────────────────

  @doc "Extract task events."
  def extract_tasks(events) do
    events
    |> Enum.filter(&(&1["eventType"] == "task_update"))
    |> Enum.map(fn e ->
      meta = e["metadata"] || %{}
      %{task_id: meta["taskId"], status: meta["status"], title: meta["title"], phase_id: e["phaseId"]}
    end)
  end

  # ── Agents ──────────────────────────────────────────────────────────────────

  @doc "Extract agent info from phase_start events, deduplicated."
  def extract_agents(events) do
    from_phases =
      events
      |> Enum.filter(&(&1["eventType"] == "phase_start"))
      |> Enum.flat_map(fn e ->
        meta = e["metadata"] || %{}
        phase_id = e["phaseId"]
        phase_name = meta["phaseName"] || e["detail"] || phase_id

        (meta["agents"] || [])
        |> Enum.map(fn name ->
          %{name: name, phase_id: phase_id, phase_name: phase_name, source: "phase_start"}
        end)
      end)

    agent_tool_calls =
      Enum.filter(events, &(&1["eventType"] == "tool_call" and &1["tool"] == "Agent"))

    from_tool_calls =
      agent_tool_calls
      |> Enum.map(fn e ->
        detail = e["detail"]
        name = if is_binary(detail) and detail != "", do: detail, else: nil
        %{name: name, phase_id: e["phaseId"], source: "tool_call"}
      end)
      |> Enum.reject(&is_nil(&1.name))

    raw_agents = if from_phases != [], do: from_phases, else: from_tool_calls
    agents = raw_agents |> Enum.uniq_by(& &1.name) |> Enum.reject(&is_nil(&1.name))
    %{agents: agents, agent_spawn_count: length(agent_tool_calls)}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  def phase_duration_ms(%{started_at: s, ended_at: e}) when is_binary(s) and is_binary(e) do
    with {:ok, sd, _} <- DateTime.from_iso8601(s),
         {:ok, ed, _} <- DateTime.from_iso8601(e) do
      max(DateTime.diff(ed, sd, :millisecond), 0)
    else
      _ -> 0
    end
  end

  def phase_duration_ms(_), do: 0

  def shift_iso(iso_string, add_ms) when is_binary(iso_string) and is_integer(add_ms) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> DateTime.add(dt, add_ms, :millisecond) |> DateTime.to_iso8601()
      _ -> iso_string
    end
  end

  def shift_iso(iso_string, _), do: iso_string

  def phase_index_from_id(nil), do: 0

  def phase_index_from_id(phase_id) when is_binary(phase_id) do
    case Regex.run(~r/-p(\d+)$/, phase_id) do
      [_, index] -> String.to_integer(index)
      _ -> 0
    end
  end

  def format_phase_name(nil), do: "unknown"

  def format_phase_name(name) do
    name
    |> String.replace(~r/^[a-z0-9]+-p\d+-?/, "")
    |> then(fn n -> if n == "", do: name, else: n end)
  end

  def safe_float(nil), do: 0.0

  def safe_float(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  def safe_float(value) when is_number(value), do: value / 1
  def safe_float(_), do: 0.0

  defp safe_int(nil), do: 0
  defp safe_int(value) when is_integer(value), do: value

  defp safe_int(value) when is_binary(value) do
    String.to_integer(value)
  rescue
    _ -> 0
  end

  defp safe_int(value) when is_float(value), do: round(value)
  defp safe_int(_), do: 0

  def metadata_duration_ms(metadata) when is_map(metadata) do
    case metadata["duration_ms"] || metadata["durationMs"] do
      nil -> 0
      val when is_number(val) -> round(val)
      val when is_binary(val) ->
        try do
          String.to_integer(val)
        rescue
          _ -> 0
        end
    end
  end

  def metadata_duration_ms(_), do: 0
end
