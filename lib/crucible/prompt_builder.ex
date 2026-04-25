defmodule Crucible.PromptBuilder do
  @moduledoc """
  Builds phase-specific prompts for workflow execution.
  Dispatches to 6 specialized builders based on phase type.
  Also provides Solid (Liquid) template rendering via `render/2`.
  """

  require Logger

  alias Crucible.RoleAssignment
  alias Crucible.SelfImprovement
  alias Crucible.WorkflowRunner
  alias Crucible.Types.{Run, Phase}

  @vault_plan_max_chars 12_000
  @module_context_max_chars 4_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Renders a prompt template with the given assigns."
  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(template_string, assigns) when is_binary(template_string) do
    with {:ok, template} <- Solid.parse(template_string) do
      case Solid.render(template, assigns) do
        {:ok, iodata, _warnings} ->
          {:ok, IO.iodata_to_binary(iodata)}

        {:error, _errors, _warnings} = err ->
          {:error, err}
      end
    end
  end

  @doc """
  Builds a prompt for the given run and phase.
  Dispatches to the correct builder based on `phase.type`.

  ## Options
    * `:infra_home` — repo root path (default: `File.cwd!()`)
    * `:client_context` — pre-built client context string (optional)
  """
  @spec build(Run.t(), Phase.t(), keyword()) :: String.t()
  def build(%Run{} = run, %Phase{} = phase, opts \\ []) do
    case phase.type do
      :session -> build_session_prompt(run, phase, opts)
      :team -> build_team_prompt(run, phase, opts)
      :review_gate -> build_review_gate_prompt(run, phase, opts)
      :pr_shepherd -> build_pr_shepherd_prompt(run, phase, opts)
      :preflight -> build_preflight_prompt(run, phase, opts)
      _ -> build_session_prompt(run, phase, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private builders
  # ---------------------------------------------------------------------------

  defp build_session_prompt(run, phase, opts) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())

    sections = [
      plan_section(run, infra_home),
      previous_phase_plans_section(run, phase, infra_home),
      client_context_section(opts),
      routing_profile_section(phase),
      module_context_section(infra_home, phase.work_units),
      phase_header_section(phase),
      work_units_section(phase.work_units),
      learned_hints_section(run.workflow_type, phase.type),
      session_instructions_section(run, phase)
    ]

    join_sections(sections)
  end

  defp build_team_prompt(run, phase, opts) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())
    plan_files = extract_all_plan_files(run, phase)
    sentinel_path = ".claude-flow/runs/#{run.id}-#{phase.id}.done"
    agents = WorkflowRunner.scale_agents(phase.agents, run.complexity)

    sections = [
      orchestrator_preamble(run, phase),
      spawn_instructions_section(agents, run, sentinel_path),
      """
      ---

      ## Context for subagent prompts
      Copy the relevant sections below into each subagent's prompt so they have the task and plan.
      Subagents have access to the Obsidian vault via MCP tools (`memory_retrieve`, `codebase`) for
      indexed codebase context — remind them to use these instead of reading raw source files.\
      """,
      phase_context_section(run, infra_home, phase),
      client_context_section(opts),
      plan_section(run, infra_home),
      routing_profile_section(phase),
      previous_phase_plans_section(run, phase, infra_home),
      module_context_section(infra_home, phase.work_units),
      learned_hints_section(run.workflow_type, phase.type),
      file_ownership_section(agents, plan_files),
      work_units_section(phase.work_units)
    ]

    join_sections(sections)
  end

  defp build_review_gate_prompt(run, phase, opts) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())

    sections = [
      client_context_section(opts),
      phase_header_section(phase),
      changed_files_section(phase.work_units),
      learned_hints_section(run.workflow_type, phase.type),
      review_gate_instructions_section(infra_home)
    ]

    join_sections(sections)
  end

  defp build_pr_shepherd_prompt(run, phase, opts) do
    pr_urls = Keyword.get(opts, :pr_urls, Crucible.PrCounter.urls(run.id))

    sections = [
      plan_section_brief(run),
      client_context_section(opts),
      phase_header_section(phase),
      pr_context_section(run),
      pr_urls_section(pr_urls),
      learned_hints_section(run.workflow_type, phase.type),
      pr_shepherd_instructions_section()
    ]

    join_sections(sections)
  end

  defp build_preflight_prompt(run, phase, opts) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())

    sections = [
      client_context_section(opts),
      phase_header_section(phase),
      learned_hints_section(run.workflow_type, phase.type),
      preflight_instructions_section(infra_home)
    ]

    join_sections(sections)
  end

  # ---------------------------------------------------------------------------
  # Section builders
  # ---------------------------------------------------------------------------

  defp client_context_section(opts) do
    Keyword.get(opts, :client_context)
  end

  defp plan_section(run, infra_home) do
    content = read_vault_plan(run, infra_home)

    if content && content != "" do
      "## Plan\n#{truncate_note(content, @vault_plan_max_chars)}"
    else
      nil
    end
  end

  defp plan_section_brief(run) do
    summary = run.plan_summary

    if summary && summary != "" do
      "## Plan Summary\n#{truncate_note(summary, @vault_plan_max_chars)}"
    else
      nil
    end
  end

  defp module_context_section(infra_home, work_units) do
    file_paths = Enum.map(work_units, & &1.path) |> Enum.reject(&is_nil/1)
    content = read_module_summaries(infra_home, file_paths)

    if content && content != "" do
      "## Module Context\n#{content}"
    else
      nil
    end
  end

  defp phase_header_section(phase) do
    "## Phase: #{phase.name} (#{phase.type})\nPhase ID: #{phase.id}"
  end

  defp work_units_section([]), do: nil

  defp work_units_section(work_units) do
    "## Work Units\n#{format_work_units(work_units)}"
  end

  defp changed_files_section(work_units) do
    paths =
      work_units
      |> Enum.map(& &1.path)
      |> Enum.reject(&is_nil/1)

    if paths == [] do
      nil
    else
      items = Enum.map_join(paths, "\n", &"- `#{&1}`")
      "## Files Changed\n#{items}"
    end
  end

  defp file_ownership_section(_agents, []), do: nil

  defp file_ownership_section(_agents, plan_files) do
    assignments = RoleAssignment.assign_files(plan_files)
    "## File Ownership\n#{format_file_ownership(assignments)}"
  end

  defp pr_context_section(run) do
    lines = [
      "## PR Context",
      "- Branch: #{run.branch || "(unknown)"}",
      "- Workspace: #{run.workspace_path || "(unknown)"}"
    ]

    Enum.join(lines, "\n")
  end

  defp learned_hints_section(workflow_name, phase_type) do
    format_learned_hints(workflow_name, phase_type)
  end

  defp routing_profile_section(%{routing_profile: profile})
       when is_binary(profile) and profile != "" do
    label =
      case profile do
        "deep-reasoning" -> "Deep Reasoning — use extended thinking for architecture decisions"
        "verification" -> "Verification — focus on correctness, run all checks"
        "cost-efficiency" -> "Cost Efficiency — prefer cheaper models, minimize tool calls"
        other -> other
      end

    "## Routing Profile\n#{label}"
  end

  defp routing_profile_section(_phase), do: nil

  defp previous_phase_plans_section(run, phase, infra_home) do
    if phase.phase_index > 0 do
      prior_phases = Enum.take(run.phases, phase.phase_index)

      plans =
        prior_phases
        |> Enum.map(fn p ->
          path = Path.join(infra_home, ".claude-flow/runs/#{run.id}-#{p.id}.plan.md")
          {p.id, read_file_safe(path)}
        end)
        |> Enum.reject(fn {_, content} -> is_nil(content) end)

      if plans == [] do
        nil
      else
        formatted =
          Enum.map_join(plans, "\n\n", fn {id, content} ->
            "### Phase #{id} Plan\n#{truncate_note(content, 4_000)}"
          end)

        "## Previous Phase Plans\n#{formatted}"
      end
    else
      nil
    end
  end

  defp session_instructions_section(run, phase) do
    sentinel_path = ".claude-flow/runs/#{run.id}-#{phase.id}.done"
    plan_path = ".claude-flow/runs/#{run.id}-#{phase.id}.plan.md"

    task_section =
      if run.task_description && run.task_description != "" do
        "## Task\n#{run.task_description}"
      else
        nil
      end

    """
    #{task_section || ""}

    ## Instructions
    You are executing a solo coding session. Complete the task described above.

    **CRITICAL**: When you are done, you MUST write a sentinel file to signal completion:
    ```
    echo '{"status":"done","commitHash":"$(git rev-parse HEAD)"}' > #{sentinel_path}
    ```

    Also write your results/plan to `#{plan_path}`.

    Do NOT return to the prompt without writing the sentinel file first.\
    """
  end

  defp orchestrator_preamble(run, phase) do
    """
    You are the ORCHESTRATOR for phase "#{phase.name}" of workflow "#{run.workflow_type}".

    ## YOUR ROLE — ORCHESTRATE, DO NOT IMPLEMENT
    You spawn parallel subagents to do the coding work. You do NOT write code or implement anything yourself.
    After all subagents return, you verify results and write the sentinel file.

    **Allowed tools:** Agent (primary), Bash (verification + sentinel), Read (verify changes).
    **Forbidden tools:** Edit, Write, Glob, Grep (you are not a coder).
    **Forbidden pattern:** Do NOT call Agent with `run_in_background: true`. Subagents must run in foreground so results return to you.
    **Forbidden pattern:** Do NOT use TeamCreate, TaskCreate, or any team tools. You are spawning subagents, not a team.\
    """
  end

  defp spawn_instructions_section(agents, run, sentinel_path) do
    coder_agents = Enum.reject(agents, &(agent_role(&1) == "reviewer"))
    build_coder_spawn(coder_agents, run, sentinel_path)
  end

  defp build_coder_spawn(coder_agents, run, sentinel_path) do
    agent_list = format_agent_roster_with_subagent_type(coder_agents)
    workspace = run.workspace_path || File.cwd!()
    signals_dir = Path.join(workspace, ".claude-flow/signals")

    """
    ## Execution — Parallel Subagents (Worktree-Isolated)

    Each coder gets its own git worktree (complete filesystem isolation). Coders are fully
    self-sufficient: they implement, verify, commit, push, open a PR, and write a signal file.

    1. Call **Agent** for ALL coders below **in a single message** (parallel execution).

    #{agent_list}

    2. Each subagent prompt MUST include:
       - The full task description, plan context, and work units (copied from sections below)
       - A `## Your Files` section from the File Ownership section below
       - **Context loading instructions** (CRITICAL for efficiency):
         ```
         BEFORE reading any source files, run these MCP tool calls:
         1. codebase action=summary module=<your-work-area>  (e.g. module=lib/memory)
         2. memory_retrieve query=<relevant-topic>
         These return AST-indexed summaries with exports, deps, and key functions.
         Only Read raw files for the specific lines you need to edit.
         ```
       - The **signal file path** for their role (absolute path — worktrees have a different cwd):
         `#{signals_dir}/#{run.id}.pr-<ROLE>.json`
       - Tell them: after opening the PR, write the signal file:
         ```
         PR_URL=$(gh pr create --base main --title "<title>" --body "<body>" | tail -1)
         echo '{"pr_url":"'$PR_URL'","role":"<ROLE>","branch":"'$(git branch --show-current)'"}' > #{signals_dir}/#{run.id}.pr-<ROLE>.json
         ```

    3. **Wait for results** — all Agent calls return when subagents complete.

    4. **Write sentinel**:
       ```
       echo '{"status":"done"}' > #{sentinel_path}
       ```\
    """
  end

  defp phase_context_section(run, infra_home, phase) do
    task_line =
      if run.task_description && run.task_description != "" do
        "Task: #{run.task_description}"
      else
        nil
      end

    [
      task_line,
      "Working directory: #{run.workspace_path || infra_home}",
      "Phase: #{phase.phase_index + 1} of #{length(run.phases)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp review_gate_instructions_section(infra_home) do
    tool_cmd =
      if File.exists?(Path.join(infra_home, "mix.exs")) do
        "mix compile --warnings-as-errors && mix test"
      else
        "tsc --noEmit && npx vitest run"
      end

    """
    ## Instructions
    You are a review gate. Run verification and emit a structured verdict.

    ### Steps
    1. Run `git diff --stat` to see what changed
    2. Read changed files and check for correctness, security issues, and style
    3. Run verification: `#{tool_cmd}`
    4. Check for common issues: hardcoded secrets, missing error handling, untested code paths

    ### Verdict Format
    Write your verdict to the verdicts file. Use exactly one of:
    - `GATE: PASS` — all checks green, code is correct and well-structured
    - `GATE: PASS_WITH_CONCERNS` — minor issues noted but acceptable to proceed
    - `GATE: BLOCK` — failing tests, type errors, security issues, or significant problems

    Include per-file notes:
    ```
    GATE: PASS

    ## File Reviews
    - `lib/foo.ex` — clean, well-tested
    - `lib/bar.ex` — minor: consider extracting helper (non-blocking)
    ```\
    """
  end

  defp pr_urls_section([]), do: nil

  defp pr_urls_section(urls) do
    list = Enum.map_join(urls, "\n", &"- #{&1}")

    """
    ## PRs to Review
    These PRs were opened by coder subagents for this run:
    #{list}\
    """
  end

  defp pr_shepherd_instructions_section do
    """
    ## Instructions
    You are the PR shepherd. Your job is to **review all PRs for this run** against the plan,
    check for bugs, and **merge** each one.

    ### Discovery
    The PRs for this run are listed in the "PRs to Review" section above.
    If that section is empty, find them with:
       `gh pr list --state open --json number,title,headRefName,url`

    ### Review Each PR
    For each PR, perform this workflow:

    2. **Plan vs Implementation** — compare the PR diff against the plan:
       - Does the code implement what the plan specified?
       - Are all files mentioned in the plan accounted for?
       - Are there unexpected changes not in the plan? Flag them.
       - Is anything from the plan missing?

    3. **Bug Review** — review the diff for correctness:
       - Logic errors, off-by-one, race conditions
       - No leftover debug code, no hardcoded values
       - Proper error handling, no swallowed errors
       - Security: injection risks, unvalidated input, exposed secrets

    4. **Verify locally** — run tests and type-check:
       - Check out the branch: `git fetch origin && git checkout <branch>`
       - Run `tsc --noEmit` and/or `mix compile --warnings-as-errors`
       - Run test suite — invoke directly (`mix test`, `npx vitest run`).
         **Do not wrap commands in `timeout` / `gtimeout`** — macOS does
         not ship GNU coreutils, and this phase already has a BEAM-level
         watchdog. A `timeout` wrapper will fail with `command not found`.
       - If issues found: fix directly on the branch, commit, push

    5. **Poll CI** — `gh pr checks` to confirm CI status
       - No checks = treat as green (repo has no required checks)
       - Failing checks: fix, push, re-poll

    6. **MERGE** — `gh pr merge --squash` (REQUIRED — unmerged PR = pipeline failure)

    7. **Verify merge** — `gh pr view --json state` → confirm `"state": "MERGED"`

    ### Merge Conflict Resolution
    ```
    git fetch origin main && git rebase origin/main
    git add . && git rebase --continue
    git push --force-with-lease
    ```
    Then re-poll CI and retry merge.

    ### Output
    Write a summary for each PR: plan alignment score, bugs found, fixes applied, merge status.\
    """
  end

  defp preflight_instructions_section(infra_home) do
    tool_cmd =
      if File.exists?(Path.join(infra_home, "mix.exs")) do
        "mix compile --warnings-as-errors && mix test"
      else
        "tsc --noEmit && npx vitest run"
      end

    """
    ## Instructions
    Pre-implementation checklist. Validate the plan before execution begins.

    ### Checks
    1. **Architecture Fit** — Does the plan align with existing patterns? Check relevant modules with `ls` and `grep`
    2. **Dependency Audit** — Are all required dependencies available? Check `mix.exs` / `package.json`
    3. **API Contract Check** — Do the proposed interfaces match existing consumers? Check imports and call sites
    4. **Security Scan** — Any secrets, injection risks, or unsafe patterns in the plan?
    5. **Scope Verification** — Is the change set reasonable? Count files to touch

    ### Verification
    Run: `#{tool_cmd}`

    ### Output Format
    Write results to the plan file:
    ```
    | Check             | Status | Notes                    |
    |-------------------|--------|--------------------------|
    | Architecture Fit  | PASS   | Follows adapter pattern  |
    | Dependency Audit  | PASS   | All deps present         |
    | ...               | ...    | ...                      |

    PREFLIGHT: PASS
    ```

    Status must be one of: `PASS`, `WARN`, `FAIL`. Overall PREFLIGHT status is FAIL if any check is FAIL.\
    """
  end

  # ---------------------------------------------------------------------------
  # Shared helpers (public for testing)
  # ---------------------------------------------------------------------------

  @doc "Truncates content to max_chars, appending a marker if truncated."
  @spec truncate_note(String.t(), pos_integer()) :: String.t()
  def truncate_note(content, max_chars \\ @vault_plan_max_chars)

  def truncate_note(nil, _max_chars), do: ""

  def truncate_note(content, max_chars) when byte_size(content) <= max_chars do
    content
  end

  def truncate_note(content, max_chars) do
    String.slice(content, 0, max_chars) <> "\n[...truncated]"
  end

  @doc false
  def read_vault_plan(run, infra_home) do
    cond do
      run.plan_note && run.plan_note != "" ->
        path = resolve_plan_path(run.plan_note, infra_home)
        read_file_safe(path)

      run.plan_summary && run.plan_summary != "" ->
        run.plan_summary

      true ->
        nil
    end
  end

  @doc false
  def read_module_summaries(infra_home, file_paths) do
    codebase_dir = Path.join(infra_home, "memory/codebase")

    if File.dir?(codebase_dir) do
      modules =
        file_paths
        |> Enum.map(&path_to_module_note/1)
        |> Enum.uniq()

      modules
      |> Enum.reduce({"", 0}, fn mod, {acc, size} ->
        if size >= @module_context_max_chars do
          {acc, size}
        else
          path = Path.join(codebase_dir, mod <> ".md")
          content = read_file_safe(path)

          if content do
            remaining = @module_context_max_chars - size
            chunk = truncate_note(content, remaining)
            new_acc = acc <> "### #{mod}\n#{chunk}\n\n"
            {new_acc, size + byte_size(chunk)}
          else
            {acc, size}
          end
        end
      end)
      |> elem(0)
      |> String.trim()
    else
      nil
    end
  end

  @doc false
  def format_learned_hints(workflow_name, phase_type) do
    hints = SelfImprovement.read_prompt_hints_for_phase(workflow_name, phase_type)

    if hints == [] do
      nil
    else
      items = Enum.map_join(hints, "\n", &"- #{&1}")
      "## Runtime Learning Hints\n#{items}"
    end
  end

  @doc false
  def format_work_units(work_units) do
    Enum.map_join(work_units, "\n", fn wu ->
      role_tag = if wu.role, do: " [#{wu.role}]", else: ""
      desc = if wu.description, do: " — #{wu.description}", else: ""
      "- `#{wu.path}`#{desc}#{role_tag}"
    end)
  end

  @doc false
  def format_agent_roster(agents) do
    Enum.map_join(agents, "\n", fn agent ->
      name = Map.get(agent, :name, Map.get(agent, "name", "agent"))
      role = Map.get(agent, :role, Map.get(agent, "role", "coder"))
      "- **#{name}** (#{role})"
    end)
  end

  @doc false
  def format_file_ownership(assignments) when is_map(assignments) do
    assignments
    |> Enum.sort_by(fn {role, _} -> Atom.to_string(role) end)
    |> Enum.map_join("\n", fn {role, files} ->
      profile = RoleAssignment.role_profile(role)
      file_list = Enum.map_join(files, ", ", &"`#{&1}`")
      "- **#{profile.name}** (#{role}): #{file_list}"
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp agent_role(agent) do
    Map.get(agent, :role, Map.get(agent, "role", "coder"))
  end

  defp agent_description(agent) do
    Map.get(agent, :description, Map.get(agent, "description"))
  end

  defp format_agent_roster_with_subagent_type(agents) do
    Enum.map_join(agents, "\n", fn agent ->
      role = agent_role(agent)
      desc = agent_description(agent)
      is_reviewer = role == "reviewer"
      label = if desc, do: "#{role} (#{desc})", else: role

      isolation_note =
        if is_reviewer,
          do: "",
          else: ", isolation: \"worktree\""

      "  - **#{label}**: `Agent(subagent_type: \"#{role}\"#{isolation_note})`"
    end)
  end

  defp join_sections(sections) do
    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp resolve_plan_path(plan_note, infra_home) do
    cond do
      Path.type(plan_note) == :absolute ->
        plan_note

      true ->
        # Vault notes are stored under memory/ — add prefix if missing
        note_path =
          if String.starts_with?(plan_note, "memory/") do
            plan_note
          else
            Path.join("memory", plan_note)
          end

        # Add .md extension if missing
        note_path =
          if String.ends_with?(note_path, ".md") do
            note_path
          else
            note_path <> ".md"
          end

        Path.join(infra_home, note_path)
    end
  end

  defp read_file_safe(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp path_to_module_note(file_path) do
    file_path
    |> Path.rootname()
    |> String.replace(~r{^(lib|src)/}, "")
    |> String.replace("/", "-")
  end

  defp extract_all_plan_files(run, phase) do
    wu_paths =
      phase.work_units
      |> Enum.map(& &1.path)
      |> Enum.reject(&is_nil/1)

    plan_paths =
      if run.plan_summary do
        RoleAssignment.extract_plan_files(run.plan_summary)
      else
        []
      end

    (wu_paths ++ plan_paths) |> Enum.uniq()
  end
end
