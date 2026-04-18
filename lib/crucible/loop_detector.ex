defmodule Crucible.LoopDetector do
  @moduledoc """
  Five loop detection strategies for agentic editing sessions.
  Pure functions: accept event lists, return LoopReport maps.

  Ports lib/harness/loop-detection/loop-detector.ts with idiomatic Elixir.
  """

  @type severity :: :warn | :error
  @type loop_type :: :edit | :semantic | :coordination | :command | :retry

  @type loop_report :: %{
          type: loop_type(),
          severity: severity(),
          count: non_neg_integer(),
          file: String.t() | nil,
          agent_ids: [String.t()],
          suggestion: String.t()
        }

  # --- 1. Edit loop ---

  @doc """
  Detect edit loops: any file edited 5+ times triggers a report.
  Severity escalates to :error at 8+ edits.
  """
  @spec detect_edit_loop([%{file: String.t(), timestamp: String.t()}]) :: [loop_report()]
  def detect_edit_loop(events) do
    events
    |> Enum.group_by(& &1.file)
    |> Enum.flat_map(fn {file, edits} ->
      count = length(edits)

      if count >= 5 do
        severity = if count >= 8, do: :error, else: :warn

        [
          %{
            type: :edit,
            severity: severity,
            count: count,
            file: file,
            agent_ids: [],
            suggestion: "File has been edited #{count} times. Consider a different approach."
          }
        ]
      else
        []
      end
    end)
  end

  # --- 2. Semantic loop ---

  @doc """
  Detect semantic loops: edits where content barely changed (>70% character similarity).
  Reports when 3+ near-identical edits found on the same file.
  """
  @spec detect_semantic_loop([
          %{file: String.t(), content_before: String.t(), content_after: String.t()}
        ]) :: [loop_report()]
  def detect_semantic_loop(events) do
    events
    |> Enum.group_by(& &1.file)
    |> Enum.flat_map(fn {file, edits} ->
      similar_count =
        Enum.count(edits, fn ev ->
          char_similarity(ev.content_before, ev.content_after) > 0.7
        end)

      if similar_count >= 3 do
        severity = if similar_count >= 5, do: :error, else: :warn

        [
          %{
            type: :semantic,
            severity: severity,
            count: similar_count,
            file: file,
            agent_ids: [],
            suggestion:
              "Near-identical edits detected on #{file}. The approach may not be making progress."
          }
        ]
      else
        []
      end
    end)
  end

  # --- 3. Coordination loop ---

  @doc """
  Detect coordination loops: A edits file, B edits same file, A edits again
  within a 5-minute window. Classic ping-pong pattern.
  """
  @spec detect_coordination_loop([
          %{file: String.t(), agent_id: String.t(), timestamp: String.t()}
        ]) :: [loop_report()]
  def detect_coordination_loop(events) do
    window_ms = 300_000

    sorted =
      Enum.sort_by(events, fn ev ->
        {:ok, dt, _} = DateTime.from_iso8601(ev.timestamp)
        DateTime.to_unix(dt, :millisecond)
      end)

    sorted
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.reduce({MapSet.new(), []}, fn [a, b, c], {seen, reports} ->
      if a.file == b.file and b.file == c.file and
           a.agent_id == c.agent_id and a.agent_id != b.agent_id do
        {:ok, dt_a, _} = DateTime.from_iso8601(a.timestamp)
        {:ok, dt_c, _} = DateTime.from_iso8601(c.timestamp)
        span = DateTime.to_unix(dt_c, :millisecond) - DateTime.to_unix(dt_a, :millisecond)

        [left, right] = Enum.sort([a.agent_id, b.agent_id])
        key = "#{a.file}:#{left}:#{right}"

        if span <= window_ms and not MapSet.member?(seen, key) do
          report = %{
            type: :coordination,
            severity: :warn,
            count: 3,
            file: a.file,
            agent_ids: [a.agent_id, b.agent_id],
            suggestion: "Agents are trading edits on #{a.file}. Assign clear file ownership."
          }

          {MapSet.put(seen, key), [report | reports]}
        else
          {seen, reports}
        end
      else
        {seen, reports}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # --- 4. Command loop ---

  @doc """
  Detect command loops: same command failing 3+ times.
  Severity escalates to :error at 6+ failures.
  """
  @spec detect_command_loop([%{command: String.t(), exit_code: integer()}]) :: [loop_report()]
  def detect_command_loop(events) do
    events
    |> Enum.filter(fn ev -> ev.exit_code != 0 end)
    |> Enum.group_by(& &1.command)
    |> Enum.flat_map(fn {command, failures} ->
      count = length(failures)

      if count >= 3 do
        severity = if count >= 6, do: :error, else: :warn

        [
          %{
            type: :command,
            severity: severity,
            count: count,
            file: nil,
            agent_ids: [],
            suggestion:
              "Command '#{command}' has failed #{count} times. Try a different approach."
          }
        ]
      else
        []
      end
    end)
  end

  # --- 5. Retry without progress ---

  @doc """
  Detect retry-without-progress: retry_count grows while artifact_count
  stays flat for 3+ consecutive entries.
  """
  @spec detect_retry_without_progress([
          %{retry_count: non_neg_integer(), artifact_count: non_neg_integer()}
        ]) :: [loop_report()]
  def detect_retry_without_progress(events) when length(events) < 2, do: []

  def detect_retry_without_progress(events) do
    stagnant_count =
      events
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [prev, curr] ->
        curr.retry_count > prev.retry_count and curr.artifact_count <= prev.artifact_count
      end)

    if stagnant_count >= 3 do
      [
        %{
          type: :retry,
          severity: :error,
          count: stagnant_count,
          file: nil,
          agent_ids: [],
          suggestion:
            "Retries increasing without new artifacts. The retry strategy is not making progress."
        }
      ]
    else
      []
    end
  end

  # --- Public convenience ---

  @doc """
  Run all applicable detectors against a map of event lists.
  Keys: :edit_events, :semantic_events, :coordination_events, :command_events, :retry_events.
  """
  @spec run_all(map()) :: [loop_report()]
  def run_all(events) do
    detectors = [
      {:edit_events, &detect_edit_loop/1},
      {:semantic_events, &detect_semantic_loop/1},
      {:coordination_events, &detect_coordination_loop/1},
      {:command_events, &detect_command_loop/1},
      {:retry_events, &detect_retry_without_progress/1}
    ]

    Enum.flat_map(detectors, fn {key, detector} ->
      case Map.get(events, key, []) do
        [] -> []
        event_list -> detector.(event_list)
      end
    end)
  end

  # --- Private helpers ---

  defp char_similarity(a, b) when byte_size(a) == 0 or byte_size(b) == 0, do: 0.0

  defp char_similarity(a, b) do
    freq_a = char_frequencies(a)
    freq_b = char_frequencies(b)

    all_chars = MapSet.union(MapSet.new(Map.keys(freq_a)), MapSet.new(Map.keys(freq_b)))

    dot =
      Enum.reduce(all_chars, 0.0, fn c, acc ->
        acc + Map.get(freq_a, c, 0) * Map.get(freq_b, c, 0)
      end)

    mag_a = :math.sqrt(Enum.reduce(freq_a, 0.0, fn {_, v}, acc -> acc + v * v end))
    mag_b = :math.sqrt(Enum.reduce(freq_b, 0.0, fn {_, v}, acc -> acc + v * v end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  defp char_frequencies(str) do
    str
    |> String.graphemes()
    |> Enum.frequencies()
  end
end
