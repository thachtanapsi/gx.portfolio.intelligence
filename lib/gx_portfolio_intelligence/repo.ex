defmodule GxPortfolioIntelligence.Repo do
  use Ecto.Repo,
    otp_app: :gx_portfolio_intelligence,
    adapter: Ecto.Adapters.Postgres
end
