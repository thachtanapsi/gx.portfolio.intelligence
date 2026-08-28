defmodule GxPortfolioIntelligence.Workers.TrendWorker do
  use Oban.Worker,
    queue: :trend,
    max_attempts: 8,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias GxPortfolioIntelligence.{ArtifactStore, FullAnalysis, Repo}
  alias GxPortfolioIntelligence.Schemas.UniverseSnapshot
  alias GxPortfolioIntelligence.TradingAgents.Runner

  @impl true
  def perform(%Oban.Job{args: %{"snapshot_id" => snapshot_id, "manifest_path" => manifest}}) do
    universe = Repo.get!(UniverseSnapshot, snapshot_id) |> Repo.preload(:members)

    with {:ok, cutoff} <- trend_cutoff(universe),
         previous_cutoff <- FullAnalysis.previous_cutoff(universe) || DateTime.add(cutoff, -3600),
         {:ok, output} <-
           ArtifactStore.path([
             "trends",
             Date.to_iso8601(universe.analysis_date),
             universe.slot <> ".json"
           ]),
         {:ok, result} <-
           Runner.trend(
             date: universe.analysis_date,
             cutoff: cutoff,
             previous_cutoff: previous_cutoff,
             slot: universe.slot,
             universe_manifest: manifest,
             output: output,
             weights: FullAnalysis.trend_weights()
           ),
         {:ok, _trend} <-
           FullAnalysis.persist_trend(result, universe,
             cutoff: cutoff,
             previous_cutoff: previous_cutoff,
             artifact_path: output,
             frozen: universe.frozen
           ) do
      :ok
    end
  end

  defp trend_cutoff(%{frozen: true, analysis_date: date}),
    do: GxPortfolioIntelligence.Calendar.at_slot(date, "15:00")

  defp trend_cutoff(%{cutoff_at: cutoff}), do: {:ok, cutoff}
end
