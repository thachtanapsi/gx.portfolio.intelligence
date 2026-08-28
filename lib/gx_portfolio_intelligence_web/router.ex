defmodule GxPortfolioIntelligenceWeb.Router do
  use GxPortfolioIntelligenceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug GxPortfolioIntelligenceWeb.Plugs.BearerAuth
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/health", GxPortfolioIntelligenceWeb do
    pipe_through :health
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/api/v1", GxPortfolioIntelligenceWeb do
    pipe_through :api

    post "/research-batches", ResearchBatchController, :create
    post "/ad-hoc-research-batches", ResearchBatchController, :create_adhoc
    get "/research-batches", ResearchBatchController, :index
    get "/research-batches/:id", ResearchBatchController, :show
    get "/research-batches/:id/items", ResearchBatchController, :items
    post "/research-batches/:id/retry", ResearchBatchController, :retry
    get "/research-batches/:id/full-analysis", FullAnalysisController, :show
    get "/research-batches/:id/full-analysis/items", FullAnalysisController, :items

    get "/research-batches/:id/full-analysis/items/:ticker/report",
        FullAnalysisController,
        :report

    get "/research-batches/:id/full-analysis/items/:ticker/stages",
        FullAnalysisController,
        :stages

    post "/research-batches/:id/full-analysis/retry", FullAnalysisController, :retry
    get "/trend-snapshots", TrendSnapshotController, :index
    get "/universe-snapshots", UniverseSnapshotController, :index
  end
end
