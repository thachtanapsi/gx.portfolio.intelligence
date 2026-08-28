defmodule GxPortfolioIntelligence.Orchestrator do
  @moduledoc false

  alias GxPortfolioIntelligence.{Calendar, FullAnalysis, Research}

  alias GxPortfolioIntelligence.Workers.{
    EvidenceWorker,
    FanoutWorker,
    RagBatchWorker,
    ResearchWorker,
    UniverseWorker
  }

  @final_lanes [{"15:20", "social"}, {"15:20", "media"}, {"15:30", "macro"}, {"15:30", "media"}]
  @ticker ~r/^[A-Z0-9]{1,16}$/
  @idempotency_key ~r/^[A-Za-z0-9._:-]{8,128}$/
  @max_adhoc_tickers 50

  def create_manual_batch(date \\ Calendar.today(), limit \\ 500) do
    with {:ok, job} <-
           UniverseWorker.new(%{
             "analysis_date" => Date.to_iso8601(date),
             "slot" => "15:15",
             "limit" => limit,
             "frozen" => true
           })
           |> Oban.insert() do
      {:ok, %{job_id: job.id, analysis_date: date, status: "scheduled"}}
    end
  end

  def create_adhoc_batch(tickers, idempotency_key),
    do: create_adhoc_batch(tickers, idempotency_key, :omitted, :omitted, DateTime.utc_now())

  # Backward-compatible deterministic entry point used by existing callers/tests.
  def create_adhoc_batch(tickers, idempotency_key, %DateTime{} = now),
    do: create_adhoc_batch(tickers, idempotency_key, :omitted, :omitted, now)

  def create_adhoc_batch(tickers, idempotency_key, analysis_date),
    do: create_adhoc_batch(tickers, idempotency_key, analysis_date, :omitted, DateTime.utc_now())

  def create_adhoc_batch(tickers, idempotency_key, analysis_date, %DateTime{} = now) do
    create_adhoc_batch(tickers, idempotency_key, analysis_date, :omitted, now)
  end

  def create_adhoc_batch(tickers, idempotency_key, analysis_date, analysis_depth) do
    create_adhoc_batch(
      tickers,
      idempotency_key,
      analysis_date,
      analysis_depth,
      DateTime.utc_now()
    )
  end

  def create_adhoc_batch(
        tickers,
        idempotency_key,
        analysis_date,
        analysis_depth,
        %DateTime{} = now
      ) do
    with {:ok, symbols} <- normalize_adhoc_tickers(tickers),
         {:ok, key_hash} <- hash_idempotency_key(idempotency_key),
         {:ok, depth} <- normalize_analysis_depth(analysis_depth),
         {:ok, local_now} <- DateTime.shift_zone(now, Calendar.timezone()),
         {:ok, request} <- resolve_adhoc_request(analysis_date, local_now, now),
         request_fingerprint <-
           request_fingerprint(symbols, request.requested_date, analysis_depth, depth),
         ticker_set_fingerprint <- ticker_set_fingerprint(symbols),
         {:ok, batch, disposition} <-
           Research.resolve_adhoc_batch(
             %{
               analysis_date: request.analysis_date,
               cutoff_at: request.cutoff,
               research_mode: request.research_mode,
               analysis_depth: depth,
               status: "pending",
               target_count: length(symbols),
               sla_ready_count: length(symbols),
               idempotency_key_hash: key_hash,
               metadata: %{
                 "requested_tickers" => symbols,
                 "request_fingerprint" => request_fingerprint,
                 "ticker_set_fingerprint" => ticker_set_fingerprint,
                 "cutoff_policy" => request.cutoff_policy,
                 "evidence_policy" => request.evidence_policy,
                 "data_provenance" => request.data_provenance,
                 "analysis_depth" => depth
               }
             },
             key_hash,
             request_fingerprint
           ),
         {:ok, job} <- maybe_enqueue_adhoc_universe(batch, disposition),
         :ok <- maybe_start_adhoc_full(batch) do
      {:ok,
       %{
         batch_id: batch.id,
         job_id: if(job, do: job.id, else: nil),
         batch_type: batch.batch_type,
         research_mode: batch.research_mode,
         analysis_depth: batch.analysis_depth,
         status: batch.status,
         analysis_date: batch.analysis_date,
         cutoff_at: batch.cutoff_at,
         tickers: batch.metadata["requested_tickers"],
         evidence_policy: batch.metadata["evidence_policy"],
         data_provenance: batch.metadata["data_provenance"],
         replayed: disposition != :created
       }}
    end
  end

  def recover_missing_batch(date) do
    cond do
      Research.batch_for_date(date) ->
        {:ok, :batch_exists}

      match?(%{status: "skipped"}, Research.snapshot_for(date, "15:15")) ->
        {:ok, :non_trading_day}

      true ->
        create_manual_batch(date, 500)
    end
  end

  def ensure_final_pipeline(%{universe_snapshot_id: nil}),
    do: {:error, :missing_universe_snapshot}

  def ensure_final_pipeline(%{batch_type: "adhoc"} = batch) do
    counts = Research.item_counts(batch.id)

    if counts.total == 0 do
      case FanoutWorker.new(%{"batch_id" => batch.id}) |> Oban.insert() do
        {:ok, _job} -> {:ok, 1}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, 0}
    end
  end

  def ensure_final_pipeline(batch) do
    evidence =
      Enum.flat_map(@final_lanes, fn {slot, lane} ->
        case Research.evidence_run(batch.analysis_date, slot, lane) do
          %{status: status} when status in ["complete", "degraded", "failed"] ->
            []

          _ ->
            [
              {EvidenceWorker,
               %{
                 "snapshot_id" => batch.universe_snapshot_id,
                 "lane" => lane,
                 "slot" => slot
               }, slot}
            ]
        end
      end)

    counts = Research.item_counts(batch.id)

    fanout =
      if counts.total == 0,
        do: [{FanoutWorker, %{"batch_id" => batch.id}, "15:45"}],
        else: []

    jobs = evidence ++ fanout

    Enum.reduce_while(jobs, {:ok, length(jobs)}, fn {worker, args, slot}, acc ->
      opts = schedule_opts(batch.analysis_date, slot)

      case worker.new(args, opts) |> Oban.insert() do
        {:ok, _job} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def fanout(batch) do
    with {:ok, items} <- Research.ensure_items(batch) do
      _ = FullAnalysis.ensure_for_research_batch(batch)
      items = Enum.filter(items, &(&1.status in ["pending", "failed"]))

      results =
        Enum.map(items, fn item ->
          ResearchWorker.new(%{"item_id" => item.id}) |> Oban.insert()
        end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> {:ok, length(items)}
        error -> error
      end
    end
  end

  def retry(%{batch_type: "adhoc", status: "blocked", universe_snapshot_id: nil} = batch) do
    case enqueue_adhoc_universe(batch) do
      {:ok, _job} -> {:ok, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  # A frozen, blocked selection is immutable. Retrying it must not silently
  # recalculate a different historical universe or call the LLM again.
  def retry(%{batch_type: "adhoc", status: "blocked"}), do: {:ok, 0}

  def retry(batch) do
    items = Research.retryable_items(batch.id)

    results =
      case ensure_retry_pipeline(batch) do
        {:ok, _} -> []
        {:error, reason} -> [{:error, reason}]
      end

    results =
      Enum.map(items, fn item ->
        with :ok <- maybe_reset_rag(item),
             {:ok, _} <- ResearchWorker.new(%{"item_id" => item.id}) |> Oban.insert() do
          :ok
        end
      end) ++ results

    counts = Research.item_counts(batch.id)

    results =
      if counts.total == 0 or counts.ready == counts.total or counts.stale > 0 do
        results
      else
        case RagBatchWorker.new(%{"batch_id" => batch.id}) |> Oban.insert() do
          {:ok, _} -> results
          {:error, reason} -> [{:error, reason} | results]
        end
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, length(items)}
      {:error, _} = error -> error
    end
  end

  defp ensure_retry_pipeline(%{batch_type: "adhoc", universe_snapshot_id: nil} = batch) do
    case enqueue_adhoc_universe(batch) do
      {:ok, _job} -> {:ok, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_retry_pipeline(batch), do: ensure_final_pipeline(batch)

  defp maybe_reset_rag(%{rag_status: status, digest: digest} = item)
       when status == "failed" and not is_nil(digest) do
    case Research.reset_rag(item) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_reset_rag(_item), do: :ok

  defp schedule_opts(date, slot) do
    with {:ok, scheduled_at} <- Calendar.at_slot(date, slot),
         :lt <- DateTime.compare(DateTime.utc_now(), scheduled_at) do
      [scheduled_at: scheduled_at]
    else
      _ -> []
    end
  end

  defp enqueue_adhoc_universe(batch) do
    UniverseWorker.new(%{
      "analysis_date" => Date.to_iso8601(batch.analysis_date),
      "slot" => "adhoc-#{batch.id}",
      "limit" => batch.target_count,
      "frozen" => true,
      "batch_id" => batch.id,
      "batch_type" => "adhoc",
      "price_mode" => if(batch.research_mode == "historical", do: "historical", else: "live"),
      "cutoff" => DateTime.to_iso8601(batch.cutoff_at),
      "tickers" => batch.metadata["requested_tickers"]
    })
    |> Oban.insert()
  end

  defp maybe_enqueue_adhoc_universe(batch, :created), do: enqueue_adhoc_universe(batch)

  defp maybe_enqueue_adhoc_universe(
         %{universe_snapshot_id: nil, status: status} = batch,
         _disposition
       )
       when status not in ["completed", "blocked", "failed"],
       do: enqueue_adhoc_universe(batch)

  defp maybe_enqueue_adhoc_universe(_batch, _disposition), do: {:ok, nil}

  defp resolve_adhoc_request(:omitted, local_now, now),
    do: {:ok, live_request(DateTime.to_date(local_now), now, :omitted)}

  defp resolve_adhoc_request(value, local_now, now) when is_binary(value) do
    with {:ok, requested_date} <- Date.from_iso8601(value) do
      today = DateTime.to_date(local_now)

      case Date.compare(requested_date, today) do
        :gt ->
          {:error, :future_analysis_date}

        :eq ->
          {:ok, live_request(requested_date, now, requested_date)}

        :lt ->
          with {:ok, cutoff} <- Calendar.at_slot(requested_date, "15:00") do
            {:ok,
             %{
               analysis_date: requested_date,
               requested_date: requested_date,
               cutoff: cutoff,
               research_mode: "historical",
               cutoff_policy: "historical_15_00",
               evidence_policy: "archive_as_of_historical_cutoff",
               data_provenance: "historical_replay"
             }}
          end
      end
    else
      _ -> {:error, :invalid_analysis_date}
    end
  end

  defp resolve_adhoc_request(_value, _local_now, _now),
    do: {:error, :invalid_analysis_date}

  defp live_request(analysis_date, now, requested_date) do
    %{
      analysis_date: analysis_date,
      requested_date: requested_date,
      cutoff: DateTime.truncate(now, :microsecond),
      research_mode: "live",
      cutoff_policy: "request_time",
      evidence_policy: "archive_as_of_request_cutoff",
      data_provenance: "request_cutoff"
    }
  end

  defp normalize_adhoc_tickers(tickers) when is_list(tickers) do
    cond do
      length(tickers) not in 1..@max_adhoc_tickers ->
        {:error, :invalid_ticker_count}

      not Enum.all?(tickers, &is_binary/1) ->
        {:error, :invalid_ticker}

      true ->
        validate_normalized_tickers(Enum.map(tickers, &(String.trim(&1) |> String.upcase())))
    end
  end

  defp normalize_adhoc_tickers(_), do: {:error, :invalid_tickers}

  defp validate_normalized_tickers(normalized) do
    cond do
      length(normalized) not in 1..@max_adhoc_tickers ->
        {:error, :invalid_ticker_count}

      Enum.any?(normalized, &(not Regex.match?(@ticker, &1))) ->
        {:error, :invalid_ticker}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {:error, :duplicate_ticker}

      true ->
        {:ok, Enum.sort(normalized)}
    end
  end

  defp hash_idempotency_key(value) when is_binary(value) do
    normalized = String.trim(value)

    if Regex.match?(@idempotency_key, normalized) do
      {:ok, sha256(normalized)}
    else
      {:error, :invalid_idempotency_key}
    end
  end

  defp hash_idempotency_key(_), do: {:error, :missing_idempotency_key}

  defp request_fingerprint(tickers, :omitted),
    do: sha256(Jason.encode!(%{"schema_version" => 1, "tickers" => tickers}))

  defp request_fingerprint(tickers, %Date{} = analysis_date) do
    sha256(
      Jason.encode!(%{
        "schema_version" => 2,
        "tickers" => tickers,
        "analysis_date" => Date.to_iso8601(analysis_date)
      })
    )
  end

  defp request_fingerprint(tickers, requested_date, :omitted, "digest"),
    do: request_fingerprint(tickers, requested_date)

  defp request_fingerprint(tickers, requested_date, _provided, depth) do
    pipeline_version = if(depth == "full", do: "gx_full_v1", else: "daily_digest_v1")

    payload = %{
      "schema_version" => 3,
      "tickers" => tickers,
      "analysis_depth" => depth,
      "pipeline_version" => pipeline_version
    }

    payload =
      if match?(%Date{}, requested_date),
        do: Map.put(payload, "analysis_date", Date.to_iso8601(requested_date)),
        else: payload

    sha256(Jason.encode!(payload))
  end

  defp normalize_analysis_depth(:omitted), do: {:ok, "digest"}
  defp normalize_analysis_depth(value) when value in ["digest", "full"], do: {:ok, value}
  defp normalize_analysis_depth(_), do: {:error, :invalid_analysis_depth}

  defp maybe_start_adhoc_full(%{analysis_depth: "digest"}), do: :ok

  defp maybe_start_adhoc_full(batch) do
    with {:ok, _full_batch} <- FullAnalysis.ensure_for_research_batch(batch) do
      batch.id
      |> Research.list_items(limit: 100)
      |> Enum.each(&FullAnalysis.maybe_schedule_item/1)

      :ok
    end
  end

  defp ticker_set_fingerprint(tickers),
    do: sha256(Jason.encode!(%{"schema_version" => 1, "tickers" => tickers}))

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
