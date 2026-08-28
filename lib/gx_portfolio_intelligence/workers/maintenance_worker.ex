defmodule GxPortfolioIntelligence.Workers.MaintenanceWorker do
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 900, fields: [:worker, :args], states: :all]

  alias GxPortfolioIntelligence.{
    Alerts,
    ArtifactStore,
    Calendar,
    DependencyCheck,
    FullAnalysis,
    Orchestrator,
    Research
  }

  alias GxPortfolioIntelligence.Workers.SlaWorker

  @impl true
  def perform(_job) do
    latest = Research.latest_batch()
    maybe_alert_dependencies(latest)

    Research.list_recoverable_batches()
    |> Enum.each(fn recoverable ->
      maybe_retry_failed(recoverable)
      maybe_reconcile_sla(recoverable)
    end)

    maybe_reconcile_missing_batch()
    maybe_reconcile_current_batch()
    FullAnalysis.recover_incomplete()
    maybe_alert_disk(latest)
    :ok
  end

  defp maybe_alert_dependencies(batch) do
    {ready, checks} = DependencyCheck.ready?()

    unless ready do
      failed =
        checks
        |> Enum.reject(fn {_name, ok?} -> ok? end)
        |> Enum.map_join(",", &to_string(elem(&1, 0)))

      if batch do
        Alerts.emit(:dependency_unhealthy, batch, %{phase: time_bucket(), reason: failed})
      else
        Alerts.emit_global(:dependency_unhealthy, Calendar.today(), %{
          phase: time_bucket(),
          reason: failed
        })
      end
    end

    :ok
  end

  defp maybe_retry_failed(%{status: "completed"}), do: :ok

  defp maybe_retry_failed(batch) do
    case Orchestrator.retry(batch) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Alerts.emit(:batch_blocked, batch, %{reason: Research.error_text(reason)})
    end
  end

  defp maybe_reconcile_sla(%{batch_type: "adhoc"}), do: :ok

  defp maybe_reconcile_sla(batch) do
    {:ok, deadline} =
      GxPortfolioIntelligence.Calendar.sla_deadline(batch.analysis_date, "final_sla")

    cond do
      batch.sla_status == "pending" and DateTime.compare(DateTime.utc_now(), deadline) != :lt ->
        SlaWorker.new(%{"batch_id" => batch.id, "phase" => "final_sla"}) |> Oban.insert()

      batch.sla_status == "missed" and is_nil(batch.sla_recovered_at) and
          batch.rag_ready_count >= batch.sla_ready_count ->
        SlaWorker.new(%{"batch_id" => batch.id, "phase" => "recovery"}) |> Oban.insert()

      true ->
        :ok
    end
  end

  defp maybe_reconcile_missing_batch do
    expected_date = Calendar.previous_weekday()
    {:ok, deadline} = Calendar.sla_deadline(expected_date, "final_sla")

    if DateTime.compare(DateTime.utc_now(), deadline) != :lt and
         is_nil(Research.batch_for_date(expected_date)) and
         not match?(%{status: "skipped"}, Research.snapshot_for(expected_date, "15:15")) do
      Alerts.emit_global(:batch_sla_missed, expected_date, %{
        phase: "final_sla",
        reason: "research_batch_missing"
      })

      Orchestrator.recover_missing_batch(expected_date)
    end

    :ok
  end

  defp maybe_reconcile_current_batch do
    today = Calendar.today()
    {:ok, freeze_at} = Calendar.at_slot(today, "15:15")

    if DateTime.compare(DateTime.utc_now(), freeze_at) != :lt and
         is_nil(Research.batch_for_date(today)) and
         not match?(%{status: "skipped"}, Research.snapshot_for(today, "15:15")) do
      Orchestrator.recover_missing_batch(today)
    end

    :ok
  end

  defp maybe_alert_disk(batch) do
    with {:ok, root} <- ArtifactStore.root(),
         {:ok, percent} <- disk_used_percent(root),
         threshold <- Application.get_env(:gx_portfolio_intelligence, :disk_alert_percent, 85),
         true <- percent >= threshold do
      payload = %{
        phase: "disk-#{Date.utc_today()}",
        reason: "artifact_disk_capacity_low",
        disk_used_percent: percent
      }

      if batch,
        do: Alerts.emit(:dependency_unhealthy, batch, payload),
        else: Alerts.emit_global(:dependency_unhealthy, Calendar.today(), payload)
    else
      _ -> :ok
    end
  end

  defp disk_used_percent(path) do
    disks = :disksup.get_disk_data()
    expanded = Path.expand(path)

    disks
    |> Enum.map(fn {mount, _kilobytes, percent} -> {to_string(mount), percent} end)
    |> Enum.filter(fn {mount, _percent} ->
      expanded == mount or String.starts_with?(expanded, String.trim_trailing(mount, "/") <> "/")
    end)
    |> Enum.max_by(fn {mount, _percent} -> byte_size(mount) end, fn -> nil end)
    |> case do
      {_mount, percent} when is_integer(percent) -> {:ok, percent}
      _ -> {:error, :disk_unknown}
    end
  end

  defp time_bucket do
    now = DateTime.utc_now()
    "#{Date.to_iso8601(DateTime.to_date(now))}-#{now.hour}"
  end
end
