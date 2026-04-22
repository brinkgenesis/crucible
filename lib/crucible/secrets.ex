defmodule Crucible.Secrets do
  @moduledoc """
  Secrets provider facade.

  Call `init!/0` once at the top of `config/runtime.exs` to bootstrap secrets
  from the configured provider. Then use `get/1` anywhere to read cached values.

  ## Providers

  - `"env"` (default) — reads from `System.get_env/1`. Zero behavior change for dev.
  - `"aws"` — reads from AWS Secrets Manager (single JSON blob secret).

  Set `SECRETS_PROVIDER` env var to select. Bootstrap vars (`SECRETS_PROVIDER`,
  `AWS_REGION`, `AWS_SECRET_NAME`) always come from env — they are not stored
  in Secrets Manager.

  ## Usage

      # In config/runtime.exs (called once at startup):
      Crucible.Secrets.init!()

      # Anywhere in application code:
      Crucible.Secrets.get("DATABASE_URL")
      Crucible.Secrets.get!("SECRET_KEY_BASE")
  """

  require Logger

  @persistent_term_key :infra_secrets_cache
  @status_key :infra_secrets_status

  @secret_keys ~w(
    DATABASE_URL
    SECRET_KEY_BASE
    INFRA_API_KEY
    ANTHROPIC_API_KEY
    GOOGLE_API_KEY
    MINIMAX_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    TOGETHER_API_KEY
    GOOGLE_OAUTH_CLIENT_ID
    GOOGLE_OAUTH_CLIENT_SECRET
    GITHUB_TOKEN
    ALERT_WEBHOOK_URL
    CLOUDFLARE_API_TOKEN
    CLUSTER_GOSSIP_SECRET
  )

  @doc """
  Initialize the secrets cache from the configured provider.

  Must be called once at startup (typically from `config/runtime.exs`).
  Raises on failure — secrets are required for the application to start.

  Emits structured log events so ops engineers can diagnose hangs or
  credential failures without attaching a debugger.
  """
  @spec init!() :: :ok
  def init! do
    provider = provider_module()
    provider_name = provider_label(provider)

    Logger.info("[Crucible.Secrets] Initializing secrets", provider: provider_name)

    case provider.fetch_all(@secret_keys) do
      {:ok, secrets} when is_map(secrets) ->
        loaded_count = map_size(secrets)
        initialized_at = DateTime.utc_now()

        :persistent_term.put(@persistent_term_key, secrets)

        # Mirror resolved secrets back into the process env so call sites
        # that still read `System.get_env/1` (SDK adapters, scripts) work
        # regardless of provider. No-op for EnvProvider (same source).
        export_to_system_env(secrets)

        :persistent_term.put(@status_key, %{
          provider: provider_name,
          secret_count: loaded_count,
          initialized_at: initialized_at
        })

        Logger.info("[Crucible.Secrets] Secrets loaded successfully",
          provider: provider_name,
          secret_count: loaded_count,
          initialized_at: DateTime.to_iso8601(initialized_at)
        )

        :ok

      {:error, reason} ->
        missing = extract_missing_keys(reason)

        Logger.error("[Crucible.Secrets] Failed to load secrets",
          provider: provider_name,
          reason: inspect(reason),
          missing_keys: missing
        )

        raise "Secrets init failed via provider=#{provider_name}: #{inspect(reason)}"
    end
  end

  @doc """
  Returns operational status of the secrets subsystem.

  Returns `%{provider: atom, secret_count: non_neg_integer, initialized_at: DateTime.t() | nil}`.
  If `init!/0` has not yet been called, `initialized_at` is `nil` and `secret_count` is 0.
  """
  @spec status() :: %{
          provider: atom,
          secret_count: non_neg_integer(),
          initialized_at: DateTime.t() | nil
        }
  def status do
    case :persistent_term.get(@status_key, nil) do
      nil ->
        provider_name = provider_label(provider_module())
        %{provider: provider_name, secret_count: 0, initialized_at: nil}

      status ->
        status
    end
  end

  # Convert a provider module to a short label atom for log/status fields.
  defp provider_label(Crucible.Secrets.AwsProvider), do: :aws
  defp provider_label(_), do: :env

  defp export_to_system_env(secrets) do
    Enum.each(secrets, fn
      {key, value} when is_binary(key) and is_binary(value) and value != "" ->
        System.put_env(key, value)

      _ ->
        :ok
    end)
  end

  # Best-effort extraction of missing key names from provider error terms.
  defp extract_missing_keys({:missing_keys, keys}) when is_list(keys), do: keys
  defp extract_missing_keys(_), do: []

  @doc "Retrieve a secret by key. Returns `nil` if not found."
  @spec get(String.t()) :: String.t() | nil
  def get(key) when is_binary(key) do
    case :persistent_term.get(@persistent_term_key, :not_initialized) do
      :not_initialized -> System.get_env(key)
      secrets -> Map.get(secrets, key)
    end
  end

  @doc "Retrieve a secret by key. Raises if not found."
  @spec get!(String.t()) :: String.t()
  def get!(key) when is_binary(key) do
    case get(key) do
      nil -> raise "Secret #{key} not found"
      value -> value
    end
  end

  @doc "Returns the list of secret keys managed by this module."
  @spec secret_keys() :: [String.t()]
  def secret_keys, do: @secret_keys

  @doc false
  def provider_module do
    case System.get_env("SECRETS_PROVIDER", "env") do
      "aws" -> Crucible.Secrets.AwsProvider
      _env -> Crucible.Secrets.EnvProvider
    end
  end
end
