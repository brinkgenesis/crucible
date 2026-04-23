defmodule Crucible.Sandbox.PolicyTest do
  use ExUnit.Case, async: true

  alias Crucible.Sandbox.Policy

  test "validate/1 accepts policies without a network allowlist" do
    assert :ok =
             Policy.from_preset(:standard) |> Map.put(:allowed_endpoints, []) |> Policy.validate()
  end

  test "validate/1 rejects unsupported network allowlists" do
    policy =
      Policy.from_preset(:permissive) |> Map.put(:allowed_endpoints, ["api.example.com:443"])

    assert {:error, {:network_allowlist_not_supported, ["api.example.com:443"]}} =
             Policy.validate(policy)
  end
end
