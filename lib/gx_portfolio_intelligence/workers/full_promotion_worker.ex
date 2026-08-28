defmodule GxPortfolioIntelligence.Workers.FullPromotionWorker do
  use Oban.Worker,
    queue: :rag,
    max_attempts: 100,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias GxPortfolioIntelligence.{ArtifactStore, FullAnalysis, FullReportEnvelope, RAG}

  @impl true
  def perform(%Oban.Job{args: %{"item_id" => item_id}}) do
    item = FullAnalysis.load_item!(item_id)
    batch = item.full_analysis_batch.research_batch

    cond do
      item.rag_status == "ready" ->
        :ok

      item.rag_status == "stale" ->
        :ok

      item.research_item.rag_status != "ready" ->
        {:snooze, 15}

      true ->
        promote(item, batch)
    end
  end

  defp promote(item, batch) do
    with {:ok, remote} <- RAG.status(batch.id, page: 1, page_size: 1),
         true <- sealed?(remote) or {:snooze, 15},
         {:ok, envelope} <- ArtifactStore.read_json(item.envelope_path, 262_144),
         {:ok, safe, _source_updated_at} <-
           FullReportEnvelope.sanitize(envelope, expected(item, batch)),
         {:ok, response} <- RAG.promote(batch.id, [safe]) do
      handle_response(item, response)
    else
      {:snooze, _} = snooze ->
        snooze

      false ->
        {:snooze, 15}

      {:error, reason} = error ->
        FullAnalysis.mark_promotion_failed(item, reason)
        error
    end
  end

  defp handle_response(item, response) do
    remote =
      (response["items"] || response["results"] || response["documents"] || [])
      |> Enum.find(fn value -> String.upcase(to_string(value["ticker"] || "")) == item.ticker end)

    case remote do
      %{"action" => action, "status" => "ready"} when action in ["promoted", "unchanged"] ->
        FullAnalysis.mark_promoted(item, action)
        :ok

      %{"action" => action, "status" => status}
      when action in ["promoted", "unchanged"] and status in ["pending", "submitted", "indexing"] ->
        FullAnalysis.mark_promotion_submitted(item, status)
        {:snooze, 10}

      %{"action" => "stale"} ->
        FullAnalysis.mark_promotion_failed(item, :stale)
        :ok

      %{"action" => "conflict"} ->
        FullAnalysis.mark_promotion_failed(item, :full_report_conflict)
        :ok

      _ ->
        {:error, :invalid_rag_promotion_response}
    end
  end

  defp sealed?(response) do
    status = response["status"] || get_in(response, ["batch", "status"])
    status in ["sealed", "complete", "completed"] or response["sealed"] == true
  end

  defp expected(item, batch) do
    %{
      source: batch.source,
      ticker: item.ticker,
      analysis_date: batch.analysis_date,
      cutoff_at: batch.cutoff_at,
      liquidity_rank: item.liquidity_rank,
      research_mode: batch.research_mode,
      data_provenance:
        batch.metadata["data_provenance"] ||
          if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff"),
      identity_hash: item.identity_hash,
      parent_identity_hash: item.parent_identity_hash,
      expected_digest_hash: item.expected_digest_hash,
      execution_generation: item.execution_generation
    }
  end
end
