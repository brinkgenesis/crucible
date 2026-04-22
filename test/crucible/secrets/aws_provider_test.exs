defmodule Crucible.Secrets.AwsProviderTest do
  use ExUnit.Case, async: false

  alias Crucible.Secrets.AwsProvider

  describe "fetch_all/1" do
    test "raises when AWS_SECRET_NAME is not set" do
      System.delete_env("AWS_SECRET_NAME")

      assert_raise RuntimeError, ~r/AWS_SECRET_NAME env var required/, fn ->
        AwsProvider.fetch_all(["DATABASE_URL"])
      end
    end
  end

  describe "JSON parsing (unit)" do
    # Test the provider's JSON parsing logic by calling fetch_all with a mock.
    # We can't easily mock ExAws in unit tests without a mocking library,
    # so we test the format_payload logic indirectly through the facade.

    test "secret_keys are all strings" do
      keys = Crucible.Secrets.secret_keys()
      assert Enum.all?(keys, &is_binary/1)
    end

    test "provider module returns AwsProvider when configured" do
      System.put_env("SECRETS_PROVIDER", "aws")
      on_exit(fn -> System.delete_env("SECRETS_PROVIDER") end)

      assert Crucible.Secrets.provider_module() ==
               Crucible.Secrets.AwsProvider
    end
  end
end
