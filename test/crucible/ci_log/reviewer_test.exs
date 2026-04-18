defmodule Crucible.CiLog.ReviewerTest do
  use ExUnit.Case, async: true

  alias Crucible.CiLog.Reviewer
  alias Crucible.Schema.CiLogEvent

  defp make_event(overrides \\ %{}) do
    base = %CiLogEvent{
      id: Ecto.UUID.generate(),
      run_id: "12345",
      workflow_name: "CI Tests",
      conclusion: "failure",
      duration_ms: 45_000,
      failure_summary: "Error: test failed",
      raw_log: "Step 1: compile\nStep 2: test\nError: assertion failed in test_foo",
      analyzed_at: nil,
      created_at: DateTime.utc_now()
    }

    Map.merge(base, overrides)
  end

  describe "build_user_prompt/1" do
    test "includes workflow name, conclusion, and duration" do
      event = make_event()
      prompt = Reviewer.build_user_prompt(event)

      assert prompt =~ "Workflow: CI Tests"
      assert prompt =~ "Conclusion: failure"
      assert prompt =~ "Duration: 45000ms"
    end

    test "includes raw log content" do
      event = make_event(%{raw_log: "some error output here"})
      prompt = Reviewer.build_user_prompt(event)

      assert prompt =~ "some error output here"
    end

    test "includes JSON schema in prompt" do
      event = make_event()
      prompt = Reviewer.build_user_prompt(event)

      assert prompt =~ "\"category\""
      assert prompt =~ "\"severity\""
      assert prompt =~ "\"suggestedFix\""
      assert prompt =~ "\"isRecurring\""
    end
  end

  describe "parse_analysis/1" do
    test "parses valid JSON response" do
      json =
        ~s|{"category":"test_failure","severity":"critical","title":"Foo test fails","summary":"The foo test broke.","suggestedFix":"Fix the foo.","isRecurring":false}|

      assert {:ok, analysis} = Reviewer.parse_analysis(json)
      assert analysis.category == "test_failure"
      assert analysis.severity == "critical"
      assert analysis.title == "Foo test fails"
      assert analysis.summary == "The foo test broke."
      assert analysis.suggested_fix == "Fix the foo."
      assert analysis.is_recurring == false
    end

    test "extracts JSON embedded in surrounding text" do
      text =
        ~s|Here is my analysis:\n{"category":"build_failure","severity":"warning","title":"Build timeout","summary":"Build took too long.","suggestedFix":"Increase timeout.","isRecurring":true}\nDone.|

      assert {:ok, analysis} = Reviewer.parse_analysis(text)
      assert analysis.category == "build_failure"
      assert analysis.is_recurring == true
    end

    test "returns :error for missing required fields" do
      json = ~s|{"category":"test_failure","severity":"critical"}|
      assert :error = Reviewer.parse_analysis(json)
    end

    test "returns :error for invalid category" do
      json =
        ~s|{"category":"unknown_cat","severity":"critical","title":"T","summary":"S","suggestedFix":"F","isRecurring":false}|

      assert :error = Reviewer.parse_analysis(json)
    end

    test "returns :error for non-JSON text" do
      assert :error = Reviewer.parse_analysis("This is not JSON at all")
    end

    test "returns :error for empty string" do
      assert :error = Reviewer.parse_analysis("")
    end
  end

  describe "review/2 with mock router" do
    test "returns parsed analysis on valid LLM response" do
      valid_json =
        ~s|{"category":"flaky_test","severity":"warning","title":"Flaky login test","summary":"Login test fails intermittently.","suggestedFix":"Add retry.","isRecurring":true}|

      mock_router = fn _request ->
        {:ok, %{text: valid_json}}
      end

      event = make_event()
      assert {:ok, analysis} = Reviewer.review(event, mock_router)
      assert analysis.category == "flaky_test"
      assert analysis.severity == "warning"
      assert analysis.is_recurring == true
    end

    test "returns fallback on unparseable LLM response" do
      mock_router = fn _request ->
        {:ok, %{text: "I cannot analyze this log."}}
      end

      event = make_event()
      assert {:ok, analysis} = Reviewer.review(event, mock_router)
      assert analysis.category == "infra_issue"
      assert analysis.severity == "warning"
      assert analysis.title == "Parse error"
      assert analysis.suggested_fix == "Manual review needed"
    end

    test "returns fallback on router error" do
      mock_router = fn _request ->
        {:error, :timeout}
      end

      event = make_event()
      assert {:ok, analysis} = Reviewer.review(event, mock_router)
      assert analysis.category == "infra_issue"
      assert analysis.title == "Parse error"
    end

    test "passes correct router request shape" do
      captured_request = :erlang.make_ref()
      test_pid = self()

      mock_router = fn request ->
        send(test_pid, {captured_request, request})

        {:ok,
         %{
           text:
             ~s|{"category":"test_failure","severity":"info","title":"T","summary":"S","suggestedFix":"F","isRecurring":false}|
         }}
      end

      event = make_event()
      Reviewer.review(event, mock_router)

      assert_receive {^captured_request, request}
      assert request.complexity_hint == 4
      assert request.strategy == :cost
      assert request.max_tokens == 1024
      assert is_binary(request.prompt)
      assert is_binary(request.system_prompt)
    end
  end
end
