import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :crucible, Crucible.Repo,
  url:
    "postgres://infra:infra@localhost/crucible_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :crucible, CrucibleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ZVQAc+1WAHznwsyOQB395nG2Lac0VGvWLCOhslVQgjxzVuZZa3lPPYp+ZJVRxiV/",
  server: false

# Isolate test artifacts from real run data.
# Without this, ResultWriter + Orchestrator write to the real .claude-flow/runs/
# directory, polluting it with thousands of test-run-*, bottleneck-*, etc. files
# that cause API timeouts and postgres connection exhaustion.
config :crucible, :orchestrator,
  disabled: true,
  repo_root: Path.join(System.tmp_dir!(), "infra-orchestrator-test"),
  runs_dir: ".claude-flow/runs"

# Disable Oban in tests
config :crucible, Oban, testing: :inline

# Set a fixed API key so auth is always active in tests.
# Tests use authenticate() to send the matching Bearer token.
# This avoids global state races when with_auth_required() was used.
config :crucible, api_key: "test-api-key-fixed"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Disable OTel tracing in tests
config :opentelemetry, traces_exporter: :none

# Sandbox off in tests — Docker-dependent cases opt in via @tag :docker.
config :crucible, :feature_flags, sandbox_enabled: false
