defmodule Crucible.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias Crucible.PromptBuilder
  alias Crucible.Types.{Run, Phase, WorkUnit}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_run(overrides \\ %{}) do
    Map.merge(
      %Run{
        id: "run-001",
        workflow_type: "feature",
        plan_note: nil,
        plan_summary: "Implement the widget feature",
        branch: "feat/widget",
        workspace_path: "/tmp/test-workspace",
        budget_usd: 25.0
      },
      overrides
    )
  end

  defp make_phase(type, overrides \\ %{}) do
    Map.merge(
      %Phase{
        id: "phase-001",
        name: "implement-feature",
        type: type,
        work_units: [
          %WorkUnit{
            path: "lib/foo.ex",
            description: "implement new feature",
            role: "coder_backend"
          },
          %WorkUnit{path: "lib/bar.ex", description: "add helper", role: nil}
        ],
        agents: [
          %{name: "Alice", role: "coder_backend"},
          %{name: "Bob", role: "coder_runtime"}
        ]
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # render/2 (backward compatibility)
  # ---------------------------------------------------------------------------

  describe "render/2" do
    test "renders a simple template" do
      assert {:ok, result} = PromptBuilder.render("Hello {{ name }}!", %{"name" => "World"})
      assert result == "Hello World!"
    end

    test "renders template with conditionals" do
      template = """
      {% if plan %}Plan: {{ plan }}{% endif %}
      Task: {{ task }}
      """

      assert {:ok, result} =
               PromptBuilder.render(template, %{"plan" => "Build it", "task" => "Code"})

      assert result =~ "Plan: Build it"
      assert result =~ "Task: Code"
    end

    test "renders template without optional values" do
      template = "{% if plan %}Plan: {{ plan }}{% endif %}Task: {{ task }}"

      assert {:ok, result} = PromptBuilder.render(template, %{"task" => "Code"})
      refute result =~ "Plan:"
      assert result =~ "Task: Code"
    end

    test "renders template with loops" do
      template = "{% for unit in work_units %}- {{ unit }}\n{% endfor %}"

      assert {:ok, result} =
               PromptBuilder.render(template, %{"work_units" => ["file1.ex", "file2.ex"]})

      assert result =~ "- file1.ex"
      assert result =~ "- file2.ex"
    end

    test "returns error for invalid template" do
      assert {:error, _} = PromptBuilder.render("{% if %}", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # truncate_note/2
  # ---------------------------------------------------------------------------

  describe "truncate_note/2" do
    test "returns content unchanged when under limit" do
      content = "Short content"
      assert PromptBuilder.truncate_note(content, 12_000) == content
    end

    test "truncates at max_chars and adds marker" do
      content = String.duplicate("x", 15_000)
      result = PromptBuilder.truncate_note(content, 12_000)
      assert String.length(result) < 15_000
      assert result =~ "[...truncated]"
    end

    test "handles nil content" do
      assert PromptBuilder.truncate_note(nil) == ""
    end

    test "uses default max of 12_000" do
      content = String.duplicate("a", 13_000)
      result = PromptBuilder.truncate_note(content)
      assert result =~ "[...truncated]"
    end

    test "does not truncate at exactly max_chars" do
      content = String.duplicate("b", 100)
      result = PromptBuilder.truncate_note(content, 100)
      assert result == content
    end
  end

  # ---------------------------------------------------------------------------
  # build/3 dispatch
  # ---------------------------------------------------------------------------

  describe "build/3 dispatches by phase type" do
    test "session type produces session instructions" do
      result =
        PromptBuilder.build(make_run(), make_phase(:session), infra_home: "/tmp/nonexistent")

      assert result =~ "## Phase: implement-feature (session)"
      assert result =~ "## Instructions"
      assert result =~ "solo coding session"
    end

    test "team type produces team instructions" do
      result = PromptBuilder.build(make_run(), make_phase(:team), infra_home: "/tmp/nonexistent")
      assert result =~ "ORCHESTRATOR"
      assert result =~ "DO NOT IMPLEMENT"
      assert result =~ "Do NOT use TeamCreate"
    end

    test "review_gate type produces review gate instructions" do
      result =
        PromptBuilder.build(make_run(), make_phase(:review_gate), infra_home: "/tmp/nonexistent")

      assert result =~ "## Phase: implement-feature (review_gate)"
      assert result =~ "GATE: PASS"
      assert result =~ "GATE: BLOCK"
    end

    test "pr_shepherd type produces PR shepherd instructions" do
      result =
        PromptBuilder.build(make_run(), make_phase(:pr_shepherd), infra_home: "/tmp/nonexistent")

      assert result =~ "## Phase: implement-feature (pr_shepherd)"
      assert result =~ "PR shepherd"
    end

    test "preflight type produces preflight instructions" do
      result =
        PromptBuilder.build(make_run(), make_phase(:preflight), infra_home: "/tmp/nonexistent")

      assert result =~ "## Phase: implement-feature (preflight)"
      assert result =~ "Pre-implementation checklist"
    end

    test "unknown type falls back to session" do
      phase = make_phase(:session, %{type: :unknown_type})
      result = PromptBuilder.build(make_run(), phase, infra_home: "/tmp/nonexistent")
      assert result =~ "solo coding session"
    end
  end

  # ---------------------------------------------------------------------------
  # Section content verification
  # ---------------------------------------------------------------------------

  describe "session prompt sections" do
    test "includes plan summary when plan_note is nil" do
      run = make_run(%{plan_note: nil, plan_summary: "Do the thing"})
      result = PromptBuilder.build(run, make_phase(:session), infra_home: "/tmp/nonexistent")
      assert result =~ "## Plan"
      assert result =~ "Do the thing"
    end

    test "includes work units section" do
      result =
        PromptBuilder.build(make_run(), make_phase(:session), infra_home: "/tmp/nonexistent")

      assert result =~ "## Work Units"
      assert result =~ "`lib/foo.ex`"
      assert result =~ "implement new feature"
    end

    test "includes phase header with ID" do
      result =
        PromptBuilder.build(make_run(), make_phase(:session), infra_home: "/tmp/nonexistent")

      assert result =~ "Phase ID: phase-001"
    end
  end

  describe "team prompt sections" do
    test "includes agent roster in spawn instructions" do
      result = PromptBuilder.build(make_run(), make_phase(:team), infra_home: "/tmp/nonexistent")
      assert result =~ "coder_backend"
      assert result =~ "coder_runtime"
      assert result =~ "subagent_type"
    end

    test "includes file ownership section" do
      result = PromptBuilder.build(make_run(), make_phase(:team), infra_home: "/tmp/nonexistent")
      assert result =~ "## File Ownership"
    end

    test "includes parallel subagent instructions" do
      result = PromptBuilder.build(make_run(), make_phase(:team), infra_home: "/tmp/nonexistent")
      assert result =~ "Parallel Subagents"
      assert result =~ "in a single message"
      assert result =~ "Write sentinel"
    end
  end

  describe "team prompt complexity scaling" do
    test "complexity 1 scales to single agent in spawn instructions" do
      run = make_run(%{complexity: 1})

      phase =
        make_phase(:team, %{
          agents: [
            %{name: "Ava", role: "coder-backend", description: "Backend Engineer"},
            %{name: "Marco", role: "coder-runtime", description: "Runtime Engineer"},
            %{name: "Lena", role: "coder-frontend", description: "Frontend Engineer"}
          ]
        })

      result = PromptBuilder.build(run, phase, infra_home: "/tmp/nonexistent")
      assert result =~ "coder-backend"
      refute result =~ "coder-runtime"
      refute result =~ "coder-frontend"
    end

    test "complexity 2 scales to two agents in spawn instructions" do
      run = make_run(%{complexity: 2})

      phase =
        make_phase(:team, %{
          agents: [
            %{name: "Ava", role: "coder-backend", description: "Backend Engineer"},
            %{name: "Marco", role: "coder-runtime", description: "Runtime Engineer"},
            %{name: "Lena", role: "coder-frontend", description: "Frontend Engineer"}
          ]
        })

      result = PromptBuilder.build(run, phase, infra_home: "/tmp/nonexistent")
      assert result =~ "coder-backend"
      assert result =~ "coder-runtime"
      refute result =~ "coder-frontend"
    end

    test "nil complexity keeps all agents" do
      run = make_run(%{complexity: nil})

      phase =
        make_phase(:team, %{
          agents: [
            %{name: "Ava", role: "coder-backend"},
            %{name: "Marco", role: "coder-runtime"}
          ]
        })

      result = PromptBuilder.build(run, phase, infra_home: "/tmp/nonexistent")
      assert result =~ "coder-backend"
      assert result =~ "coder-runtime"
    end
  end

  describe "review gate prompt sections" do
    test "includes files changed section" do
      result =
        PromptBuilder.build(make_run(), make_phase(:review_gate), infra_home: "/tmp/nonexistent")

      assert result =~ "## Files Changed"
      assert result =~ "`lib/foo.ex`"
    end

    test "includes PASS_WITH_CONCERNS verdict" do
      result =
        PromptBuilder.build(make_run(), make_phase(:review_gate), infra_home: "/tmp/nonexistent")

      assert result =~ "GATE: PASS_WITH_CONCERNS"
    end
  end

  describe "pr_shepherd prompt sections" do
    test "includes PR context with branch" do
      result =
        PromptBuilder.build(make_run(), make_phase(:pr_shepherd), infra_home: "/tmp/nonexistent")

      assert result =~ "## PR Context"
      assert result =~ "feat/widget"
    end

    test "includes plan vs implementation review" do
      result =
        PromptBuilder.build(make_run(), make_phase(:pr_shepherd), infra_home: "/tmp/nonexistent")

      assert result =~ "Plan vs Implementation"
      assert result =~ "plan alignment score"
    end
  end

  describe "preflight prompt sections" do
    test "includes test/compile commands" do
      result =
        PromptBuilder.build(make_run(), make_phase(:preflight), infra_home: "/tmp/nonexistent")

      # Non-existent dir so no mix.exs → falls back to tsc/vitest
      assert result =~ "tsc --noEmit" or result =~ "mix compile"
    end

    test "instructs not to proceed on failure" do
      result =
        PromptBuilder.build(make_run(), make_phase(:preflight), infra_home: "/tmp/nonexistent")

      assert result =~ "PREFLIGHT status is FAIL if any check is FAIL"
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "graceful handling of missing data" do
    test "missing vault plan does not crash" do
      run = make_run(%{plan_note: nil, plan_summary: nil})
      result = PromptBuilder.build(run, make_phase(:session), infra_home: "/tmp/nonexistent")
      refute result =~ "## Plan"
      assert result =~ "## Phase:"
    end

    test "empty work units omits work units section" do
      phase = make_phase(:session, %{work_units: []})
      result = PromptBuilder.build(make_run(), phase, infra_home: "/tmp/nonexistent")
      refute result =~ "## Work Units"
    end

    test "empty agents omits agent roster section" do
      phase = make_phase(:team, %{agents: []})
      result = PromptBuilder.build(make_run(), phase, infra_home: "/tmp/nonexistent")
      refute result =~ "## Agent Roster"
    end

    test "nonexistent plan_note file does not crash" do
      run = make_run(%{plan_note: "/tmp/nonexistent/plan.md", plan_summary: nil})
      result = PromptBuilder.build(run, make_phase(:session), infra_home: "/tmp/nonexistent")
      # Should not crash, plan section just gets omitted
      assert is_binary(result)
      assert result =~ "## Phase:"
    end
  end

  # ---------------------------------------------------------------------------
  # Client context injection
  # ---------------------------------------------------------------------------

  describe "client context injection" do
    test "includes client context in session prompt when provided" do
      ctx = "## Client Context\nClient: Acme Corp\nAccounting system: quickbooks"

      result =
        PromptBuilder.build(make_run(), make_phase(:session),
          infra_home: "/tmp/nonexistent",
          client_context: ctx
        )

      assert result =~ "## Client Context"
      assert result =~ "Acme Corp"
      assert result =~ "quickbooks"
    end

    test "includes client context in team prompt when provided" do
      ctx = "## Client Context\nClient: Acme Corp"

      result =
        PromptBuilder.build(make_run(), make_phase(:team),
          infra_home: "/tmp/nonexistent",
          client_context: ctx
        )

      assert result =~ "## Client Context"
    end

    test "includes client context in review_gate prompt when provided" do
      ctx = "## Client Context\nClient: Acme Corp"

      result =
        PromptBuilder.build(make_run(), make_phase(:review_gate),
          infra_home: "/tmp/nonexistent",
          client_context: ctx
        )

      assert result =~ "## Client Context"
    end

    test "includes client context in pr_shepherd prompt when provided" do
      ctx = "## Client Context\nClient: Acme Corp"

      result =
        PromptBuilder.build(make_run(), make_phase(:pr_shepherd),
          infra_home: "/tmp/nonexistent",
          client_context: ctx
        )

      assert result =~ "## Client Context"
    end

    test "includes client context in preflight prompt when provided" do
      ctx = "## Client Context\nClient: Acme Corp"

      result =
        PromptBuilder.build(make_run(), make_phase(:preflight),
          infra_home: "/tmp/nonexistent",
          client_context: ctx
        )

      assert result =~ "## Client Context"
    end

    test "omits client context when not provided" do
      result =
        PromptBuilder.build(make_run(), make_phase(:session), infra_home: "/tmp/nonexistent")

      refute result =~ "## Client Context"
    end
  end
end
