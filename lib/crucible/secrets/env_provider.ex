defmodule Crucible.Secrets.EnvProvider do
  @moduledoc """
  Default secrets provider — reads from environment variables.

  This is a pass-through to `System.get_env/1`. Used in development and
  any environment where secrets are injected as env vars (Docker, K8s secretRef, etc.).
  """
  @behaviour Crucible.Secrets.Provider

  @impl true
  def fetch_all(keys) when is_list(keys) do
    secrets = Map.new(keys, fn key -> {key, System.get_env(key)} end)
    {:ok, secrets}
  end
end
