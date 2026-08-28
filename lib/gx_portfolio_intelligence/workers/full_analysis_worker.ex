defmodule GxPortfolioIntelligence.Workers.FullAnalysisWorker do
  use Oban.Worker,
    queue: :full_analysis,
    max_attempts: 40,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias GxPortfolioIntelligence.{ArtifactStore, FullAnalysis, FullReportEnvelope}
  alias GxPortfolioIntelligence.TradingAgents.Runner
  alias GxPortfolioIntelligence.Workers.FullPromotionWorker

  @impl true
  def perform(%Oban.Job{args: %{"item_id" => item_id}}) do
    item = FullAnalysis.load_item!(item_id)

    cond do
      item.status == "complete" and item.rag_status == "ready" ->
        :ok

      item.status == "blocked" ->
        :ok

      item.research_item.status not in ["complete", "partial"] ->
        {:snooze, 30}

      is_nil(item.session_path) ->
        initialize(item)

      true ->
        resume(item)
    end
  end

  defp initialize(item) do
    batch = item.full_analysis_batch.research_batch

    with {:ok, output_root} <- ArtifactStore.root(),
         {:ok, result} <-
           Runner.analysis_init(
             ticker: item.ticker,
             date: batch.analysis_date,
             cutoff: batch.cutoff_at,
             research_mode: batch.research_mode,
             data_provenance: provenance(batch),
             liquidity_rank: item.liquidity_rank,
             universe_fingerprint: batch_universe_fingerprint(batch),
             execution_key: item.execution_key,
             execution_generation: item.execution_generation,
             parent_identity_hash: item.parent_identity_hash,
             expected_digest_hash: item.expected_digest_hash,
             output_root: output_root
           ),
         {:ok, _updated} <- FullAnalysis.initialize_item(item, result) do
      {:snooze, 1}
    else
      {:error, :research_claimed} ->
        {:snooze, 5}

      {:error, reason} = error ->
        FullAnalysis.fail_item(item, reason)
        error
    end
  end

  defp resume(item) do
    with {:ok, status} <- Runner.analysis_status(session: item.session_path),
         {:ok, reconciled} <- FullAnalysis.reconcile_status(item, status) do
      case FullAnalysis.next_stage(reconciled) do
        nil -> export(reconciled)
        stage -> run_stage(reconciled, stage)
      end
    else
      {:error, :research_claimed} -> {:snooze, 5}
      {:error, _} = error -> error
    end
  end

  defp run_stage(item, stage) do
    case FullAnalysis.claim_stage(stage) do
      {:ok, running, claim_key} -> run_claimed_stage(item, running, claim_key)
      {:busy, _current} -> {:snooze, 15}
      {:already_complete, _current} -> {:snooze, 1}
    end
  end

  defp run_claimed_stage(item, stage, claim_key) do
    case Runner.analysis_run_stage(
           session: item.session_path,
           stage: stage.stage,
           expected_identity: item.identity_hash
         ) do
      {:ok, result} ->
        case FullAnalysis.complete_stage(stage, claim_key, result) do
          {:ok, _completed} ->
            {:snooze, 1}

          {:error, reason} = error ->
            FullAnalysis.mark_stage_failed(stage, claim_key, reason)
            error
        end

      {:error, :research_claimed} ->
        _ = FullAnalysis.release_stage_claim(stage, claim_key)
        {:snooze, 5}

      {:error, reason} = error ->
        FullAnalysis.mark_stage_failed(stage, claim_key, reason)
        error
    end
  end

  defp export(item) do
    batch = item.full_analysis_batch.research_batch

    with {:ok, result} <- Runner.analysis_export_rag(session: item.session_path) do
      case result["status"] do
        "not_publishable" ->
          FullAnalysis.mark_not_publishable(item, :core_stage_incomplete)
          :ok

        status when status in ["complete", "partial"] ->
          persist_export(item, batch, result)

        _ ->
          {:error, :invalid_analysis_export_contract}
      end
    end
  end

  defp persist_export(item, batch, result) do
    envelope_path = result["rag_envelope_path"]

    expected = %{
      source: batch.source,
      ticker: item.ticker,
      analysis_date: batch.analysis_date,
      cutoff_at: batch.cutoff_at,
      liquidity_rank: item.liquidity_rank,
      research_mode: batch.research_mode,
      data_provenance: provenance(batch),
      identity_hash: item.identity_hash,
      parent_identity_hash: item.parent_identity_hash,
      expected_digest_hash: item.expected_digest_hash,
      execution_generation: item.execution_generation
    }

    with true <- is_binary(envelope_path) or {:error, :missing_full_report_path},
         true <- result["schema_version"] == 2 or {:error, :invalid_analysis_export_contract},
         true <-
           result["identity_hash"] == item.identity_hash or {:error, :full_identity_mismatch},
         true <-
           result["parent_identity_hash"] == item.parent_identity_hash or
             {:error, :parent_identity_mismatch},
         {:ok, envelope} <- ArtifactStore.read_json(envelope_path, 262_144),
         {:ok, safe, source_updated_at} <- FullReportEnvelope.sanitize(envelope, expected),
         true <-
           result["full_report_hash"] == safe["full_report_hash"] or
             {:error, :full_report_hash_mismatch},
         {:ok, updated} <-
           FullAnalysis.mark_promoting(item, %{
             envelope_path: envelope_path,
             full_report_hash: safe["full_report_hash"],
             source_updated_at: source_updated_at
           }),
         {:ok, _job} <- FullPromotionWorker.new(%{"item_id" => updated.id}) |> Oban.insert() do
      :ok
    else
      false ->
        {:error, :invalid_analysis_export_contract}

      {:error, reason} = error ->
        FullAnalysis.mark_not_publishable(item, reason)
        error
    end
  end

  defp provenance(batch),
    do:
      batch.metadata["data_provenance"] ||
        if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff")

  defp batch_universe_fingerprint(batch) do
    batch = GxPortfolioIntelligence.Repo.preload(batch, :universe_snapshot)
    batch.universe_snapshot.fingerprint
  end
end
