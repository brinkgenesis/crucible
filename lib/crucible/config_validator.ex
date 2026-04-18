defmodule Crucible.ConfigValidator do
  @moduledoc """
  Validates required environment variables and configuration at startup.
  Called at the top of Application.start/2 in prod to fail fast on misconfiguration.
  """

  require Logger

  @doc """
  Validates prod-required config. Raises on missing required vars.
  Logs warnings for missing optional vars.
  """
  @spec validate!() :: :ok
  def validate! do
    if Application.get_env(:crucible, :config_env, :dev) == :prod do
      validate_required!()
      validate_repo_config!()
      validate_rate_limits!()
      validate_alerting!()
      validate_cluster!()
      validate_optional()
    end

    :ok
  end

  defp validate_required! do
    missing =
      ~w(DATABASE_URL SECRET_KEY_BASE)
      |> Enum.reject(&System.get_env/1)

    unless missing == [] do
      raise """
      Missing required environment variables: #{Enum.join(missing, ", ")}
      These must be set before starting in production.
      """
    end

    validate_database_url!()
  end

  defp validate_database_url! do
    url = System.get_env("DATABASE_URL", "")

    unless String.starts_with?(url, "ecto://") or String.starts_with?(url, "postgresql://") do
      raise "DATABASE_URL must begin with ecto:// or postgresql://"
    end
  end

  defp validate_repo_config! do
    repo_config = Application.get_env(:crucible, Crucible.Repo, [])

    integer_keys = [:pool_size, :pool_count, :checkout_timeout, :queue_target, :queue_interval]

    errors =
      integer_keys
      |> Enum.map(&validate_positive_integer(repo_config, &1))
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, msg} -> msg end)

    unless errors == [] do
      raise "Repo configuration errors:\n" <> Enum.join(errors, "\n")
    end
  end

  defp validate_rate_limits! do
    rate_config = Application.get_env(:crucible, :rate_limits, [])

    integer_keys = [:ip_read_limit, :ip_write_limit, :tenant_read_limit, :tenant_write_limit]

    errors =
      integer_keys
      |> Enum.map(&validate_positive_integer(rate_config, &1))
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, msg} -> msg end)

    unless errors == [] do
      raise "Rate limit configuration errors:\n" <> Enum.join(errors, "\n")
    end
  end

  defp validate_alerting! do
    alert_config = Application.get_env(:crucible, :alerting, [])

    integer_keys = [:cooldown_ms, :budget_warning_pct, :failure_rate_threshold_pct]

    errors =
      integer_keys
      |> Enum.map(&validate_positive_integer(alert_config, &1))
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, msg} -> msg end)

    unless errors == [] do
      raise "Alerting configuration errors:\n" <> Enum.join(errors, "\n")
    end
  end

  defp validate_cluster! do
    strategy = Application.get_env(:crucible, :cluster_strategy, :gossip)

    case strategy do
      :dns ->
        unless System.get_env("CLUSTER_DNS_QUERY") do
          raise "CLUSTER_DNS_QUERY is required when CLUSTER_STRATEGY=dns"
        end

        cluster_config = [
          cluster_dns_poll_interval:
            Application.get_env(:crucible, :cluster_dns_poll_interval)
        ]

        case validate_positive_integer(cluster_config, :cluster_dns_poll_interval) do
          {:error, msg} -> raise msg
          :ok -> :ok
        end

      :k8s ->
        unless System.get_env("CLUSTER_K8S_SERVICE") do
          raise "CLUSTER_K8S_SERVICE is required when CLUSTER_STRATEGY=k8s"
        end

      :gossip ->
        unless Application.get_env(:crucible, :cluster_gossip_secret) do
          Logger.warning(
            "ConfigValidator: CLUSTER_GOSSIP_SECRET not set, cluster will not form securely"
          )
        end

        cluster_config = [
          cluster_gossip_port: Application.get_env(:crucible, :cluster_gossip_port)
        ]

        case validate_positive_integer(cluster_config, :cluster_gossip_port) do
          {:error, msg} -> raise msg
          :ok -> :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_optional do
    optional = [
      {"PHX_HOST", "endpoint will use default host"},
      {"MNESIA_DIR", "Mnesia will use default directory"}
    ]

    for {var, hint} <- optional do
      unless System.get_env(var) do
        Logger.info("ConfigValidator: #{var} not set — #{hint}")
      end
    end
  end

  # Type validation helpers

  @doc false
  @spec validate_positive_integer(keyword(), atom()) :: :ok | {:error, String.t()}
  def validate_positive_integer(config, key) do
    case Keyword.get(config, key) do
      nil ->
        # presence check handled elsewhere; nil means not configured (use default)
        :ok

      v when is_integer(v) and v > 0 ->
        :ok

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> :ok
          _ -> {:error, "#{key} must be a positive integer, got invalid value"}
        end

      _ ->
        {:error, "#{key} must be a positive integer"}
    end
  end
end
