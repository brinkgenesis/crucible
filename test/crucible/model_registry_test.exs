defmodule Crucible.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias Crucible.ModelRegistry

  describe "list_models/0" do
    test "returns all models" do
      models = ModelRegistry.list_models()
      assert length(models) >= 6
      assert Enum.all?(models, &Map.has_key?(&1, :id))
      assert Enum.all?(models, &Map.has_key?(&1, :provider))
      assert Enum.all?(models, &Map.has_key?(&1, :context_window))
    end

    test "includes expected models" do
      ids = ModelRegistry.list_models() |> Enum.map(& &1.id)
      assert "claude-opus-4-6" in ids
      assert "claude-sonnet-4-6" in ids
      assert "claude-haiku-4-5-20251001" in ids
      assert "MiniMax-M2" in ids
      assert "gemini-2.5-flash" in ids
    end
  end

  describe "list_providers/0" do
    test "returns unique providers with model counts" do
      providers = ModelRegistry.list_providers()
      assert length(providers) >= 3
      names = Enum.map(providers, & &1.name)
      assert "anthropic" in names
      assert "minimax" in names
      assert "google" in names
    end
  end

  describe "get_model/1" do
    test "returns model by id" do
      model = ModelRegistry.get_model("claude-opus-4-6")
      assert model.provider == "anthropic"
      assert model.context_window == 200_000
    end

    test "returns nil for unknown model" do
      assert ModelRegistry.get_model("nonexistent") == nil
    end
  end

  describe "estimate_cost/3" do
    test "estimates cost for known model" do
      cost = ModelRegistry.estimate_cost("claude-sonnet-4-6", 1_000_000, 500_000)
      assert cost > 0
      # 1M input @ $3/M = $3, 500K output @ $15/M = $7.5 → $10.5
      assert_in_delta cost, 10.5, 0.01
    end

    test "returns 0 for unknown model" do
      assert ModelRegistry.estimate_cost("unknown", 1000, 1000) == 0.0
    end
  end

  describe "circuit_states/0" do
    test "returns a map" do
      states = ModelRegistry.circuit_states()
      assert is_map(states)
    end
  end
end
