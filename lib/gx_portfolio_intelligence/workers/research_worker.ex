defmodule GxPortfolioIntelligence.Workers.ResearchWorker do
  use Oban.Worker,
    queue: :research,
    max_attempts: 8,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias GxPortfolioIntelligence.{ArtifactStore, DigestEnvelope, FullAnalysis, Repo, Research}
  alias GxPortfolioIntelligence.Schemas.{ResearchBatch, ResearchItem, UniverseMember}
  alias GxPortfolioIntelligence.TradingAgents.Runner
  alias GxPortfolioIntelligence.Workers.RagBatchWorker

  @impl true
  def perform(%Oban.Job{args: %{"item_id" => item_id}}) do
    item = Repo.get!(ResearchItem, item_id)
    batch = Repo.get!(ResearchBatch, item.research_batch_id) |> Repo.preload(:universe_snapshot)

    case Research.claim_item(item.id) do
      {:ok, claimed} ->
        run_research(claimed, batch)

      {:already_complete, claimed} when claimed.status in ["complete", "partial"] ->
        with :ok <- enqueue_rag(batch.id) do
          schedule_full_best_effort(claimed)
        end

      {:already_complete, _claimed} ->
        :ok
    end
  end

  defp run_research(item, batch) do
    member =
      Repo.get_by!(UniverseMember,
        universe_snapshot_id: batch.universe_snapshot_id,
        ticker: item.ticker
      )

    with {:ok, output_root} <- ArtifactStore.root(),
         {:ok, result} <-
           Runner.run_one(
             ticker: item.ticker,
             date: batch.analysis_date,
             cutoff: batch.cutoff_at,
             liquidity_rank: item.liquidity_rank,
             adtv20: member.adtv20,
             adv20: member.adv20,
             universe_fingerprint: batch.universe_snapshot.fingerprint,
             mode: batch.batch_type,
             research_mode: batch.research_mode,
             execution_key: execution_key(batch, item),
             output_root: output_root
           ),
         :ok <- persist_result(item, batch, result) do
      :ok
    else
      {:error, :research_claimed} ->
        {:snooze, 5}

      {:error, reason} = error ->
        Research.fail_item(Repo.get!(ResearchItem, item.id), reason)
        error
    end
  end

  defp persist_result(item, batch, result) do
    envelope_path = result["rag_envelope_path"]

    with true <- is_binary(envelope_path) or {:error, :missing_rag_envelope_path},
         {:ok, envelope} <- ArtifactStore.read_json(envelope_path),
         {:ok, digest, source_updated_at} <-
           DigestEnvelope.sanitize(envelope, %{
             ticker: item.ticker,
             analysis_date: batch.analysis_date,
             cutoff_at: batch.cutoff_at,
             liquidity_rank: item.liquidity_rank,
             source: batch.source,
             research_mode: batch.research_mode,
             data_provenance:
               batch.metadata["data_provenance"] ||
                 if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff"),
             identity_hash: result["identity_hash"],
             digest_hash: result["digest_hash"]
           }),
         {:ok, completed_item} <- Research.complete_item(item, result, digest, source_updated_at),
         {:ok, _batch} <- Research.refresh_batch_counts(batch.id),
         :ok <- enqueue_rag(batch.id) do
      schedule_full_best_effort(completed_item)
    else
      false -> {:error, :invalid_research_contract}
      {:error, _} = error -> error
    end
  end

  defp enqueue_rag(batch_id) do
    case RagBatchWorker.new(%{"batch_id" => batch_id}) |> Oban.insert() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_full_best_effort(item) do
    case FullAnalysis.maybe_schedule_item(item) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning("full analysis scheduling failed",
          error_code: GxPortfolioIntelligence.SafeError.code(reason),
          research_item_id: item.id
        )

        :ok
    end
  end

  defp execution_key(%{batch_type: "adhoc"} = batch, item) do
    :crypto.hash(:sha256, "#{batch.source}:#{batch.id}:#{item.id}:#{item.ticker}")
    |> Base.encode16(case: :lower)
  end

  defp execution_key(_batch, _item), do: nil
end
