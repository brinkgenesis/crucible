defmodule Crucible.MixProject do
  use Mix.Project

  def project do
    [
      app: :crucible,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :underspecs],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ],
      releases: [
        crucible: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent, mnesia: :permanent]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Crucible.Application, []},
      extra_applications: [:logger, :runtime_tools, :mnesia]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Web
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:bandit, "~> 1.5"},
      {:earmark, "~> 1.4"},

      # Database
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},

      # Job queue
      {:oban, "~> 2.18"},

      # Streaming pipeline
      {:gen_stage, "~> 1.2"},

      # OAuth
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},

      # HTTP client (model router, webhooks)
      {:req, "~> 0.5"},
      {:hackney, "~> 1.20"},

      # AWS SDK (secrets management — used when SECRETS_PROVIDER=aws)
      {:ex_aws, "~> 2.5"},
      {:ex_aws_secretsmanager, "~> 2.0"},

      # Parsing
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.12"},
      {:sweet_xml, "~> 0.7"},

      # Prompt templates (Liquid, mirrors Symphony's PromptBuilder)
      {:solid, "~> 1.2"},

      # Config validation (mirrors Symphony's Config)
      {:nimble_options, "~> 1.1"},

      # Telemetry
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},

      # OpenTelemetry
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_bandit, "~> 0.2"},

      # API Documentation
      {:open_api_spex, "~> 3.21"},

      # Structured logging (prod)
      {:logger_json, "~> 6.0"},

      # Error reporting
      {:sentry, "~> 10.0"},

      # Utils
      {:gettext, "~> 1.0"},
      {:dns_cluster, "~> 0.2.0"},

      # Clustering
      {:libcluster, "~> 3.4"},
      {:horde, "~> 0.9"},

      # High-throughput PubSub fan-out (Discord Manifold)
      {:manifold, "~> 1.6"},

      # Filesystem watcher (sentinel file streaming instead of polling)
      {:file_system, "~> 1.0"},

      # Dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind crucible", "esbuild crucible"],
      "assets.deploy": [
        "tailwind crucible --minify",
        "esbuild crucible --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "ci.check": [
        "compile --warnings-as-errors",
        "sobelow --config",
        "dialyzer --halt-exit-status",
        "cmd env MIX_ENV=test mix test"
      ],
      "test.coverage": ["coveralls.html"]
    ]
  end
end
