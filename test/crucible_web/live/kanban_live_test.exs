defmodule CrucibleWeb.KanbanLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Crucible.{Repo, VaultPlanStore}
  alias Crucible.Schema.Card

  setup do
    prev_orchestrator_config = Application.get_env(:crucible, :orchestrator, [])

    repo_root =
      Path.join(System.tmp_dir!(), "kanban-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([repo_root, "memory"]))

    Application.put_env(
      :crucible,
      :orchestrator,
      Keyword.put(prev_orchestrator_config, :repo_root, repo_root)
    )

    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    on_exit(fn ->
      Application.put_env(:crucible, :orchestrator, prev_orchestrator_config)
      File.rm_rf!(repo_root)
    end)

    {:ok, repo_root: repo_root}
  end

  test "renders kanban board with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/kanban")
    assert html =~ "TACTICAL_PIPELINE"
  end

  test "shows column headers for all kanban columns", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/kanban")
    assert html =~ "Ideation"
    assert html =~ "Unassigned"
    assert html =~ "To Do"
    assert html =~ "In Progress"
    assert html =~ "Review"
    assert html =~ "Done"
  end

  test "shows add card button", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/kanban")
    assert has_element?(view, ~s(button[phx-click="toggle_add_form"]))
  end

  test "syncs the execution mode from the client hook", %{conn: conn} do
    {:ok, view, html} = conn |> authenticate() |> live("/kanban")
    assert html =~ "EXEC_SDK"

    html =
      view
      |> element("#kanban-execution-mode-sync")
      |> render_hook("set_execution_mode", %{"mode" => "api"})

    assert html =~ "EXEC_API"
  end

  test "toggle_add_form shows the card creation form", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/kanban")
    html = render_click(view, "toggle_add_form")
    assert html =~ "ENTER_OBJECTIVE_NAME..."
    assert html =~ "DEPLOY"
  end

  test "renders cards whose planned phases are stored as JSON arrays", %{conn: conn} do
    card_id = Ecto.UUID.generate()

    %Card{id: card_id}
    |> Card.changeset(%{
      title: "Shared DB planned card",
      column: "todo",
      phase_cards: [
        %{
          "id" => Ecto.UUID.generate(),
          "phaseIndex" => 0,
          "phaseName" => "sprint",
          "type" => "team",
          "agents" => ["coder-backend"],
          "parallel" => true,
          "status" => "completed",
          "dependsOn" => [],
          "estimatedCostUsd" => 0
        },
        %{
          "id" => Ecto.UUID.generate(),
          "phaseIndex" => 1,
          "phaseName" => "pr-shepherd",
          "type" => "pr-shepherd",
          "agents" => [],
          "parallel" => false,
          "status" => "completed",
          "dependsOn" => ["sprint"],
          "estimatedCostUsd" => 0
        }
      ],
      phase_depends_on: ["sprint"]
    })
    |> Repo.insert!()

    {:ok, _view, html} = conn |> authenticate() |> live("/kanban")

    assert html =~ "Shared DB planned card"
  end

  test "shows plan summary hover content and opens the vault plan popup", %{
    conn: conn,
    repo_root: _repo_root
  } do
    {:ok, plan_note} =
      VaultPlanStore.store_plan("card-plan-001", "Investigate benchmark regression", %{
        summary: "Recover the regressed benchmark by tightening workflow steps and token use.",
        approach:
          "Start from the failing benchmark evidence, then re-run after each targeted fix.",
        actionable_steps: ["Inspect the trace", "Tighten the workflow", "Re-run the benchmark"],
        affected_files: [
          "workflows/coding-sprint.yaml",
          "orchestrator/lib/crucible/self_improvement.ex"
        ],
        effort_estimate: "M"
      })

    card_id = Ecto.UUID.generate()

    %Card{id: card_id}
    |> Card.changeset(%{
      title: "Benchmark regression follow-up",
      column: "unassigned",
      workflow: "coding-sprint",
      metadata: %{
        "planSummary" =>
          "Recover the regressed benchmark by tightening workflow steps and token use.",
        "planNote" => plan_note,
        "planWikiLink" => "[[#{plan_note}]]"
      }
    })
    |> Repo.insert!()

    {:ok, view, html} = conn |> authenticate() |> live("/kanban")

    assert html =~ "Benchmark regression follow-up"
    assert html =~ "Recover the regressed benchmark by tightening workflow steps and token use."
    assert html =~ "CLICK_TO_VIEW_PLAN"

    # Open the card detail modal — plan tab auto-selects when plan exists
    html = render_click(view, "show_card_detail", %{"id" => card_id})

    assert html =~ "Benchmark regression follow-up"
  end

  test "unassigned cards get a selection checkbox; other columns do not", %{conn: conn} do
    unassigned_id = Ecto.UUID.generate()
    todo_id = Ecto.UUID.generate()

    %Card{id: unassigned_id}
    |> Card.changeset(%{title: "Pick me", column: "unassigned"})
    |> Repo.insert!()

    %Card{id: todo_id}
    |> Card.changeset(%{title: "Already running", column: "todo"})
    |> Repo.insert!()

    {:ok, _view, html} = conn |> authenticate() |> live("/kanban")

    assert html =~ ~s(aria-label="Select card #{unassigned_id}")
    refute html =~ ~s(aria-label="Select card #{todo_id}")
  end

  test "toggle_card_selected reveals the batch bar and clear_selection hides it", %{conn: conn} do
    card_id = Ecto.UUID.generate()

    %Card{id: card_id}
    |> Card.changeset(%{title: "Batchable", column: "unassigned"})
    |> Repo.insert!()

    {:ok, view, html} = conn |> authenticate() |> live("/kanban")
    refute html =~ "EXECUTE ("

    html = render_click(view, "toggle_card_selected", %{"id" => card_id})
    assert html =~ "EXECUTE (1)"

    html = render_click(view, "clear_selection", %{})
    refute html =~ "EXECUTE ("
  end

  test "build_manifest includes the selected execution mode" do
    manifest =
      CrucibleWeb.KanbanLive.build_manifest(
        "run-api-001",
        %{"name" => "coding-sprint"},
        %{
          id: Ecto.UUID.generate(),
          title: "Benchmark the harness",
          metadata: %{
            "planNote" => "memory/decisions/plan-001",
            "planSummary" => "Tighten execution."
          }
        },
        "api"
      )

    assert manifest["execution_type"] == "api"
    assert manifest["plan_note"] == "memory/decisions/plan-001"
    assert manifest["plan_summary"] == "Tighten execution."
  end
end
