defmodule Crucible.Secrets.AwsProvider do
  @moduledoc """
  AWS Secrets Manager provider — fetches secrets from a single JSON blob secret.

  The secret name is read from the `AWS_SECRET_NAME` env var (e.g. "infra-orchestrator/prod").
  The secret value must be a JSON object where keys match the expected secret names.

  AWS region is read from `AWS_REGION` (default: "us-east-1").
  Authentication uses IAM role credentials (ECS task role, EKS service account, etc.)
  or standard AWS credential chain (env vars, ~/.aws/credentials) for local testing.

  ## Configuration

      SECRETS_PROVIDER=aws
      AWS_REGION=us-east-1
      AWS_SECRET_NAME=infra-orchestrator/prod
  """
  @behaviour Crucible.Secrets.Provider

  require Logger

  @impl true
  def fetch_all(keys) when is_list(keys) do
    secret_name =
      System.get_env("AWS_SECRET_NAME") ||
        raise "AWS_SECRET_NAME env var required when SECRETS_PROVIDER=aws"

    region = System.get_env("AWS_REGION", "us-east-1")

    case fetch_secret(secret_name, region) do
      {:ok, json_string} ->
        case Jason.decode(json_string) do
          {:ok, secret_map} when is_map(secret_map) ->
            # Only return keys we asked for, convert values to strings
            result =
              Map.new(keys, fn key ->
                value =
                  case Map.get(secret_map, key) do
                    nil -> nil
                    v when is_binary(v) -> v
                    v -> to_string(v)
                  end

                {key, value}
              end)

            {:ok, result}

          {:ok, _} ->
            {:error, :secret_not_json_object}

          {:error, decode_error} ->
            {:error, {:json_decode_failed, decode_error}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_secret(secret_name, region) do
    request =
      ExAws.SecretsManager.get_secret_value(secret_name)
      |> ExAws.request(region: region)

    case request do
      {:ok, %{"SecretString" => secret_string}} ->
        {:ok, secret_string}

      {:ok, response} ->
        Logger.warning("AwsProvider: unexpected response format: #{inspect(response)}")
        {:error, {:unexpected_response, response}}

      {:error, {:http_error, status, body}} ->
        Logger.error("AwsProvider: HTTP #{status} fetching #{secret_name}: #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("AwsProvider: failed to fetch #{secret_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
