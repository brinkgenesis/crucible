defmodule Crucible.AgentIdentity do
  @moduledoc """
  "Know Your Agent" (KYA) Identity System.

  Each agent gets a persistent identity profile stored as a vault note:
  - Capabilities and specializations
  - Track record (success rate, avg cost, common tasks)
  - Trust score (0.0-1.0) based on historical performance
  - Recommendations for task assignment

  When spawning agents, the orchestrator can pick based on proven competence,
  not just availability.

  Identity notes are stored in `memory/agents/` as YAML-frontmatter Markdown.
  """

  require Logger

  @identity_dir "memory/agents"

  @doc """
  Returns the identity profile for a named agent.
  Merges static role definition with runtime performance data.
  """
  @spec get_identity(String.t(), keyword()) :: map() | nil
  def get_identity(agent_name, opts \\ []) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())
    identity_path = Path.join([infra_home, @identity_dir, "#{slugify(agent_name)}.md"])
    role_path = Path.join([infra_home, ".claude/agents", "#{slugify(agent_name)}.yml"])

    role_data = read_role_definition(role_path)
    identity_data = read_identity_note(identity_path)
    performance = compute_performance(agent_name, infra_home)

    if role_data || identity_data do
      %{
        name: agent_name,
        slug: slugify(agent_name),
        role: role_data,
        identity: identity_data,
        performance: performance,
        trust_score: compute_trust_score(identity_data, performance),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    else
      nil
    end
  end

  @doc """
  Lists all known agent identities (from role definitions + identity notes).
  """
  @spec list_agents(keyword()) :: [map()]
  def list_agents(opts \\ []) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())
    roles_dir = Path.join(infra_home, ".claude/agents")
    identity_dir = Path.join(infra_home, @identity_dir)

    role_names =
      if File.dir?(roles_dir) do
        roles_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".yml"))
        |> Enum.map(&String.trim_trailing(&1, ".yml"))
      else
        []
      end

    identity_names =
      if File.dir?(identity_dir) do
        identity_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&String.trim_trailing(&1, ".md"))
      else
        []
      end

    (role_names ++ identity_names)
    |> Enum.uniq()
    |> Enum.map(fn name ->
      get_identity(name, infra_home: infra_home) || %{name: name, slug: name, trust_score: 0.5}
    end)
    |> Enum.sort_by(& &1.trust_score, :desc)
  end

  @doc """
  Recommends the best agent for a given task type based on trust scores
  and specialization match.
  """
  @spec recommend(String.t(), keyword()) :: [map()]
  def recommend(task_type, opts \\ []) do
    agents = list_agents(opts)

    agents
    |> Enum.map(fn agent ->
      relevance = specialization_match(agent, task_type)
      score = (agent.trust_score || 0.5) * 0.6 + relevance * 0.4
      Map.put(agent, :recommendation_score, Float.round(score, 3))
    end)
    |> Enum.sort_by(& &1.recommendation_score, :desc)
    |> Enum.take(5)
  end

  @doc """
  Updates an agent's identity note with new performance data.
  Creates the note if it doesn't exist.
  """
  @spec update_identity(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def update_identity(agent_name, metrics, opts \\ []) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())
    dir = Path.join(infra_home, @identity_dir)
    File.mkdir_p!(dir)

    path = Path.join(dir, "#{slugify(agent_name)}.md")
    existing = read_identity_note(path) || %{}

    # Merge metrics into existing identity
    track_record = Map.get(existing, :track_record, %{})

    new_record =
      track_record
      |> Map.merge(%{
        last_task: Map.get(metrics, :task_type),
        last_run: DateTime.utc_now() |> DateTime.to_iso8601(),
        total_tasks: (Map.get(track_record, :total_tasks) || 0) + 1,
        successes:
          (Map.get(track_record, :successes) || 0) +
            if(Map.get(metrics, :success, false), do: 1, else: 0),
        total_cost:
          Float.round(
            (Map.get(track_record, :total_cost) || 0.0) + (Map.get(metrics, :cost, 0.0) || 0.0),
            2
          )
      })

    content = build_identity_note(agent_name, Map.put(existing, :track_record, new_record))
    File.write(path, content)
  end

  # --- Private ---

  defp read_role_definition(path) do
    case File.read(path) do
      {:ok, content} -> parse_yaml_frontmatter(content)
      _ -> nil
    end
  end

  defp read_identity_note(path) do
    case File.read(path) do
      {:ok, content} -> parse_identity_frontmatter(content)
      _ -> nil
    end
  end

  defp parse_yaml_frontmatter(content) do
    # Simple YAML frontmatter parser — extracts key fields
    lines = String.split(content, "\n")

    if List.first(lines) == "---" do
      yaml_lines =
        lines
        |> Enum.drop(1)
        |> Enum.take_while(&(&1 != "---"))

      data =
        yaml_lines
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] ->
              key_atom =
                try do
                  String.trim(key) |> String.to_existing_atom()
                rescue
                  ArgumentError -> nil
                end

              if key_atom, do: Map.put(acc, key_atom, String.trim(value)), else: acc

            _ ->
              acc
          end
        end)

      if map_size(data) > 0, do: data, else: nil
    else
      nil
    end
  rescue
    e ->
      Logger.warning("AgentIdentity: parse_yaml_frontmatter failed: #{Exception.message(e)}")
      nil
  end

  defp parse_identity_frontmatter(content) do
    base = parse_yaml_frontmatter(content) || %{}

    # Also extract track record from body
    track_record =
      if String.contains?(content, "## Track Record") do
        content
        |> String.split("## Track Record")
        |> List.last()
        |> String.split("\n")
        |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/- \*\*(\w+)\*\*:\s*(.+)/, line) do
            [_, key, value] ->
              key_atom =
                try do
                  String.to_existing_atom(String.downcase(key))
                rescue
                  ArgumentError -> nil
                end

              if key_atom, do: Map.put(acc, key_atom, parse_value(value)), else: acc

            _ ->
              acc
          end
        end)
      else
        %{}
      end

    Map.put(base, :track_record, track_record)
  rescue
    e ->
      Logger.warning("AgentIdentity: parse_identity_frontmatter failed: #{Exception.message(e)}")
      %{}
  end

  defp parse_value(s) do
    s = String.trim(s)

    cond do
      match?({_, ""}, Float.parse(s)) -> elem(Float.parse(s), 0)
      match?({_, ""}, Integer.parse(s)) -> elem(Integer.parse(s), 0)
      true -> s
    end
  end

  defp compute_performance(agent_name, infra_home) do
    traces_dir = Path.join(infra_home, ".claude-flow/logs/traces")

    if File.dir?(traces_dir) do
      cutoff = DateTime.utc_now() |> DateTime.add(-7 * 86400, :second)
      slug = slugify(agent_name)

      agent_events =
        traces_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.flat_map(fn file ->
          Path.join(traces_dir, file)
          |> File.stream!()
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, %{"agentId" => aid, "timestamp" => ts} = event}
              when is_binary(aid) ->
                with {:ok, dt, _} <- DateTime.from_iso8601(ts),
                     true <- DateTime.compare(dt, cutoff) == :gt,
                     true <- String.contains?(String.downcase(aid), slug) do
                  [event]
                else
                  _ -> []
                end

              _ ->
                []
            end
          end)
        end)

      edits = Enum.count(agent_events, &(Map.get(&1, "eventType") == "agent_edit"))
      tool_calls = Enum.count(agent_events, &(Map.get(&1, "eventType") == "agent_tool_call"))

      %{
        events_7d: length(agent_events),
        edits_7d: edits,
        tool_calls_7d: tool_calls,
        efficiency: if(tool_calls > 0, do: Float.round(edits / tool_calls, 3), else: 0.0)
      }
    else
      %{events_7d: 0, edits_7d: 0, tool_calls_7d: 0, efficiency: 0.0}
    end
  rescue
    e ->
      Logger.warning(
        "AgentIdentity: compute_performance failed for #{agent_name}: #{Exception.message(e)}"
      )

      %{events_7d: 0, edits_7d: 0, tool_calls_7d: 0, efficiency: 0.0}
  end

  defp compute_trust_score(identity, performance) do
    # Base trust from track record
    track = (identity || %{}) |> Map.get(:track_record, %{})
    total = Map.get(track, :total_tasks) || 0
    successes = Map.get(track, :successes) || 0

    success_rate = if total > 0, do: successes / total, else: 0.5
    experience_bonus = min(0.1, total / 100)

    # Performance signal
    perf = performance || %{}
    efficiency = Map.get(perf, :efficiency, 0.0)
    activity = min(0.1, (Map.get(perf, :events_7d) || 0) / 100)

    score = success_rate * 0.5 + experience_bonus + efficiency * 0.2 + activity + 0.1
    Float.round(min(1.0, score), 3)
  end

  defp specialization_match(agent, task_type) do
    role = Map.get(agent, :role) || %{}

    role_name = to_string(Map.get(role, :name, ""))
    role_desc = to_string(Map.get(role, :description, ""))
    agent_name = to_string(Map.get(agent, :name, ""))

    task_lower = String.downcase(task_type)
    searchable = String.downcase("#{role_name} #{role_desc} #{agent_name}")

    # Simple keyword matching
    keywords = String.split(task_lower, ~r/[\s_-]+/)
    matches = Enum.count(keywords, &String.contains?(searchable, &1))
    if length(keywords) > 0, do: min(1.0, matches / length(keywords)), else: 0.0
  end

  defp build_identity_note(agent_name, data) do
    track = Map.get(data, :track_record, %{})
    total = Map.get(track, :total_tasks, 0)
    successes = Map.get(track, :successes, 0)
    cost = Map.get(track, :total_cost, 0.0)

    """
    ---
    title: "Agent: #{agent_name}"
    memoryType: agent-identity
    category: self
    priority: notable
    tags: [agent, kya, identity]
    updated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    ---

    # #{agent_name}

    ## Track Record
    - **total_tasks**: #{total}
    - **successes**: #{successes}
    - **success_rate**: #{if total > 0, do: Float.round(successes / total, 2), else: 0.0}
    - **total_cost**: #{Float.round(cost * 1.0, 2)}
    - **last_run**: #{Map.get(track, :last_run, "never")}
    - **last_task**: #{Map.get(track, :last_task, "none")}

    ## Links
    - [[agents]]
    """
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
