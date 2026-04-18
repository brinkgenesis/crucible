defmodule Crucible.Schema.PolicyConfigTest do
  use ExUnit.Case, async: true

  alias Crucible.Schema.PolicyConfig

  describe "changeset/2" do
    test "valid with no fields (all optional)" do
      cs = PolicyConfig.changeset(%PolicyConfig{}, %{})
      assert cs.valid?
    end

    test "accepts valid variant values" do
      for variant <- ~w(active candidate) do
        cs = PolicyConfig.changeset(%PolicyConfig{}, %{variant: variant})
        assert cs.valid?, "expected #{variant} to be valid"
      end
    end

    test "rejects invalid variant" do
      cs = PolicyConfig.changeset(%PolicyConfig{}, %{variant: "invalid"})
      refute cs.valid?
      assert cs.errors[:variant]
    end

    test "accepts policy_id and timings" do
      cs = PolicyConfig.changeset(%PolicyConfig{}, %{
        policy_id: "pol-123",
        timings: %{"p50" => 1200, "p99" => 5000}
      })
      assert cs.valid?
    end

    test "defaults canary to false" do
      config = %PolicyConfig{}
      assert config.canary == false
    end
  end
end
