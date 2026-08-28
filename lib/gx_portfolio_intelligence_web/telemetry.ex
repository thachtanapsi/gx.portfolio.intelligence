defmodule GxPortfolioIntelligenceWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("gx_portfolio_intelligence.repo.query.total_time", unit: {:native, :millisecond}),
      counter("oban.job.stop.duration", tags: [:queue, :worker, :state])
    ]
  end

  defp periodic_measurements, do: []
end
