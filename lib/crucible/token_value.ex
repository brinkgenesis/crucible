defmodule Crucible.TokenValue do
  @moduledoc """
  Token Value Scoring for memory vault notes.

  Scores notes using Ribbit's taxonomy of token value tiers:
    access → memory → expert → context → identity → knowledge → asset

  Higher tiers represent more transformed, more valuable knowledge.
  Used by memory_retrieve to prioritize what kind of knowledge to load,
  not just how important it is.
  """

  @type tier :: :access | :memory | :expert | :context | :identity | :knowledge | :asset

  @tiers_ordered [:access, :memory, :expert, :context, :identity, :knowledge, :asset]
  @tier_weights %{
    access: 1,
    memory: 2,
    expert: 3,
    context: 4,
    identity: 5,
    knowledge: 6,
    asset: 7
  }

  @doc "Returns the ordered list of value tiers from lowest to highest."
  @spec tiers() :: [tier()]
  def tiers, do: @tiers_ordered

  @doc "Returns the numeric weight for a tier (1-7)."
  @spec weight(tier()) :: pos_integer()
  def weight(tier), do: Map.get(@tier_weights, tier, 1)

  @doc """
  Scores a vault note based on its content and metadata.
  Returns `{tier, score}` where score is 0.0-1.0 within that tier.
  """
  @spec score_note(map()) :: {tier(), float()}
  def score_note(note) when is_map(note) do
    type = Map.get(note, :type) || Map.get(note, "type") || Map.get(note, "memoryType", "")
    content = Map.get(note, :content) || Map.get(note, "content", "")
    tags = Map.get(note, :tags) || Map.get(note, "tags", [])
    priority = Map.get(note, :priority) || Map.get(note, "priority", "background")
    has_links = has_wikilinks?(content)

    tier = classify_tier(type, content, tags, has_links)
    intra_score = intra_tier_score(tier, priority, has_links, content)

    {tier, Float.round(intra_score, 2)}
  end

  @doc """
  Ranks a list of notes by token value (highest first).
  Returns notes with :value_tier and :value_score assigned.
  """
  @spec rank(list(map())) :: list(map())
  def rank(notes) when is_list(notes) do
    notes
    |> Enum.map(fn note ->
      {tier, score} = score_note(note)
      composite = weight(tier) * 100 + score * 100

      note
      |> Map.put(:value_tier, tier)
      |> Map.put(:value_score, score)
      |> Map.put(:_rank, composite)
    end)
    |> Enum.sort_by(& &1._rank, :desc)
    |> Enum.map(&Map.delete(&1, :_rank))
  end

  @doc """
  Computes aggregate token value metrics for a collection of notes.
  Useful for the Token Factory dashboard.
  """
  @spec pipeline_metrics(list(map())) :: map()
  def pipeline_metrics(notes) when is_list(notes) do
    scored = Enum.map(notes, &score_note/1)

    by_tier =
      scored
      |> Enum.group_by(fn {tier, _} -> tier end)
      |> Enum.map(fn {tier, entries} ->
        scores = Enum.map(entries, fn {_, s} -> s end)
        avg = if scores != [], do: Enum.sum(scores) / length(scores), else: 0.0
        {tier, %{count: length(entries), avg_score: Float.round(avg, 2)}}
      end)
      |> Map.new()

    total = length(notes)

    # Transformation ratio: what % of notes are above "memory" tier
    transformed =
      scored
      |> Enum.count(fn {tier, _} -> weight(tier) >= weight(:expert) end)

    transformation_ratio = if total > 0, do: Float.round(transformed / total, 3), else: 0.0

    # Weighted average tier score
    weighted_sum =
      scored
      |> Enum.map(fn {tier, score} -> weight(tier) + score end)
      |> Enum.sum()

    avg_value = if total > 0, do: Float.round(weighted_sum / total, 2), else: 0.0

    %{
      total_notes: total,
      by_tier: by_tier,
      transformation_ratio: transformation_ratio,
      avg_value: avg_value
    }
  end

  # --- Classification ---

  defp classify_tier(type, content, tags, has_links) do
    type_str = to_string(type) |> String.downcase()
    tags_str = tags |> Enum.map(&to_string/1) |> Enum.map(&String.downcase/1)

    cond do
      # Asset: shipped code, PRs merged, deployed artifacts
      type_str in ["asset", "release", "deployment"] or "asset" in tags_str ->
        :asset

      # Knowledge: linked decisions, lessons with backlinks, MOCs
      type_str in ["moc", "knowledge"] or
        (type_str == "decision" and has_links) or
          "knowledge" in tags_str ->
        :knowledge

      # Identity: preferences, commitments, people notes
      type_str in ["preference", "commitment", "people", "identity"] ->
        :identity

      # Context: decisions, linked observations
      type_str == "decision" or (type_str == "observation" and has_links) ->
        :context

      # Expert: lessons, patterns, extracted knowledge
      type_str in ["lesson", "pattern"] or
          String.contains?(content, "auto-captured") ->
        :expert

      # Memory: cached results, handoffs, stored observations
      type_str in ["handoff", "observation", "tension"] ->
        :memory

      # Access: raw traces, logs, unprocessed inputs
      true ->
        :access
    end
  end

  defp intra_tier_score(tier, priority, has_links, content) do
    base =
      case priority do
        p when p in ["critical", :critical] -> 0.9
        p when p in ["notable", :notable] -> 0.6
        _ -> 0.3
      end

    link_bonus = if has_links, do: 0.05, else: 0.0

    # Longer, more substantive content gets a small bonus
    len = String.length(content)

    length_bonus =
      cond do
        len > 2000 -> 0.05
        len > 500 -> 0.02
        true -> 0.0
      end

    # Higher tiers have inherently higher intra-scores
    tier_floor = weight(tier) / 14.0

    min(1.0, tier_floor + base + link_bonus + length_bonus)
  end

  defp has_wikilinks?(content) when is_binary(content) do
    String.contains?(content, "[[")
  end

  defp has_wikilinks?(_), do: false
end
