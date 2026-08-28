defmodule GxPortfolioIntelligence.Workers.SlaWorker do
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias GxPortfolioIntelligence.{Alerts, Calendar, Research}

  @impl true
  def perform(%Oban.Job{args: %{"batch_id" => batch_id, "phase" => phase}}) do
    {:ok, batch} = Research.refresh_batch_counts(batch_id)

    if batch.batch_type == "adhoc", do: :ok, else: evaluate(batch, phase)
  end

  defp evaluate(batch, "recovery") do
    if batch.sla_status == "missed" and is_nil(batch.sla_recovered_at) and
         batch.rag_ready_count >= batch.sla_ready_count do
      with {:ok, _alert} <-
             Alerts.emit(:batch_recovered, batch, %{phase: "recovery"}),
           {:ok, _recovered} <- Research.mark_sla_recovered(batch) do
        :ok
      end
    else
      :ok
    end
  end

  defp evaluate(batch, phase) when phase in ["early_sla", "final_sla"] do
    {:ok, deadline} = Calendar.sla_deadline(batch.analysis_date, phase)
    now = DateTime.utc_now()

    if DateTime.compare(now, deadline) == :lt do
      {:snooze, max(DateTime.diff(deadline, now, :second), 1)}
    else
      ready_at_deadline = Research.rag_ready_count_at(batch.id, deadline)

      cond do
        phase == "early_sla" and ready_at_deadline < batch.sla_ready_count ->
          with {:ok, _alert} <-
                 Alerts.emit(:batch_blocked, batch, %{
                   phase: phase,
                   reason: "below_sla_threshold",
                   rag_ready_count: ready_at_deadline
                 }) do
            :ok
          end

        phase == "early_sla" ->
          :ok

        ready_at_deadline >= batch.sla_ready_count ->
          {:ok, _met} = Research.set_sla(batch, "met")
          :ok

        true ->
          with {:ok, _alert} <-
                 Alerts.emit(:batch_sla_missed, batch, %{
                   phase: phase,
                   reason: "below_sla_threshold",
                   rag_ready_count: ready_at_deadline
                 }),
               {:ok, _missed} <- Research.set_sla(batch, "missed") do
            :ok
          end
      end
    end
  end
end
