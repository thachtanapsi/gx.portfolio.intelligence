import Config

config :gx_portfolio_intelligence,
  ecto_repos: [GxPortfolioIntelligence.Repo],
  timezone: "Asia/Ho_Chi_Minh",
  cutoff_time: ~T[15:45:00],
  target_count: 500,
  sla_ready_count: 490,
  rag_claim_lease_seconds: 120,
  trend_enabled: false,
  full_analysis_enabled: false,
  full_analysis_limit: 5,
  full_analysis_backlog_warning_threshold: 20,
  full_analysis_pinned_tickers: [],
  full_stage_claim_lease_seconds: 2_100,
  trend_weights: %{
    "volume_ratio" => 30,
    "daily_move_abs" => 25,
    "momentum20_abs" => 15,
    "social_attention" => 15,
    "media_event" => 15
  },
  cron_enabled: false,
  auth_token: nil,
  trading_agents_runner: GxPortfolioIntelligence.TradingAgents.PortRunner,
  rag_client: GxPortfolioIntelligence.RAG.Client,
  alert_dispatcher: GxPortfolioIntelligence.Alerts.Webhook,
  webhook_url: nil,
  webhook_token: nil,
  disk_alert_percent: 85,
  port_runner: [
    executable: nil,
    project_root: nil,
    artifact_root: nil,
    argv_prefix: ["-m", "cli.gx_main"],
    timeout_ms: 900_000,
    full_stage_timeout_ms: 1_800_000,
    max_output_bytes: 2_000_000
  ],
  rag: [base_url: "http://127.0.0.1:8000", api_key: nil, timeout_ms: 60_000],
  finch: [name: GxPortfolioIntelligence.Finch]

config :gx_portfolio_intelligence, GxPortfolioIntelligence.Repo,
  migration_primary_key: [name: :id, type: :bigserial],
  migration_timestamps: [type: :utc_datetime_usec]

config :gx_portfolio_intelligence, GxPortfolioIntelligenceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: GxPortfolioIntelligenceWeb.ErrorJSON], layout: false],
  pubsub_server: GxPortfolioIntelligence.PubSub,
  live_view: [signing_salt: "gx-pi-api-only"]

config :phoenix, :json_library, Jason
config :tzdata, :autoupdate, :disabled
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

import_config "#{config_env()}.exs"
