defmodule GxPortfolioIntelligence.Workers.RagBatchWorker do
  use Oban.Worker,
    queue: :rag,
    max_attempts: 100,
    unique: [period: 86_400, fields: [:worker, :args], states: :incomplete]

  alias GxPortfolioIntelligence.{Alerts, RAG, Research}
  alias GxPortfolioIntelligence.Workers.SlaWorker

  @page_size 50
  @claim_size 25
  @max_pages 12

  @impl true
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    batch = Research.get_batch!(batch_id)
    counts = Research.item_counts(batch.id)

    if counts.total == 0 do
      :ok
    else
      rag_batch = %{batch | target_count: counts.total}

      with {:ok, _} <- RAG.put_batch(rag_batch),
           {:ok, items} <- Research.claim_rag_items(batch.id, @claim_size) do
        process_claimed(batch, items)
      end
    end
  end

  defp process_claimed(batch, []) do
    with {:ok, remote_items} <- fetch_all_statuses(batch.id),
         {:ok, refreshed} <- Research.sync_rag_statuses(batch.id, remote_items) do
      counts = Research.item_counts(batch.id)
      maybe_emit_recovery(refreshed)

      cond do
        counts.total > 0 and counts.ready == counts.total ->
          with {:ok, _} <- RAG.seal(batch.id) do
            :ok
          end

        counts.pending_rag > 0 ->
          {:snooze, 15}

        counts.stale > 0 ->
          Alerts.emit(:batch_blocked, refreshed, %{reason: "rag_stale_document"})
          :ok

        true ->
          {:snooze, 15}
      end
    end
  end

  defp process_claimed(batch, items) do
    documents = Enum.map(items, &document(batch, &1))

    case RAG.put_documents(batch.id, documents) do
      {:ok, response} ->
        actions = actions_by_ticker(response)
        {:ok, _batch} = Research.mark_rag_submitted(items, actions)
        {:snooze, 1}

      {:error, reason} = error ->
        Research.release_rag_items(items, reason)
        error
    end
  end

  defp fetch_all_statuses(batch_id) do
    Enum.reduce_while(1..@max_pages, {:ok, []}, fn page, {:ok, acc} ->
      case RAG.status(batch_id, page: page, page_size: @page_size) do
        {:ok, response} ->
          items = response["items"] || []
          next = acc ++ items

          if length(items) < @page_size do
            {:halt, {:ok, next}}
          else
            {:cont, {:ok, next}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp document(batch, item) do
    Map.take(item.digest, [
      "schema_version",
      "ticker",
      "analysis_date",
      "cutoff",
      "source_updated_at",
      "liquidity_rank",
      "identity_hash",
      "digest_hash",
      "prompt_fingerprint",
      "model_fingerprint",
      "evidence_fingerprint",
      "status",
      "sections",
      "research_mode",
      "data_provenance"
    ])
    |> Map.put("research_mode", batch.research_mode)
    |> Map.put(
      "data_provenance",
      batch.metadata["data_provenance"] ||
        if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff")
    )
  end

  defp actions_by_ticker(response) do
    items = response["items"] || response["results"] || response["documents"] || []

    Map.new(items, fn item ->
      {String.upcase(to_string(item["ticker"] || "")), item["action"] || "accepted"}
    end)
  end

  defp maybe_emit_recovery(batch) do
    if batch.sla_status == "missed" and is_nil(batch.sla_recovered_at) and
         batch.rag_ready_count >= batch.sla_ready_count do
      SlaWorker.new(%{"batch_id" => batch.id, "phase" => "recovery"}) |> Oban.insert()
    end
  end
end
