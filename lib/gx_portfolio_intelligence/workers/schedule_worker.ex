defmodule GxPortfolioIntelligence.Workers.ScheduleWorker do
  use Oban.Worker,
    queue: :control,
    max_attempts: 5,
    unique: [
      period: 3_600,
      fields: [:worker, :args],
      states: :all
    ]

  alias GxPortfolioIntelligence.{Calendar, Orchestrator, Research}

  alias GxPortfolioIntelligence.Workers.{
    EvidenceWorker,
    FanoutWorker,
    MaintenanceWorker,
    SlaWorker,
    UniverseWorker
  }

  @impl true
  def perform(%Oban.Job{args: %{"action" => "candidate", "slot" => slot}}) do
    enqueue_universe(Calendar.today(), slot, 600, false, nil)
  end

  def perform(%Oban.Job{args: %{"action" => "freeze", "slot" => slot}}) do
    with {:ok, _job} <- enqueue_universe(Calendar.today(), slot, 500, true, nil) do
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"action" => "collect_final", "slot" => slot}}) do
    enqueue_collectors(Calendar.today(), slot, ~w(social media))
  end

  def perform(%Oban.Job{args: %{"action" => "macro_final", "slot" => slot}}) do
    enqueue_collectors(Calendar.today(), slot, ~w(macro media))
  end

  def perform(%Oban.Job{args: %{"action" => "fanout"}}) do
    today = Calendar.today()

    case Research.latest_batch() do
      nil ->
        {:error, :batch_not_found}

      batch when batch.analysis_date == today ->
        FanoutWorker.new(%{"batch_id" => batch.id}) |> Oban.insert() |> normalize_insert()

      _ ->
        {:error, :batch_not_found_for_today}
    end
  end

  def perform(%Oban.Job{args: %{"action" => phase}}) when phase in ["early_sla", "final_sla"] do
    expected_date = Calendar.previous_weekday()

    case Research.batch_for_date(expected_date) do
      nil ->
        maybe_alert_missing_batch(expected_date, phase)

      batch ->
        SlaWorker.new(%{"batch_id" => batch.id, "phase" => phase})
        |> Oban.insert()
        |> normalize_insert()
    end
  end

  def perform(%Oban.Job{args: %{"action" => "maintenance"}}) do
    MaintenanceWorker.new(%{}) |> Oban.insert() |> normalize_insert()
  end

  defp enqueue_universe(date, slot, limit, frozen, batch_id) do
    args = %{
      "analysis_date" => Date.to_iso8601(date),
      "slot" => slot,
      "limit" => limit,
      "frozen" => frozen
    }

    args = if batch_id, do: Map.put(args, "batch_id", batch_id), else: args
    UniverseWorker.new(args) |> Oban.insert()
  end

  defp enqueue_collectors(date, slot, lanes) do
    case Research.final_snapshot(date) || Research.snapshot_for(date, slot) do
      nil ->
        {:error, :universe_snapshot_not_found}

      %{status: "skipped"} ->
        :ok

      snapshot ->
        Enum.each(lanes, fn lane ->
          EvidenceWorker.new(%{"snapshot_id" => snapshot.id, "lane" => lane, "slot" => slot})
          |> Oban.insert()
        end)

        :ok
    end
  end

  defp normalize_insert({:ok, _}), do: :ok
  defp normalize_insert(error), do: error

  defp maybe_alert_missing_batch(date, phase) do
    case Research.snapshot_for(date, "15:15") do
      %{status: "skipped"} ->
        :ok

      _ ->
        event = if phase == "final_sla", do: :batch_sla_missed, else: :batch_blocked

        with {:ok, _alert} <-
               GxPortfolioIntelligence.Alerts.emit_global(event, date, %{
                 phase: phase,
                 reason: "research_batch_missing"
               }),
             {:ok, _recovery} <- Orchestrator.recover_missing_batch(date) do
          :ok
        end
    end
  end
end
