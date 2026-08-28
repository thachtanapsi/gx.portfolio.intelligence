defmodule GxPortfolioIntelligenceWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :gx_portfolio_intelligence

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :gx_portfolio_intelligence
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library(),
    length: 2_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug GxPortfolioIntelligenceWeb.Router
end
