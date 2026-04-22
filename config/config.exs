# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :crucible,
  ecto_repos: [Crucible.Repo],
  generators: [timestamp_type: :utc_datetime]

# Manifold PubSub fan-out — when enabled, PubSub broadcasts use Discord's Manifold
# for parallel message delivery across BEAM schedulers. Disable to use standard PG2.
config :crucible, :manifold_pubsub, enabled: false

# Orchestrator configuration — runs_dir path lives under repo_root.
# Dev default: sibling of the config dir. Prod/container: set via CRUCIBLE_REPO_ROOT env in runtime.exs.
config :crucible, :orchestrator, repo_root: Path.expand("..", __DIR__)

# Configure the endpoint
config :crucible, CrucibleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CrucibleWeb.ErrorHTML, json: CrucibleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Crucible.PubSub,
  live_view: [signing_salt: "kQKZDsDZ"]

# Configure Ueberauth (Google OAuth)
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "openid email profile"]}
  ]

# Configure Oban job queue
config :crucible, Oban,
  repo: Crucible.Repo,
  queues: [default: 10, patrol: 1],
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Crucible.SessionCleaner},
       {"3 3 * * *", Crucible.Jobs.BackupJob},
       {"0 4 * * 0", Crucible.Jobs.BackupVerifyJob},
       {"0 2 * * *", Crucible.Jobs.LogRotationJob},
       {"30 */6 * * *", Crucible.Jobs.StaleCardArchiver},
       {"17 */3 * * *", Crucible.Jobs.InboxScanJob},
       {"45 * * * *", Crucible.Jobs.CiLogAnalyzerJob},
       {"*/30 * * * *", Crucible.Jobs.RssIngestJob},
       {"7 */2 * * *", Crucible.Jobs.GithubIngestJob}
     ]}
  ]

# Sentry error reporting (DSN set at runtime via SENTRY_DSN env var)
config :sentry,
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  tags: %{app: "infra-orchestrator"}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  crucible: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  crucible: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# OpenTelemetry — base configuration
config :opentelemetry,
  resource: [service: [name: "infra-orchestrator", version: "0.1.0"]],
  span_processor: :batch,
  traces_exporter: :otlp

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
