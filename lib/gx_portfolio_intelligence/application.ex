defmodule GxPortfolioIntelligence.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GxPortfolioIntelligenceWeb.Telemetry,
      GxPortfolioIntelligence.Repo,
      {Phoenix.PubSub, name: GxPortfolioIntelligence.PubSub},
      {Finch, name: GxPortfolioIntelligence.Finch},
      {Oban, Application.fetch_env!(:gx_portfolio_intelligence, Oban)},
      GxPortfolioIntelligenceWeb.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GxPortfolioIntelligence.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    GxPortfolioIntelligenceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
