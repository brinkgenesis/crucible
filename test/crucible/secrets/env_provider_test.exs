defmodule Crucible.Secrets.EnvProviderTest do
  use ExUnit.Case, async: true

  alias Crucible.Secrets.EnvProvider

  describe "fetch_all/1" do
    test "returns env var values for requested keys" do
      System.put_env("TEST_SECRET_A", "value_a")
      System.put_env("TEST_SECRET_B", "value_b")

      on_exit(fn ->
        System.delete_env("TEST_SECRET_A")
        System.delete_env("TEST_SECRET_B")
      end)

      assert {:ok, secrets} = EnvProvider.fetch_all(["TEST_SECRET_A", "TEST_SECRET_B"])
      assert secrets["TEST_SECRET_A"] == "value_a"
      assert secrets["TEST_SECRET_B"] == "value_b"
    end

    test "returns nil for unset env vars" do
      System.delete_env("TEST_NONEXISTENT_SECRET")

      assert {:ok, secrets} = EnvProvider.fetch_all(["TEST_NONEXISTENT_SECRET"])
      assert secrets["TEST_NONEXISTENT_SECRET"] == nil
    end

    test "returns empty map for empty key list" do
      assert {:ok, secrets} = EnvProvider.fetch_all([])
      assert secrets == %{}
    end

    test "only returns requested keys" do
      System.put_env("TEST_INCLUDED", "yes")
      System.put_env("TEST_EXCLUDED", "no")

      on_exit(fn ->
        System.delete_env("TEST_INCLUDED")
        System.delete_env("TEST_EXCLUDED")
      end)

      assert {:ok, secrets} = EnvProvider.fetch_all(["TEST_INCLUDED"])
      assert Map.has_key?(secrets, "TEST_INCLUDED")
      refute Map.has_key?(secrets, "TEST_EXCLUDED")
    end
  end
end
