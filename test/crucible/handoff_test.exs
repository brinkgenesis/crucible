defmodule Crucible.HandoffTest do
  use ExUnit.Case, async: true

  alias Crucible.Handoff

  describe "parse_sections/1" do
    test "returns empty sections for nil" do
      sections = Handoff.parse_sections(nil)
      assert sections.decisions == []
      assert sections.lessons == []
      assert sections.open_questions == []
      assert sections.next_steps == []
      assert sections.raw == ""
    end

    test "returns empty sections for empty string" do
      sections = Handoff.parse_sections("")
      assert sections.decisions == []
      assert sections.raw == ""
    end

    test "parses markdown header sections with bullets" do
      text = """
      ## Decisions
      - Use GenServer for state management
      - Store KPIs in ETS

      ## Lessons
      - Always validate input types

      ## Open Questions
      - Should we shard by tenant?

      ## Next Steps
      - Implement the sharding logic
      - Write integration tests
      """

      sections = Handoff.parse_sections(text)
      assert sections.decisions == ["Use GenServer for state management", "Store KPIs in ETS"]
      assert sections.lessons == ["Always validate input types"]
      assert sections.open_questions == ["Should we shard by tenant?"]
      assert sections.next_steps == ["Implement the sharding logic", "Write integration tests"]
      assert sections.raw == ""
    end

    test "parses bold header variants" do
      text = """
      **Decisions made**:
      - Chose Phoenix over Plug
      **Lessons learned**:
      - PubSub is faster than polling
      **Next steps**:
      - Deploy to staging
      """

      sections = Handoff.parse_sections(text)
      assert sections.decisions == ["Chose Phoenix over Plug"]
      assert sections.lessons == ["PubSub is faster than polling"]
      assert sections.next_steps == ["Deploy to staging"]
    end

    test "parses plain text header variants" do
      text = """
      Decisions made:
      - Item A
      Lessons:
      - Item B
      Blockers
      - Blocked by upstream API
      Recommended
      - Fix upstream first
      """

      sections = Handoff.parse_sections(text)
      assert sections.decisions == ["Item A"]
      assert sections.lessons == ["Item B"]
      assert sections.open_questions == ["Blocked by upstream API"]
      assert sections.next_steps == ["Fix upstream first"]
    end

    test "unstructured text goes to raw" do
      text = "Just some notes about the session.\nNothing structured here."
      sections = Handoff.parse_sections(text)
      assert sections.decisions == []
      assert sections.raw =~ "Just some notes"
      assert sections.raw =~ "Nothing structured"
    end

    test "mixed structured and unstructured" do
      text = """
      Some context about the work.
      ## Decisions
      - Decided to refactor the router
      More unstructured notes.
      """

      sections = Handoff.parse_sections(text)
      assert sections.decisions == ["Decided to refactor the router", "More unstructured notes."]
      assert sections.raw =~ "Some context"
    end

    test "handles asterisk bullets" do
      text = """
      ## Lessons
      * Always run tests
      * Check types first
      """

      sections = Handoff.parse_sections(text)
      assert sections.lessons == ["Always run tests", "Check types first"]
    end
  end

  describe "validate_completeness/1" do
    test "returns empty list when no structured content" do
      sections = Handoff.parse_sections("Just raw text")
      assert Handoff.validate_completeness(sections) == []
    end

    test "returns empty list when all sections present" do
      sections = %{
        decisions: ["D1"],
        lessons: ["L1"],
        open_questions: ["Q1"],
        next_steps: ["N1"],
        raw: ""
      }

      assert Handoff.validate_completeness(sections) == []
    end

    test "flags missing next_steps when other sections exist" do
      sections = %{
        decisions: ["D1"],
        lessons: ["L1"],
        open_questions: [],
        next_steps: [],
        raw: ""
      }

      assert Handoff.validate_completeness(sections) == ["next_steps"]
    end
  end

  describe "has_structured_content?/1" do
    test "returns false for empty sections" do
      assert Handoff.has_structured_content?(Handoff.parse_sections("")) == false
    end

    test "returns true when any section has content" do
      sections = %{decisions: ["D1"], lessons: [], open_questions: [], next_steps: [], raw: ""}
      assert Handoff.has_structured_content?(sections) == true
    end
  end
end
