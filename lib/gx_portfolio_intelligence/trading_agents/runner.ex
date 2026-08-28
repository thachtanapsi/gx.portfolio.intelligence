defmodule GxPortfolioIntelligence.TradingAgents.Runner do
  @moduledoc false

  @callback universe(keyword()) :: {:ok, map()} | {:error, term()}
  @callback collect(keyword()) :: {:ok, map()} | {:error, term()}
  @callback run_one(keyword()) :: {:ok, map()} | {:error, term()}
  @callback status(keyword()) :: {:ok, map()} | {:error, term()}
  @callback trend(keyword()) :: {:ok, map()} | {:error, term()}
  @callback analysis_init(keyword()) :: {:ok, map()} | {:error, term()}
  @callback analysis_run_stage(keyword()) :: {:ok, map()} | {:error, term()}
  @callback analysis_export_rag(keyword()) :: {:ok, map()} | {:error, term()}
  @callback analysis_status(keyword()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks trend: 1,
                      analysis_init: 1,
                      analysis_run_stage: 1,
                      analysis_export_rag: 1,
                      analysis_status: 1

  def implementation do
    Application.fetch_env!(:gx_portfolio_intelligence, :trading_agents_runner)
  end

  def universe(opts), do: implementation().universe(opts)
  def collect(opts), do: implementation().collect(opts)
  def run_one(opts), do: implementation().run_one(opts)
  def status(opts), do: implementation().status(opts)
  def trend(opts), do: implementation().trend(opts)
  def analysis_init(opts), do: implementation().analysis_init(opts)
  def analysis_run_stage(opts), do: implementation().analysis_run_stage(opts)
  def analysis_export_rag(opts), do: implementation().analysis_export_rag(opts)
  def analysis_status(opts), do: implementation().analysis_status(opts)
end
