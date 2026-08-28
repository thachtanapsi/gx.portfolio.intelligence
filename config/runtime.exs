import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required, for example ecto://USER:PASS@HOST/gx_portfolio_intelligence"

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is required"

  api_token = System.get_env("GX_PI_API_TOKEN") || raise "GX_PI_API_TOKEN is required"
  rag_key = System.get_env("RAG_SERVICE_API_KEY") || raise "RAG_SERVICE_API_KEY is required"

  artifact_root =
    System.get_env("GX_PI_ARTIFACT_ROOT") || raise "GX_PI_ARTIFACT_ROOT is required"

  trading_root =
    System.get_env("TRADING_AGENTS_ROOT") || raise "TRADING_AGENTS_ROOT is required"

  python = System.get_env("TRADING_AGENTS_PYTHON") || raise "TRADING_AGENTS_PYTHON is required"

  cron_enabled = System.get_env("GX_PI_CRON_ENABLED", "false") in ["1", "true", "TRUE"]
  trend_enabled = System.get_env("GX_PI_TREND_ENABLED", "false") in ["1", "true", "TRUE"]

  full_analysis_enabled =
    System.get_env("GX_PI_FULL_ANALYSIS_ENABLED", "false") in ["1", "true", "TRUE"]

  full_analysis_pinned_tickers =
    System.get_env("GX_PI_FULL_ANALYSIS_PINNED_TICKERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()

  cron_entries = GxPortfolioIntelligence.ObanConfig.cron_entries()

  plugins =
    [Oban.Plugins.Pruner] ++
      if(cron_enabled,
        do: [{Oban.Plugins.Cron, timezone: "Asia/Ho_Chi_Minh", crontab: cron_entries}],
        else: []
      )

  config :gx_portfolio_intelligence, GxPortfolioIntelligence.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "15")),
    socket_options: if(System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: [])

  config :gx_portfolio_intelligence, GxPortfolioIntelligenceWeb.Endpoint,
    server: true,
    url: [host: System.get_env("PHX_HOST", "localhost"), port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4010"))],
    secret_key_base: secret_key_base

  config :gx_portfolio_intelligence,
    auth_token: api_token,
    cron_enabled: cron_enabled,
    webhook_url: System.get_env("GX_PI_WEBHOOK_URL"),
    webhook_token: System.get_env("GX_PI_WEBHOOK_TOKEN"),
    disk_alert_percent: String.to_integer(System.get_env("GX_PI_DISK_ALERT_PERCENT", "85")),
    rag_claim_lease_seconds: String.to_integer(System.get_env("RAG_CLAIM_LEASE_SECONDS", "120")),
    trend_enabled: trend_enabled,
    full_analysis_enabled: full_analysis_enabled,
    full_analysis_limit: String.to_integer(System.get_env("GX_PI_FULL_ANALYSIS_LIMIT", "5")),
    full_analysis_backlog_warning_threshold:
      String.to_integer(System.get_env("GX_PI_FULL_ANALYSIS_BACKLOG_WARNING_THRESHOLD", "20")),
    full_analysis_pinned_tickers: full_analysis_pinned_tickers,
    full_stage_claim_lease_seconds:
      String.to_integer(System.get_env("FULL_STAGE_CLAIM_LEASE_SECONDS", "2100")),
    port_runner: [
      executable: python,
      project_root: trading_root,
      artifact_root: artifact_root,
      argv_prefix: ["-m", "cli.gx_main"],
      timeout_ms: String.to_integer(System.get_env("TRADING_AGENTS_TIMEOUT_MS", "900000")),
      full_stage_timeout_ms:
        String.to_integer(System.get_env("TRADING_AGENTS_FULL_STAGE_TIMEOUT_MS", "1800000")),
      max_output_bytes:
        String.to_integer(System.get_env("TRADING_AGENTS_MAX_OUTPUT_BYTES", "2000000"))
    ],
    rag: [
      base_url: System.get_env("RAG_SERVICE_URL", "http://127.0.0.1:8000"),
      api_key: rag_key,
      timeout_ms: String.to_integer(System.get_env("RAG_TIMEOUT_MS", "60000"))
    ]

  config :gx_portfolio_intelligence, Oban,
    repo: GxPortfolioIntelligence.Repo,
    peer: Oban.Peers.Database,
    queues: [
      control: String.to_integer(System.get_env("OBAN_CONTROL_CONCURRENCY", "1")),
      collectors: String.to_integer(System.get_env("OBAN_COLLECTORS_CONCURRENCY", "1")),
      research: String.to_integer(System.get_env("OBAN_RESEARCH_CONCURRENCY", "4")),
      trend: String.to_integer(System.get_env("OBAN_TREND_CONCURRENCY", "1")),
      full_analysis: String.to_integer(System.get_env("OBAN_FULL_ANALYSIS_CONCURRENCY", "2")),
      rag: String.to_integer(System.get_env("OBAN_RAG_CONCURRENCY", "2")),
      maintenance: String.to_integer(System.get_env("OBAN_MAINTENANCE_CONCURRENCY", "1"))
    ],
    plugins: plugins
end
