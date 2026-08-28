defmodule GxPortfolioIntelligence.Workers.FanoutWorker do
  use Oban.Worker,
    queue: :control,
    max_attempts: 120,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias GxPortfolioIntelligence.{Orchestrator, Research}

  @impl true
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    batch = Research.get_batch!(batch_id)

    cond do
      is_nil(batch.universe_snapshot_id) ->
        {:error, :universe_not_frozen}

      batch.batch_type == "adhoc" ->
        Orchestrator.fanout(batch) |> normalize()

      not Research.final_evidence_ready?(batch.analysis_date) ->
        {:snooze, 30}

      true ->
        Orchestrator.fanout(batch) |> normalize()
    end
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize(error), do: error
end
