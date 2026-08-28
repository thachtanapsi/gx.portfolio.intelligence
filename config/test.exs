import Config

config :gx_portfolio_intelligence, GxPortfolioIntelligence.Repo,
  username: System.get_env("GX_PI_DB_USER", "postgres"),
  password: System.get_env("GX_PI_DB_PASSWORD", "postgres"),
  hostname: System.get_env("GX_PI_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("GX_PI_DB_PORT", "5432")),
  database: System.get_env("GX_PI_TEST_DB_NAME", "gx_portfolio_intelligence_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :gx_portfolio_intelligence, GxPortfolioIntelligenceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4012],
  secret_key_base: "test-secret-key-base-at-least-sixty-four-bytes-long-000000000000001",
  server: false

config :gx_portfolio_intelligence, Oban,
  repo: GxPortfolioIntelligence.Repo,
  testing: :manual,
  queues: false,
  plugins: false

config :gx_portfolio_intelligence,
  auth_token: "test-api-token",
  trading_agents_runner: GxPortfolioIntelligence.TestRunner,
  rag_client: GxPortfolioIntelligence.TestRAGClient,
  alert_dispatcher: GxPortfolioIntelligence.TestAlertDispatcher

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
