defmodule Crucible.WorkflowRunner do
  @moduledoc """
  Converts workflow YAML config into a Run manifest.
  Parses workflows/*.yml and creates Run structs ready for execution.
  """

  require Logger

  alias Crucible.Types.{Run, Phase, WorkUnit}

  @valid_phase_types ~w(session team api review-gate pr-shepherd preflight)

  @doc "Creates a Run from a workflow config map and overrides."
  @spec create_run(map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def create_run(workflow_config, opts \\ [])

  def create_run(workflow_config, opts) when is_map(workflow_config) do
    case validate_workflow(workflow_config) do
      :ok -> do_create_run(workflow_config, opts)
      {:error, _} = err -> err
    end
  end

  def create_run(_invalid, _opts), do: {:error, :invalid_workflow_config}

  @doc """
  Selects the best workflow for a task description by keyword matching.
  Workflows with a `keywords` field get higher weight. Returns the best-matching name.
  """
  @spec select_workflow(String.t(), [map()]) :: {:ok, String.t()} | {:error, :no_match}
  def select_workflow(task_description, workflows)
      when is_binary(task_description) and is_list(workflows) do
    desc_words =
      task_description
      |> String.downcase()
      |> String.split(~r/[\s,._\-]+/, trim: true)
      |> MapSet.new()

    scored =
      workflows
      |> Enum.map(fn wf ->
        name = Map.get(wf, "name", "")
        keywords = Map.get(wf, "keywords", [])

        name_words =
          name
          |> String.downcase()
          |> String.split(~r/[\s,._\-]+/, trim: true)
          |> MapSet.new()

        keyword_set =
          keywords
          |> Enum.map(&String.downcase/1)
          |> MapSet.new()

        name_hits = MapSet.intersection(desc_words, name_words) |> MapSet.size()
        keyword_hits = MapSet.intersection(desc_words, keyword_set) |> MapSet.size()
        score = name_hits + keyword_hits * 2

        {wf, score}
      end)
      |> Enum.reject(fn {_, score} -> score == 0 end)
      |> Enum.sort_by(fn {_, score} -> -score end)

    case scored do
      [{wf, _} | _] -> {:ok, Map.get(wf, "name")}
      [] -> {:error, :no_match}
    end
  end

  @doc """
  Validates that team phases have properly configured work units with roles.
  Returns `:ok` or `{:error, reasons}`.
  """
  @spec preflight_team_roles([Phase.t()]) :: :ok | {:error, [String.t()]}
  def preflight_team_roles(phases) when is_list(phases) do
    errors =
      phases
      |> Enum.filter(&(&1.type == :team))
      |> Enum.flat_map(fn phase ->
        if Enum.empty?(phase.work_units) do
          ["phase #{phase.id}: team phase must have at least one work_unit"]
        else
          phase.work_units
          |> Enum.with_index()
          |> Enum.flat_map(fn {wu, idx} ->
            []
            |> then(fn errs ->
              if is_nil(wu.role) or wu.role == "",
                do: ["phase #{phase.id}: work_unit[#{idx}] missing role" | errs],
                else: errs
            end)
            |> then(fn errs ->
              if is_nil(wu.path) or wu.path == "",
                do: ["phase #{phase.id}: work_unit[#{idx}] missing path" | errs],
                else: errs
            end)
          end)
        end
      end)

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  @doc "Validate a workflow config map. Returns `:ok` or `{:error, reasons}`."
  @spec validate_workflow(map()) :: :ok | {:error, [String.t()]}
  def validate_workflow(config) when is_map(config) do
    errors =
      []
      |> validate_name(config)
      |> validate_phases(config)
      |> validate_dag(config)

    case errors do
      [] -> :ok
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  def validate_workflow(_), do: {:error, ["workflow config must be a map"]}

  # --- Private: validation ---

  # Topological sort via Kahn's algorithm to detect circular dependencies
  defp validate_dag(errors, config) do
    phases = Map.get(config, "phases", [])

    if not is_list(phases) or length(phases) == 0 do
      errors
    else
      # Build adjacency and in-degree maps
      # Phases can be referenced by id OR name in depends_on
      ids =
        Enum.with_index(phases)
        |> Enum.map(fn {p, idx} -> Map.get(p, "id", "phase-#{idx}") end)

      names =
        Enum.with_index(phases)
        |> Enum.map(fn {p, idx} ->
          Map.get(p, "name", Map.get(p, "phaseName", "phase-#{idx}"))
        end)

      # Filter nil phases
      phases = Enum.reject(phases, &is_nil/1)

      # Valid dependency targets: both ids and names
      valid_refs = MapSet.new(ids ++ names)

      # Check for duplicate phase names (ambiguous depends_on targets)
      name_dupes =
        names
        |> Enum.frequencies()
        |> Enum.filter(fn {_name, count} -> count > 1 end)
        |> Enum.map(fn {name, _} -> name end)

      dupe_errors =
        if name_dupes != [] do
          ["duplicate phase names make depends_on ambiguous: #{Enum.join(name_dupes, ", ")}"]
        else
          []
        end

      # Normalize dependencies: resolve name references to ids
      name_to_id =
        Enum.zip(names, ids)
        |> Enum.into(%{})

      deps_map =
        Enum.zip(ids, phases)
        |> Enum.into(%{}, fn {id, p} ->
          deps = Map.get(p, "depends_on", Map.get(p, "dependsOn", []))
          deps = if is_list(deps), do: deps, else: []
          # Normalize: if dep is a name, resolve to id
          normalized_deps =
            Enum.map(deps, fn dep ->
              Map.get(name_to_id, dep, dep)
            end)

          {id, normalized_deps}
        end)

      # Check for references to unknown phase IDs/names
      unknown_errors =
        Enum.zip(ids, phases)
        |> Enum.flat_map(fn {id, p} ->
          deps = Map.get(p, "depends_on", Map.get(p, "dependsOn", []))
          deps = if is_list(deps), do: deps, else: []

          Enum.flat_map(deps, fn dep ->
            if MapSet.member?(valid_refs, dep),
              do: [],
              else: ["phase \"#{id}\": depends_on references unknown phase \"#{dep}\""]
          end)
        end)

      # Kahn's algorithm for cycle detection
      # Each dep -> id edge adds 1 to id's in_degree
      in_degree = Enum.into(ids, %{}, fn id -> {id, 0} end)

      in_degree =
        Enum.reduce(deps_map, in_degree, fn {id, deps}, acc ->
          # id depends on deps, so deps -> id (id's in_degree += 1 for each dep)
          Enum.reduce(deps, acc, fn _dep, a ->
            Map.update!(a, id, &(&1 + 1))
          end)
        end)

      queue = Enum.filter(ids, fn id -> Map.get(in_degree, id, 0) == 0 end)
      {visited, _} = kahn_traverse(queue, deps_map, in_degree, ids, [])

      cycle_errors =
        if length(visited) < length(ids) do
          stuck = Enum.reject(ids, &(&1 in visited))
          ["circular dependency detected among phases: #{Enum.join(stuck, ", ")}"]
        else
          []
        end

      errors ++ dupe_errors ++ unknown_errors ++ cycle_errors
    end
  end

  defp kahn_traverse([], _deps_map, _in_degree, _all_ids, visited), do: {visited, %{}}

  defp kahn_traverse(queue, deps_map, in_degree, all_ids, visited) do
    # Process all nodes with in_degree 0
    new_visited = visited ++ queue

    # For each processed node, find nodes that depend on it and decrement their in_degree
    # Build reverse map: which nodes have this node as a dependency?
    new_in_degree =
      Enum.reduce(queue, in_degree, fn processed_id, acc ->
        # Find all nodes that depend on processed_id
        Enum.reduce(all_ids, acc, fn id, a ->
          deps = Map.get(deps_map, id, [])

          if processed_id in deps do
            Map.update!(a, id, &(&1 - 1))
          else
            a
          end
        end)
      end)

    next_queue =
      Enum.filter(all_ids, fn id ->
        id not in new_visited and Map.get(new_in_degree, id, 0) == 0
      end)

    if next_queue == [] do
      {new_visited, new_in_degree}
    else
      kahn_traverse(next_queue, deps_map, new_in_degree, all_ids, new_visited)
    end
  end

  defp validate_name(errors, config) do
    name = get_either(config, "name", "workflowName")

    case name do
      name when is_binary(name) and name != "" -> errors
      _ -> ["workflow must have a non-empty \"name\" field" | errors]
    end
  end

  defp validate_phases(errors, config) do
    case Map.get(config, "phases") do
      phases when is_list(phases) and length(phases) > 0 ->
        phases
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {phase, idx}, acc ->
          validate_phase(acc, phase, idx)
        end)

      _ ->
        ["workflow must have at least one phase" | errors]
    end
  end

  defp validate_phase(errors, phase, idx) when is_map(phase) do
    errors
    |> then(fn errs ->
      type = Map.get(phase, "type", "session")

      if type in @valid_phase_types,
        do: errs,
        else: [
          "phase[#{idx}]: invalid type \"#{type}\" (valid: #{Enum.join(@valid_phase_types, ", ")})"
          | errs
        ]
    end)
    |> then(fn errs ->
      timeout = Map.get(phase, "timeout_ms")

      if is_nil(timeout) or (is_integer(timeout) and timeout > 0),
        do: errs,
        else: ["phase[#{idx}]: timeout_ms must be a positive integer" | errs]
    end)
    |> then(fn errs ->
      deps = Map.get(phase, "depends_on", [])

      if is_list(deps),
        do: errs,
        else: ["phase[#{idx}]: depends_on must be a list" | errs]
    end)
  end

  defp validate_phase(errors, _phase, idx) do
    ["phase[#{idx}]: must be a map" | errors]
  end

  @doc """
  Scales an agent roster based on complexity.
  Reviewer is always kept. Non-reviewer agents are taken from the front
  of the list up to the complexity count. Mirrors TS `scaleAgentRoster`.
  """
  @spec scale_agents([map()], non_neg_integer() | nil) :: [map()]
  def scale_agents(agents, nil), do: agents
  def scale_agents(agents, complexity) when complexity < 1, do: agents

  def scale_agents(agents, complexity) do
    {reviewers, workers} = Enum.split_with(agents, &(Map.get(&1, :role) == "reviewer"))
    worker_count = max(1, min(length(workers), complexity))
    Enum.take(workers, worker_count) ++ reviewers
  end

  # --- Private: run creation ---

  defp do_create_run(workflow_config, opts) do
    run_id =
      Keyword.get(opts, :run_id, get_either(workflow_config, "run_id", "runId", generate_id()))

    raw_complexity = Map.get(workflow_config, "complexity")

    complexity =
      case raw_complexity do
        n when is_integer(n) and n >= 1 and n <= 3 -> n
        _ -> nil
      end

    phases =
      workflow_config
      |> Map.get("phases", [])
      |> Enum.with_index()
      |> Enum.map(fn {phase_config, idx} ->
        all_agents = parse_agents(Map.get(phase_config, "agents", []))
        phase_type = parse_phase_type(Map.get(phase_config, "type", "session"))

        scaled_agents =
          if phase_type == :team and complexity do
            scale_agents(all_agents, complexity)
          else
            all_agents
          end

        %Phase{
          id: Map.get(phase_config, "id", "phase-#{idx}"),
          name: get_either(phase_config, "name", "phaseName", "Phase #{idx}"),
          type: phase_type,
          prompt: Map.get(phase_config, "prompt"),
          depends_on: get_either(phase_config, "depends_on", "dependsOn", []),
          max_retries: get_either(phase_config, "max_retries", "maxRetries", 2),
          timeout_ms: get_either(phase_config, "timeout_ms", "timeoutMs", 600_000),
          phase_index: idx,
          parallel: Map.get(phase_config, "parallel", false),
          estimated_cost_usd: get_either(phase_config, "estimated_cost_usd", "estimatedCostUsd"),
          routing_profile: get_either(phase_config, "routing_profile", "routingProfile"),
          create_branch: get_either(phase_config, "create_branch", "createBranch", false),
          plan_approval_agents:
            get_either(phase_config, "plan_approval_agents", "planApprovalAgents", []),
          agents: scaled_agents,
          work_units: parse_work_units(get_either(phase_config, "work_units", "workUnits", []))
        }
      end)

    run = %Run{
      id: run_id,
      workflow_type: Map.get(workflow_config, "name", "unknown"),
      task_description: get_either(workflow_config, "task_description", "taskDescription"),
      complexity: Map.get(workflow_config, "complexity"),
      execution_type:
        get_either(workflow_config, "execution_type", "executionType", "subscription"),
      phases: phases,
      budget_usd:
        Keyword.get(
          opts,
          :budget_usd,
          get_either(workflow_config, "budget_usd", "budgetUsd", 50.0)
        ),
      plan_note:
        Keyword.get(opts, :plan_note, get_either(workflow_config, "plan_note", "planNote")),
      plan_summary:
        Keyword.get(
          opts,
          :plan_summary,
          get_either(workflow_config, "plan_summary", "planSummary")
        ),
      workspace_path:
        Keyword.get(
          opts,
          :workspace_path,
          get_either(workflow_config, "workspace_path", "workspacePath")
        ),
      branch: Keyword.get(opts, :branch, get_either(workflow_config, "branch", "branch")),
      base_commit:
        Keyword.get(opts, :base_commit, get_either(workflow_config, "base_commit", "baseCommit")),
      card_id: Keyword.get(opts, :card_id, get_either(workflow_config, "card_id", "cardId")),
      client_id:
        Keyword.get(opts, :client_id, get_either(workflow_config, "client_id", "clientId"))
    }

    {:ok, run}
  end

  # --- Private ---

  defp get_either(map, key1, key2, default \\ nil) do
    Map.get(map, key1) || Map.get(map, key2, default)
  end

  defp parse_phase_type("session"), do: :session
  defp parse_phase_type("team"), do: :team
  defp parse_phase_type("review-gate"), do: :review_gate
  defp parse_phase_type("pr-shepherd"), do: :pr_shepherd
  defp parse_phase_type("preflight"), do: :preflight
  defp parse_phase_type(_), do: :session

  defp parse_agents(agents) when is_list(agents) do
    Enum.map(agents, fn
      agent when is_map(agent) ->
        %{
          role: Map.get(agent, "role"),
          name: Map.get(agent, "name", Map.get(agent, "role", "agent")),
          model: Map.get(agent, "model"),
          description: Map.get(agent, "description")
        }

      _ ->
        %{role: "agent", name: "agent"}
    end)
  end

  defp parse_agents(_), do: []

  defp parse_work_units(units) when is_list(units) do
    Enum.with_index(units, fn unit, idx ->
      case unit do
        unit when is_map(unit) ->
          files = Map.get(unit, "files", [])
          path = Map.get(unit, "path", List.first(files) || "")

          %WorkUnit{
            id: Map.get(unit, "id", "wu-#{idx}"),
            path: path,
            files: files,
            read_files: Map.get(unit, "readFiles", Map.get(unit, "read_files", [])),
            description: Map.get(unit, "description"),
            role: Map.get(unit, "role"),
            context_boundary:
              Map.get(unit, "contextBoundary", Map.get(unit, "context_boundary", [])),
            depends_on: Map.get(unit, "dependsOn", Map.get(unit, "depends_on", [])),
            acceptance_criteria:
              Map.get(unit, "acceptanceCriteria", Map.get(unit, "acceptance_criteria", []))
          }

        path when is_binary(path) ->
          %WorkUnit{id: "wu-#{idx}", path: path, files: [path]}
      end
    end)
  end

  defp parse_work_units(_), do: []

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
