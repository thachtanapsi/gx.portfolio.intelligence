import Config

config :gx_portfolio_intelligence, GxPortfolioIntelligence.Repo,
  username: System.get_env("GX_PI_DB_USER", "postgres"),
  password: System.get_env("GX_PI_DB_PASSWORD", "postgres"),
  hostname: System.get_env("GX_PI_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("GX_PI_DB_PORT", "5432")),
  database: System.get_env("GX_PI_DB_NAME", "gx_portfolio_intelligence_dev"),
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :gx_portfolio_intelligence, GxPortfolioIntelligenceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4010],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "local-development-secret-key-base-at-least-sixty-four-bytes-long-00001",
  watchers: []

config :gx_portfolio_intelligence, Oban,
  repo: GxPortfolioIntelligence.Repo,
  queues: [
    control: 1,
    collectors: 1,
    research: 4,
    trend: 1,
    full_analysis: 2,
    rag: 2,
    maintenance: 1
  ],
  plugins: [Oban.Plugins.Pruner]

config :gx_portfolio_intelligence,
  auth_token: System.get_env("GX_PI_API_TOKEN"),
  webhook_url: System.get_env("GX_PI_WEBHOOK_URL"),
  webhook_token: System.get_env("GX_PI_WEBHOOK_TOKEN"),
  rag_claim_lease_seconds: String.to_integer(System.get_env("RAG_CLAIM_LEASE_SECONDS", "120")),
  trend_enabled: System.get_env("GX_PI_TREND_ENABLED", "false") in ["1", "true", "TRUE"],
  full_analysis_enabled:
    System.get_env("GX_PI_FULL_ANALYSIS_ENABLED", "false") in ["1", "true", "TRUE"],
  full_analysis_limit: String.to_integer(System.get_env("GX_PI_FULL_ANALYSIS_LIMIT", "5")),
  full_analysis_backlog_warning_threshold:
    String.to_integer(System.get_env("GX_PI_FULL_ANALYSIS_BACKLOG_WARNING_THRESHOLD", "20")),
  full_analysis_pinned_tickers:
    System.get_env("GX_PI_FULL_ANALYSIS_PINNED_TICKERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq(),
  full_stage_claim_lease_seconds:
    String.to_integer(System.get_env("FULL_STAGE_CLAIM_LEASE_SECONDS", "2100")),
  port_runner: [
    executable: System.get_env("TRADING_AGENTS_PYTHON"),
    project_root: System.get_env("TRADING_AGENTS_ROOT"),
    artifact_root: System.get_env("GX_PI_ARTIFACT_ROOT"),
    argv_prefix: ["-m", "cli.gx_main"],
    timeout_ms: String.to_integer(System.get_env("TRADING_AGENTS_TIMEOUT_MS", "900000")),
    full_stage_timeout_ms:
      String.to_integer(System.get_env("TRADING_AGENTS_FULL_STAGE_TIMEOUT_MS", "1800000")),
    max_output_bytes:
      String.to_integer(System.get_env("TRADING_AGENTS_MAX_OUTPUT_BYTES", "2000000"))
  ],
  rag: [
    base_url: System.get_env("RAG_SERVICE_URL", "http://127.0.0.1:8000"),
    api_key: System.get_env("RAG_SERVICE_API_KEY"),
    timeout_ms: String.to_integer(System.get_env("RAG_TIMEOUT_MS", "60000"))
  ]

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
