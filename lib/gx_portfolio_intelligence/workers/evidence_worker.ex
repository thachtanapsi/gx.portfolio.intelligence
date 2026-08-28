defmodule GxPortfolioIntelligence.Workers.EvidenceWorker do
  use Oban.Worker,
    queue: :collectors,
    max_attempts: 8,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias GxPortfolioIntelligence.{ArtifactStore, Calendar, Repo, Research}
  alias GxPortfolioIntelligence.Schemas.UniverseSnapshot
  alias GxPortfolioIntelligence.TradingAgents.Runner

  @impl true
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    snapshot = Repo.get!(UniverseSnapshot, args["snapshot_id"]) |> Repo.preload(:members)

    with {:ok, tickers_file} <- tickers_file(args, snapshot),
         {:ok, run} <-
           Research.create_evidence_run(%{
             analysis_date: snapshot.analysis_date,
             slot: args["slot"],
             lane: args["lane"],
             target_count: snapshot.member_count,
             universe_snapshot_id: snapshot.id
           }),
         result <-
           execute_unless_complete(
             run,
             snapshot,
             tickers_file,
             args,
             attempt,
             max_attempts
           ) do
      result
    end
  end

  defp execute_unless_complete(
         %{status: "complete"},
         _snapshot,
         _file,
         _args,
         _attempt,
         _max_attempts
       ),
       do: :ok

  defp execute_unless_complete(run, snapshot, tickers_file, args, attempt, max_attempts) do
    with {:ok, cutoff} <- Calendar.at_slot(snapshot.analysis_date, args["slot"]),
         {:ok, output_root} <- ArtifactStore.root(),
         {:ok, running} <- Research.mark_evidence_running(run),
         {:ok, result} <-
           Runner.collect(
             lane: args["lane"],
             slot: args["slot"],
             cutoff: cutoff,
             tickers_file: tickers_file,
             output_root: output_root
           ),
         :ok <- validate_result(result, snapshot, args, cutoff) do
      finalize_result(running, result, attempt, max_attempts)
    else
      {:error, reason} = error ->
        current = Repo.get!(GxPortfolioIntelligence.Schemas.EvidenceRun, run.id)

        if attempt < max_attempts do
          {:ok, _} = Research.record_evidence_error_retry(current, reason)
        else
          {:ok, _} = Research.fail_evidence(current, reason)
        end

        error
    end
  end

  defp finalize_result(running, %{"status" => "complete"} = result, _attempt, _max_attempts) do
    with {:ok, _completed} <- Research.complete_evidence(running, result), do: :ok
  end

  defp finalize_result(running, result, attempt, max_attempts) when attempt < max_attempts do
    with {:ok, _pending} <- Research.record_evidence_retry(running, result) do
      {:error, :evidence_incomplete}
    end
  end

  defp finalize_result(running, result, _attempt, _max_attempts) do
    # Only the final bounded attempt is terminal degraded/failed. This keeps
    # the fan-out barrier closed throughout all retryable attempts.
    with {:ok, _terminal} <- Research.complete_evidence(running, result), do: :ok
  end

  defp tickers_file(%{"tickers_file" => file}, _snapshot) when is_binary(file), do: {:ok, file}

  defp tickers_file(_args, snapshot) do
    ArtifactStore.write_json(
      ["manifests", Date.to_iso8601(snapshot.analysis_date), snapshot.slot <> ".json"],
      %{
        schema_version: "1.0",
        analysis_date: Date.to_iso8601(snapshot.analysis_date),
        cutoff: DateTime.to_iso8601(snapshot.cutoff_at),
        fingerprint: snapshot.fingerprint,
        members:
          snapshot.members
          |> Enum.sort_by(& &1.rank)
          |> Enum.map(
            &%{
              ticker: &1.ticker,
              exchange: &1.exchange,
              liquidity_rank: &1.rank,
              aliases: &1.metadata["aliases"] || []
            }
          )
      }
    )
  end

  defp validate_result(result, snapshot, args, cutoff) when is_map(result) do
    target = if args["lane"] == "macro", do: 1, else: snapshot.member_count
    processed = result["processed_count"]
    succeeded = result["succeeded_count"]
    failed = result["failed_count"]
    status = result["status"]
    watermark = result["watermark"]

    with true <- result["schema_version"] == 1,
         true <- result["analysis_date"] == Date.to_iso8601(snapshot.analysis_date),
         true <- result["lane"] == args["lane"],
         true <- result["slot"] == args["slot"],
         {:ok, result_cutoff, _} <- DateTime.from_iso8601(result["cutoff"] || ""),
         true <- DateTime.compare(result_cutoff, cutoff) == :eq,
         true <- result["target_count"] == target,
         true <- status in ["complete", "partial", "failed"],
         true <- valid_counts?(processed, succeeded, failed, target),
         true <- valid_complete_counts?(status, processed, succeeded, failed, target),
         true <- is_map(watermark),
         {:ok, watermark_cutoff, _} <- DateTime.from_iso8601(watermark["cutoff"] || ""),
         true <- DateTime.compare(watermark_cutoff, cutoff) == :eq,
         true <- watermark["tickers_fingerprint"] == tickers_fingerprint(snapshot, args["lane"]) do
      :ok
    else
      _ -> {:error, :evidence_identity_mismatch}
    end
  end

  defp validate_result(_, _, _, _), do: {:error, :invalid_evidence_contract}

  defp valid_counts?(processed, succeeded, failed, target) do
    Enum.all?([processed, succeeded, failed], &is_integer/1) and
      processed in 0..target and succeeded in 0..processed and failed in 0..processed and
      succeeded + failed <= processed
  end

  defp valid_complete_counts?("complete", processed, succeeded, failed, target),
    do: processed == target and succeeded == target and failed == 0

  defp valid_complete_counts?(_status, _processed, _succeeded, _failed, _target), do: true

  defp tickers_fingerprint(_snapshot, "macro"),
    do: :crypto.hash(:sha256, "[]") |> Base.encode16(case: :lower)

  defp tickers_fingerprint(snapshot, _lane) do
    snapshot.members
    |> Enum.sort_by(& &1.rank)
    |> Enum.map(& &1.ticker)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
