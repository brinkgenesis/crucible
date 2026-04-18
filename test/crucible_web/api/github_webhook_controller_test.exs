defmodule CrucibleWeb.Api.GithubWebhookControllerTest do
  use CrucibleWeb.ConnCase

  alias Crucible.Repo
  alias Crucible.Schema.Card

  describe "POST /api/v1/webhooks/github" do
    test "moves card to done when associated PR is merged", %{conn: conn} do
      # Create a card with a run_id matching the branch pattern
      run_id = "abc123def456xyz"
      {:ok, card} = Repo.insert(%Card{
        id: Ecto.UUID.generate(),
        title: "Test sprint card",
        column: "review",
        run_id: run_id
      })

      # Simulate GitHub pull_request merged webhook
      conn =
        conn
        |> put_req_header("x-github-event", "pull_request")
        |> post("/api/v1/webhooks/github", %{
          "action" => "closed",
          "pull_request" => %{
            "number" => 42,
            "merged" => true,
            "head" => %{"ref" => "run/abc123def456"}
          }
        })

      assert json_response(conn, 200)["status"] == "ok"

      updated = Repo.get!(Card, card.id)
      assert updated.column == "done"
    end

    test "ignores PR from non-run branch", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-github-event", "pull_request")
        |> post("/api/v1/webhooks/github", %{
          "action" => "closed",
          "pull_request" => %{
            "number" => 99,
            "merged" => true,
            "head" => %{"ref" => "feature/some-branch"}
          }
        })

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "ignores closed-without-merge PR", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-github-event", "pull_request")
        |> post("/api/v1/webhooks/github", %{
          "action" => "closed",
          "pull_request" => %{
            "number" => 99,
            "merged" => false,
            "head" => %{"ref" => "run/abc123"}
          }
        })

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "ignores non-pull_request events", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> post("/api/v1/webhooks/github", %{"ref" => "refs/heads/main"})

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "does not move card already in done", %{conn: conn} do
      run_id = "donealready12345"
      {:ok, card} = Repo.insert(%Card{
        id: Ecto.UUID.generate(),
        title: "Already done card",
        column: "done",
        run_id: run_id
      })

      conn =
        conn
        |> put_req_header("x-github-event", "pull_request")
        |> post("/api/v1/webhooks/github", %{
          "action" => "closed",
          "pull_request" => %{
            "number" => 55,
            "merged" => true,
            "head" => %{"ref" => "run/donealready12"}
          }
        })

      assert json_response(conn, 200)["status"] == "ignored"

      # Card stays done, version unchanged
      unchanged = Repo.get!(Card, card.id)
      assert unchanged.column == "done"
    end
  end
end
