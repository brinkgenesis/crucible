defmodule Crucible.SecretsTest do
  use ExUnit.Case, async: false

  alias Crucible.Secrets

  setup do
    # Clear persistent_term between tests
    :persistent_term.erase(:infra_secrets_cache)

    on_exit(fn ->
      :persistent_term.erase(:infra_secrets_cache)
    end)

    :ok
  end

  describe "init!/0" do
    test "loads secrets from env provider by default" do
      System.put_env("DATABASE_URL", "ecto://test:test@localhost/test_db")
      on_exit(fn -> System.delete_env("DATABASE_URL") end)

      assert :ok = Secrets.init!()
      assert Secrets.get("DATABASE_URL") == "ecto://test:test@localhost/test_db"
    end

    test "caches secrets in persistent_term" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test-123")
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

      Secrets.init!()

      # Verify persistent_term has the cache
      cache = :persistent_term.get(:infra_secrets_cache)
      assert is_map(cache)
      assert cache["ANTHROPIC_API_KEY"] == "sk-ant-test-123"
    end
  end

  describe "get/1" do
    test "returns cached value after init" do
      System.put_env("GOOGLE_API_KEY", "AIza-test")
      on_exit(fn -> System.delete_env("GOOGLE_API_KEY") end)

      Secrets.init!()
      assert Secrets.get("GOOGLE_API_KEY") == "AIza-test"
    end

    test "returns nil for unset secret" do
      System.delete_env("CLOUDFLARE_API_TOKEN")
      Secrets.init!()
      assert Secrets.get("CLOUDFLARE_API_TOKEN") == nil
    end

    test "falls back to System.get_env when not initialized" do
      :persistent_term.erase(:infra_secrets_cache)
      System.put_env("DATABASE_URL", "ecto://fallback")
      on_exit(fn -> System.delete_env("DATABASE_URL") end)

      assert Secrets.get("DATABASE_URL") == "ecto://fallback"
    end
  end

  describe "get!/1" do
    test "returns value when present" do
      System.put_env("SECRET_KEY_BASE", "test-secret-base-64chars")
      on_exit(fn -> System.delete_env("SECRET_KEY_BASE") end)

      Secrets.init!()
      assert Secrets.get!("SECRET_KEY_BASE") == "test-secret-base-64chars"
    end

    test "raises when secret is missing" do
      System.delete_env("CLOUDFLARE_API_TOKEN")
      Secrets.init!()

      assert_raise RuntimeError, ~r/Secret CLOUDFLARE_API_TOKEN not found/, fn ->
        Secrets.get!("CLOUDFLARE_API_TOKEN")
      end
    end
  end

  describe "secret_keys/0" do
    test "returns list of managed keys" do
      keys = Secrets.secret_keys()
      assert is_list(keys)
      assert "DATABASE_URL" in keys
      assert "SECRET_KEY_BASE" in keys
      assert "ANTHROPIC_API_KEY" in keys
      assert "GOOGLE_OAUTH_CLIENT_ID" in keys
    end
  end

  describe "sensitive_key?/1" do
    test "treats managed secrets as sensitive" do
      assert Secrets.sensitive_key?("DATABASE_URL")
      assert Secrets.sensitive_key?("GOOGLE_OAUTH_CLIENT_SECRET")
    end

    test "treats generic secret-like names as sensitive" do
      assert Secrets.sensitive_key?("CUSTOM_PASSWORD")
      refute Secrets.sensitive_key?("PHX_HOST")
    end
  end

  describe "subprocess_env_overrides/1" do
    test "unsets app secrets for child processes" do
      overrides = Secrets.subprocess_env_overrides()
      assert {~c"DATABASE_URL", false} in overrides
      assert {~c"SECRET_KEY_BASE", false} in overrides
      assert {~c"CLAUDECODE", false} in overrides
    end

    test "keeps explicitly allowed auth vars" do
      overrides = Secrets.subprocess_env_overrides(keep: Secrets.claude_auth_keys())
      refute {~c"ANTHROPIC_API_KEY", false} in overrides
    end
  end

  describe "provider_module/0" do
    test "defaults to EnvProvider" do
      System.delete_env("SECRETS_PROVIDER")
      assert Secrets.provider_module() == Crucible.Secrets.EnvProvider
    end

    test "returns AwsProvider when configured" do
      System.put_env("SECRETS_PROVIDER", "aws")
      on_exit(fn -> System.delete_env("SECRETS_PROVIDER") end)

      assert Secrets.provider_module() == Crucible.Secrets.AwsProvider
    end
  end
end
