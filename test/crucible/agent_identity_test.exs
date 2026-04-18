defmodule Crucible.AgentIdentityTest do
  use ExUnit.Case, async: true

  alias Crucible.AgentIdentity

  @tmp_dir System.tmp_dir!()
           |> Path.join("agent_identity_test_#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(Path.join(@tmp_dir, ".claude/agents"))
    File.mkdir_p!(Path.join(@tmp_dir, "memory/agents"))
    File.mkdir_p!(Path.join(@tmp_dir, ".claude-flow/logs/traces"))

    # Write a sample role definition
    File.write!(
      Path.join(@tmp_dir, ".claude/agents/coder.yml"),
      """
      ---
      name: coder
      description: Backend coding agent
      model: claude-sonnet-4-6
      ---
      """
    )

    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "get_identity/2" do
    test "returns identity for known agent" do
      identity = AgentIdentity.get_identity("coder", infra_home: @tmp_dir)
      assert identity != nil
      assert identity.name == "coder"
      assert is_float(identity.trust_score)
      assert identity.trust_score >= 0.0 and identity.trust_score <= 1.0
    end

    test "returns nil for unknown agent" do
      identity = AgentIdentity.get_identity("nonexistent", infra_home: @tmp_dir)
      assert identity == nil
    end
  end

  describe "list_agents/1" do
    test "returns list of agents" do
      agents = AgentIdentity.list_agents(infra_home: @tmp_dir)
      assert is_list(agents)
      assert length(agents) >= 1
      assert Enum.any?(agents, &(&1.name == "coder"))
    end

    test "agents sorted by trust_score descending" do
      agents = AgentIdentity.list_agents(infra_home: @tmp_dir)
      scores = Enum.map(agents, & &1.trust_score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "recommend/2" do
    test "returns recommendations for task type" do
      recs = AgentIdentity.recommend("backend coding", infra_home: @tmp_dir)
      assert is_list(recs)
      assert length(recs) >= 1
      assert Enum.all?(recs, &Map.has_key?(&1, :recommendation_score))
    end

    test "recommendations sorted by score descending" do
      recs = AgentIdentity.recommend("coding", infra_home: @tmp_dir)
      scores = Enum.map(recs, & &1.recommendation_score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "atom safety" do
    test "unknown YAML keys in role file are not interned as atoms" do
      novel_key = "xyzzy_novel_key_#{System.unique_integer([:positive])}"

      File.write!(
        Path.join(@tmp_dir, ".claude/agents/novel-agent.yml"),
        """
        ---
        name: novel-agent
        #{novel_key}: some_value
        ---
        """
      )

      _identity = AgentIdentity.get_identity("novel-agent", infra_home: @tmp_dir)

      # The critical invariant: the novel key must NOT have been interned as an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel_key) end
    end

    test "unknown track-record keys in identity note are not interned as atoms" do
      novel_key = "zork_track_key_#{System.unique_integer([:positive])}"

      content = """
      ---
      title: "Agent: mystery-agent"
      memoryType: agent-identity
      ---

      ## Track Record
      - **#{novel_key}**: 42
      - **total_tasks**: 5
      - **successes**: 4
      """

      File.mkdir_p!(Path.join(@tmp_dir, "memory/agents"))
      File.write!(Path.join(@tmp_dir, "memory/agents/mystery-agent.md"), content)

      _identity = AgentIdentity.get_identity("mystery-agent", infra_home: @tmp_dir)

      # The critical invariant: the novel key must NOT have been interned as an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel_key) end
    end
  end

  describe "update_identity/3" do
    test "creates identity note for new agent" do
      assert :ok =
               AgentIdentity.update_identity(
                 "test-agent",
                 %{
                   task_type: "coding",
                   success: true,
                   cost: 0.50
                 },
                 infra_home: @tmp_dir
               )

      path = Path.join([@tmp_dir, "memory/agents", "test-agent.md"])
      assert File.exists?(path)

      content = File.read!(path)
      assert String.contains?(content, "test-agent")
      assert String.contains?(content, "total_tasks")
    end

    test "accumulates task count on repeated updates" do
      opts = [infra_home: @tmp_dir]

      AgentIdentity.update_identity(
        "counter-agent",
        %{
          task_type: "review",
          success: true,
          cost: 0.10
        },
        opts
      )

      AgentIdentity.update_identity(
        "counter-agent",
        %{
          task_type: "coding",
          success: true,
          cost: 0.20
        },
        opts
      )

      identity = AgentIdentity.get_identity("counter-agent", opts)
      track = get_in(identity, [:identity, :track_record])
      assert track.total_tasks == 2
    end
  end
end
