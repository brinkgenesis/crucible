defmodule Crucible.Cluster.Topology do
  @moduledoc """
  Cluster topology configuration for libcluster.

  Reads the clustering strategy from application config (set via env vars
  in runtime.exs) and returns the appropriate libcluster topology spec.

  Supported strategies:
  - :gossip  — Cluster.Strategy.Gossip (development/local, default)
  - :dns     — Cluster.Strategy.DNSPoll (production)
  - :k8s     — Cluster.Strategy.Kubernetes.DNS (Kubernetes)
  """

  @doc """
  Returns the child spec for the libcluster Cluster.Supervisor
  configured with the active topology.
  """
  def child_spec(_opts) do
    topologies = build_topologies()

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [topologies]},
      type: :supervisor
    }
  end

  def start_link(topologies) do
    Cluster.Supervisor.start_link(topologies)
  rescue
    e ->
      require Logger

      Logger.warning(
        "Cluster.Topology: libcluster failed to start: #{inspect(e)}, running single-node"
      )

      :ignore
  end

  @doc """
  Builds the topology configuration list based on application config.
  """
  def build_topologies do
    strategy = Application.get_env(:crucible, :cluster_strategy, :gossip)
    topology_config(strategy)
  end

  defp topology_config(:gossip) do
    secret =
      Application.get_env(:crucible, :cluster_gossip_secret) ||
        raise """
        CLUSTER_GOSSIP_SECRET must be set for gossip clustering.
        Generate one with: mix phx.gen.secret
        """

    [
      crucible: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: Application.get_env(:crucible, :cluster_gossip_port, 45892),
          if_addr: {0, 0, 0, 0},
          multicast_if: {0, 0, 0, 0},
          multicast_addr: {230, 1, 1, 251},
          secret: secret
        ]
      ]
    ]
  end

  defp topology_config(:dns) do
    query = Application.get_env(:crucible, :cluster_dns_query, "")
    poll_interval = Application.get_env(:crucible, :cluster_dns_poll_interval, 5_000)

    node_basename =
      Application.get_env(:crucible, :cluster_node_basename, "crucible")

    [
      crucible: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: poll_interval,
          query: query,
          node_basename: node_basename
        ]
      ]
    ]
  end

  defp topology_config(:k8s) do
    namespace = Application.get_env(:crucible, :cluster_k8s_namespace, "default")
    service = Application.get_env(:crucible, :cluster_k8s_service, "infra-orchestrator")

    app_name =
      Application.get_env(:crucible, :cluster_k8s_app_name, "infra-orchestrator")

    [
      crucible: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: service,
          application_name: app_name,
          namespace: namespace,
          polling_interval: 5_000
        ]
      ]
    ]
  end

  defp topology_config(unknown) do
    require Logger
    Logger.warning("Unknown cluster strategy #{inspect(unknown)}, falling back to gossip")
    topology_config(:gossip)
  end
end
