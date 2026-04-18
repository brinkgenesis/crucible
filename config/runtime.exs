import Config

# Bootstrap secrets provider (env vars by default, AWS Secrets Manager via SECRETS_PROVIDER=aws)
Crucible.Secrets.init!()

# -- Feature flags (env-var overrides for runtime-tunable defaults) --
# SANDBOX_ENABLED: "true" (default) enables sandbox code path; set "false" to disable.
# Independent from SANDBOX_MODE (local|docker) — both must align for real container isolation.
# Skipped in :test — config/test.exs pins the value explicitly.
if config_env() != :test do
  config :crucible, :feature_flags,
    sandbox_enabled: System.get_env("SANDBOX_ENABLED", "true") != "false"
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/crucible start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :crucible, CrucibleWeb.Endpoint, server: true
end

port =
  case Integer.parse(System.get_env("PORT", "4801")) do
    {n, ""} when n > 0 -> n
    _ -> 4801
  end

config :crucible, CrucibleWeb.Endpoint, http: [port: port]

# -- Dashboard auth --
config :crucible, :dashboard_auth, System.get_env("DASHBOARD_AUTH", "false") == "true"

# -- Google OAuth --
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: Crucible.Secrets.get("GOOGLE_OAUTH_CLIENT_ID"),
  client_secret: Crucible.Secrets.get("GOOGLE_OAUTH_CLIENT_SECRET")

config :crucible, :oauth,
  allowed_domain: System.get_env("OAUTH_ALLOWED_DOMAIN")

# -- CORS origins --
if cors_origins = System.get_env("CORS_ALLOWED_ORIGINS") do
  config :crucible, :cors_origins, cors_origins
end

# -- Rate limiting --
ip_read_limit =
  case Integer.parse(System.get_env("RATE_LIMIT_IP_READ", "120")) do
    {n, ""} when n > 0 -> n
    _ -> 120
  end

ip_write_limit =
  case Integer.parse(System.get_env("RATE_LIMIT_IP_WRITE", "20")) do
    {n, ""} when n > 0 -> n
    _ -> 20
  end

tenant_read_limit =
  case Integer.parse(System.get_env("RATE_LIMIT_TENANT_READ", "300")) do
    {n, ""} when n > 0 -> n
    _ -> 300
  end

tenant_write_limit =
  case Integer.parse(System.get_env("RATE_LIMIT_TENANT_WRITE", "60")) do
    {n, ""} when n > 0 -> n
    _ -> 60
  end

config :crucible, :rate_limits,
  ip_read_limit: ip_read_limit,
  ip_write_limit: ip_write_limit,
  tenant_read_limit: tenant_read_limit,
  tenant_write_limit: tenant_write_limit

# -- Alerting --
alert_cooldown_ms =
  case Integer.parse(System.get_env("ALERT_COOLDOWN_MS", "300000")) do
    {n, ""} when n > 0 -> n
    _ -> 300_000
  end

alert_budget_warning_pct =
  case Integer.parse(System.get_env("ALERT_BUDGET_WARNING_PCT", "80")) do
    {n, ""} when n > 0 -> n
    _ -> 80
  end

alert_failure_rate_pct =
  case Integer.parse(System.get_env("ALERT_FAILURE_RATE_PCT", "25")) do
    {n, ""} when n > 0 -> n
    _ -> 25
  end

config :crucible, :alerting,
  enabled: System.get_env("ALERTING_ENABLED", "false") == "true",
  webhook_url: Crucible.Secrets.get("ALERT_WEBHOOK_URL"),
  webhook_token: System.get_env("ALERTMANAGER_WEBHOOK_TOKEN"),
  webhook_format:
    (case System.get_env("ALERT_WEBHOOK_FORMAT", "generic") do
       "generic" ->
         :generic

       "slack" ->
         :slack

       "pagerduty" ->
         :pagerduty

       "teams" ->
         :teams

       other ->
         raise "Invalid ALERT_WEBHOOK_FORMAT: #{other}. Must be generic, slack, pagerduty, or teams."
     end),
  cooldown_ms: alert_cooldown_ms,
  budget_warning_pct: alert_budget_warning_pct,
  failure_rate_threshold_pct: alert_failure_rate_pct

# -- Sandbox isolation (API workflows) --
sandbox_mode =
  case System.get_env("SANDBOX_MODE", "local") do
    "docker" -> :docker
    _ -> :local
  end

sandbox_pool_size =
  case Integer.parse(System.get_env("SANDBOX_POOL_SIZE", "3")) do
    {n, ""} when n > 0 -> n
    _ -> 3
  end

config :crucible, :sandbox,
  mode: sandbox_mode,
  pool_size: sandbox_pool_size,
  image: System.get_env("SANDBOX_IMAGE", "node:22-alpine"),
  policy_preset:
    (case System.get_env("SANDBOX_POLICY", "standard") do
       "strict" -> :strict
       "permissive" -> :permissive
       _ -> :standard
     end),
  router_host: System.get_env("SANDBOX_ROUTER_HOST", "host.docker.internal:4800"),
  network_allowlist: System.get_env("SANDBOX_NETWORK_ALLOWLIST")

# -- Distributed RPC --
distributed_rpc_timeout_ms =
  case Integer.parse(System.get_env("DISTRIBUTED_RPC_TIMEOUT_MS", "3000")) do
    {n, ""} when n > 0 -> n
    _ -> 3000
  end

config :crucible, :distributed_rpc_timeout_ms, distributed_rpc_timeout_ms

# -- Cluster configuration --
# CLUSTER_STRATEGY: "gossip" (default/dev), "dns" (production), "k8s" (Kubernetes)
cluster_strategy =
  case System.get_env("CLUSTER_STRATEGY", "gossip") do
    "dns" -> :dns
    "k8s" -> :k8s
    _ -> :gossip
  end

config :crucible, cluster_strategy: cluster_strategy

# DNS strategy options
if cluster_strategy == :dns do
  cluster_dns_poll_interval =
    case Integer.parse(System.get_env("CLUSTER_DNS_POLL_INTERVAL", "5000")) do
      {n, ""} when n > 0 -> n
      _ -> 5000
    end

  config :crucible,
    cluster_dns_query: System.get_env("CLUSTER_DNS_QUERY", ""),
    cluster_dns_poll_interval: cluster_dns_poll_interval,
    cluster_node_basename: System.get_env("CLUSTER_NODE_BASENAME", "crucible")
end

# Gossip strategy options
if cluster_strategy == :gossip do
  cluster_gossip_port =
    case Integer.parse(System.get_env("CLUSTER_GOSSIP_PORT", "45892")) do
      {n, ""} when n > 0 -> n
      _ -> 45892
    end

  config :crucible,
    cluster_gossip_secret: Crucible.Secrets.get("CLUSTER_GOSSIP_SECRET"),
    cluster_gossip_port: cluster_gossip_port
end

# Kubernetes strategy options
if cluster_strategy == :k8s do
  config :crucible,
    cluster_k8s_namespace: System.get_env("CLUSTER_K8S_NAMESPACE", "default"),
    cluster_k8s_service: System.get_env("CLUSTER_K8S_SERVICE", "infra-orchestrator"),
    cluster_k8s_app_name: System.get_env("CLUSTER_K8S_APP_NAME", "infra-orchestrator")
end

# -- Backups --
backup_dir = System.get_env("BACKUP_DIR")
vault_path = System.get_env("VAULT_PATH")
backup_retention = String.to_integer(System.get_env("BACKUP_RETENTION_DAYS", "7"))

if backup_dir || vault_path do
  backup_config =
    []
    |> then(fn c -> if backup_dir, do: Keyword.put(c, :dir, backup_dir), else: c end)
    |> then(fn c -> if vault_path, do: Keyword.put(c, :vault_path, vault_path), else: c end)
    |> Keyword.put(:retention_days, backup_retention)

  config :crucible, :backup, backup_config
end

# -- Sentry --
sentry_dsn = System.get_env("SENTRY_DSN")

if sentry_dsn do
  config :sentry, dsn: sentry_dsn
end

# -- OpenTelemetry --
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: otel_endpoint

if config_env() == :prod do
  config :crucible, config_env: :prod

  database_url =
    Crucible.Secrets.get("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  pool_size =
    case Integer.parse(System.get_env("POOL_SIZE", "10")) do
      {n, ""} when n > 0 -> n
      _ -> 10
    end

  pool_count =
    case Integer.parse(System.get_env("POOL_COUNT", "1")) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end

  db_checkout_timeout =
    case Integer.parse(System.get_env("DB_CHECKOUT_TIMEOUT", "15000")) do
      {n, ""} when n > 0 -> n
      _ -> 15_000
    end

  db_queue_target =
    case Integer.parse(System.get_env("DB_QUEUE_TARGET", "50")) do
      {n, ""} when n > 0 -> n
      _ -> 50
    end

  db_queue_interval =
    case Integer.parse(System.get_env("DB_QUEUE_INTERVAL", "1000")) do
      {n, ""} when n > 0 -> n
      _ -> 1000
    end

  config :crucible, Crucible.Repo,
    # ssl: true,
    url: database_url,
    pool_size: pool_size,
    pool_count: pool_count,
    timeout: 10_000,
    checkout_timeout: db_checkout_timeout,
    queue_target: db_queue_target,
    queue_interval: db_queue_interval,
    backoff_type: :rand_exp,
    backoff_min: 200,
    backoff_max: 15_000,
    disconnect_on_error_codes: [:admin_shutdown],
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    Crucible.Secrets.get("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :crucible, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :crucible, CrucibleWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base,
    # Allow 30s for in-flight requests to complete during shutdown
    drainer: [
      shutdown: 30_000
    ]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :crucible, CrucibleWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :crucible, CrucibleWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :crucible, Crucible.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
