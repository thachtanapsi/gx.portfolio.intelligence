defmodule GxPortfolioIntelligence.Research do
  @moduledoc "Idempotent persistence boundary for daily research orchestration."

  import Ecto.Query

  alias GxPortfolioIntelligence.Repo

  alias GxPortfolioIntelligence.Schemas.{
    EvidenceRun,
    ResearchBatch,
    ResearchBatchRequestKey,
    ResearchItem
  }

  alias GxPortfolioIntelligence.Schemas.{UniverseMember, UniverseSnapshot}

  @universe_ticker ~r/^[A-Z0-9]{1,16}$/
  @universe_exchanges ~w(HOSE HNX UPCOM)

  def create_batch(attrs) do
    attrs =
      attrs
      |> Map.put_new(:batch_type, "eod")
      |> Map.put_new(:research_mode, "eod")
      |> Map.put_new(
        :analysis_depth,
        if(GxPortfolioIntelligence.FullAnalysis.full_enabled?(), do: "full", else: "digest")
      )
      |> Map.put_new(:source, "tradingagents_daily_research")
      |> Map.put_new(
        :target_count,
        Application.get_env(:gx_portfolio_intelligence, :target_count, 500)
      )
      |> Map.put_new(
        :sla_ready_count,
        Application.get_env(:gx_portfolio_intelligence, :sla_ready_count, 490)
      )

    changeset = ResearchBatch.changeset(%ResearchBatch{}, attrs)

    case Repo.insert(changeset) do
      {:ok, batch} ->
        {:ok, batch}

      {:error, failed} = error ->
        if unique_error?(failed, :analysis_date) do
          {:ok,
           Repo.get_by!(ResearchBatch,
             analysis_date: Ecto.Changeset.get_field(changeset, :analysis_date),
             batch_type: "eod"
           )}
        else
          error
        end
    end
  end

  def create_adhoc_batch(attrs) do
    key_hash = Map.get(attrs, :idempotency_key_hash) || Map.get(attrs, "idempotency_key_hash")
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    request_fingerprint = metadata["request_fingerprint"]

    resolve_adhoc_batch(attrs, key_hash, request_fingerprint)
  end

  def resolve_adhoc_batch(attrs, key_hash, request_fingerprint)
      when is_binary(key_hash) and is_binary(request_fingerprint) do
    attrs =
      attrs
      |> Map.put(:batch_type, "adhoc")
      |> Map.put_new(:research_mode, "live")
      |> Map.put(:source, "tradingagents_adhoc_research")
      |> Map.put(:sla_status, "not_applicable")
      |> Map.put(:idempotency_key_hash, key_hash)

    mode = Map.get(attrs, :research_mode) || Map.get(attrs, "research_mode") || "live"
    date = Map.get(attrs, :analysis_date) || Map.get(attrs, "analysis_date")

    Repo.transaction(fn ->
      # Ad-hoc creation volume is low. One short transaction-level lock keeps
      # idempotency-key and canonical-date resolution in a single total order,
      # avoiding cross-key/date deadlocks while never covering Oban or network IO.
      advisory_lock!("create")

      case request_key_batch(key_hash) do
        %ResearchBatchRequestKey{} = request_key ->
          replay_request_key!(request_key, request_fingerprint)

        nil ->
          case legacy_key_batch(key_hash) do
            %ResearchBatch{} = existing ->
              replay_legacy_key!(existing, key_hash, request_fingerprint)

            nil ->
              resolve_new_adhoc!(attrs, key_hash, request_fingerprint, mode, date)
          end
      end
    end)
    |> case do
      {:ok, {batch, disposition}} -> {:ok, batch, disposition}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_adhoc_batch(_attrs, _key_hash, _request_fingerprint),
    do: {:error, :invalid_idempotency_contract}

  def block_batch(%ResearchBatch{} = batch, error) do
    batch
    |> ResearchBatch.changeset(%{status: "blocked", last_error: error_text(error)})
    |> Repo.update()
  end

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> options[:constraint] == :unique
      _ -> false
    end)
  end

  defp advisory_lock!(key) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
           "gx_pi_adhoc:" <> key
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_key_batch(key_hash) do
    Repo.one(
      from k in ResearchBatchRequestKey,
        where: k.idempotency_key_hash == ^key_hash,
        preload: :research_batch
    )
  end

  defp legacy_key_batch(key_hash),
    do: Repo.get_by(ResearchBatch, idempotency_key_hash: key_hash)

  defp replay_request_key!(request_key, request_fingerprint) do
    if request_key.request_fingerprint == request_fingerprint do
      {request_key.research_batch, :replayed}
    else
      Repo.rollback(:idempotency_conflict)
    end
  end

  defp replay_legacy_key!(batch, key_hash, request_fingerprint) do
    if batch.metadata["request_fingerprint"] == request_fingerprint do
      insert_request_key!(batch.id, key_hash, request_fingerprint)
      {batch, :replayed}
    else
      Repo.rollback(:idempotency_conflict)
    end
  end

  defp resolve_new_adhoc!(attrs, key_hash, request_fingerprint, "historical", date) do
    existing =
      Repo.one(
        from b in ResearchBatch,
          where:
            b.batch_type == "adhoc" and b.research_mode == "historical" and
              b.analysis_date == ^date,
          lock: "FOR UPDATE"
      )

    case existing do
      nil -> insert_adhoc_with_key!(attrs, key_hash, request_fingerprint)
      batch -> reuse_historical!(batch, attrs, key_hash, request_fingerprint)
    end
  end

  defp resolve_new_adhoc!(attrs, key_hash, request_fingerprint, _mode, _date),
    do: insert_adhoc_with_key!(attrs, key_hash, request_fingerprint)

  defp insert_adhoc_with_key!(attrs, key_hash, request_fingerprint) do
    case %ResearchBatch{} |> ResearchBatch.changeset(attrs) |> Repo.insert() do
      {:ok, batch} ->
        insert_request_key!(batch.id, key_hash, request_fingerprint)
        {batch, :created}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp reuse_historical!(batch, attrs, key_hash, request_fingerprint) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    cutoff = Map.get(attrs, :cutoff_at) || Map.get(attrs, "cutoff_at")

    requested_depth =
      Map.get(attrs, :analysis_depth) || Map.get(attrs, "analysis_depth") || "digest"

    if batch.metadata["requested_tickers"] == metadata["requested_tickers"] and
         batch.metadata["ticker_set_fingerprint"] == metadata["ticker_set_fingerprint"] and
         DateTime.compare(batch.cutoff_at, cutoff) == :eq do
      batch = maybe_upgrade_analysis_depth!(batch, requested_depth)
      insert_request_key!(batch.id, key_hash, request_fingerprint)
      {batch, :canonical_replayed}
    else
      Repo.rollback(:historical_batch_conflict)
    end
  end

  defp maybe_upgrade_analysis_depth!(%ResearchBatch{analysis_depth: "digest"} = batch, "full") do
    batch
    |> ResearchBatch.changeset(%{
      analysis_depth: "full",
      metadata: Map.put(batch.metadata, "analysis_depth", "full")
    })
    |> Repo.update!()
  end

  defp maybe_upgrade_analysis_depth!(batch, _requested_depth), do: batch

  defp insert_request_key!(batch_id, key_hash, request_fingerprint) do
    changeset =
      ResearchBatchRequestKey.changeset(%ResearchBatchRequestKey{}, %{
        research_batch_id: batch_id,
        idempotency_key_hash: key_hash,
        request_fingerprint: request_fingerprint
      })

    case Repo.insert(changeset) do
      {:ok, request_key} -> request_key
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  def get_batch(id) when is_integer(id), do: Repo.get(ResearchBatch, id)

  def get_batch(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> get_batch(value)
      _ -> nil
    end
  end

  def get_batch!(id), do: Repo.get!(ResearchBatch, id)

  def latest_batch do
    Repo.one(
      from b in ResearchBatch,
        where: b.batch_type == "eod",
        order_by: [desc: b.analysis_date],
        limit: 1
    )
  end

  def batch_for_date(date),
    do: Repo.get_by(ResearchBatch, analysis_date: date, batch_type: "eod")

  def list_batches(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(100)
    date = Keyword.get(opts, :analysis_date)
    batch_type = Keyword.get(opts, :batch_type)

    query =
      from b in ResearchBatch,
        order_by: [desc: b.inserted_at],
        limit: ^limit

    query = if date, do: from(b in query, where: b.analysis_date == ^date), else: query
    query = if batch_type, do: from(b in query, where: b.batch_type == ^batch_type), else: query
    Repo.all(query)
  end

  def list_recoverable_batches do
    Repo.all(
      from b in ResearchBatch,
        where:
          (b.batch_type == "adhoc" and b.status not in ["completed", "blocked"]) or
            (b.batch_type == "eod" and
               (b.status != "completed" or b.sla_status == "pending" or
                  (b.sla_status == "missed" and is_nil(b.sla_recovered_at)))),
        order_by: [desc: b.inserted_at]
    )
  end

  def list_items(batch_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(100)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    status = Keyword.get(opts, :status)
    ticker = Keyword.get(opts, :ticker)

    query =
      from i in ResearchItem,
        where: i.research_batch_id == ^batch_id,
        order_by: [asc: i.liquidity_rank],
        limit: ^limit,
        offset: ^offset

    query = if status, do: from(i in query, where: i.status == ^status), else: query

    query =
      if ticker, do: from(i in query, where: i.ticker == ^String.upcase(ticker)), else: query

    Repo.all(query)
  end

  def list_snapshots(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 30) |> min(100)
    date = Keyword.get(opts, :analysis_date)

    query =
      from s in UniverseSnapshot, order_by: [desc: s.analysis_date, desc: s.slot], limit: ^limit

    query = if date, do: from(s in query, where: s.analysis_date == ^date), else: query
    Repo.all(query)
  end

  def snapshot_for(date, slot), do: Repo.get_by(UniverseSnapshot, analysis_date: date, slot: slot)

  def final_snapshot(date) do
    Repo.one(
      from s in UniverseSnapshot,
        where: s.analysis_date == ^date and s.frozen == true and s.slot == "15:15",
        order_by: [desc: s.inserted_at],
        limit: 1
    )
  end

  def final_evidence_ready?(date) do
    required =
      MapSet.new([
        {"15:20", "social"},
        {"15:20", "media"},
        {"15:30", "macro"},
        {"15:30", "media"}
      ])

    terminal =
      Repo.all(
        from r in EvidenceRun,
          where:
            r.analysis_date == ^date and
              r.status in ["complete", "degraded", "failed"] and
              r.slot in ["15:20", "15:30"],
          select: {r.slot, r.lane}
      )
      |> MapSet.new()

    MapSet.subset?(required, terminal)
  end

  def evidence_run(date, slot, lane) do
    Repo.get_by(EvidenceRun, analysis_date: date, slot: slot, lane: lane)
  end

  def persist_universe(result, frozen?) when is_map(result) do
    with {:ok, attrs, members} <- validate_universe(result, frozen?) do
      Repo.transaction(fn ->
        existing =
          Repo.one(
            from s in UniverseSnapshot,
              where: s.analysis_date == ^attrs.analysis_date and s.slot == ^attrs.slot,
              lock: "FOR UPDATE"
          )

        snapshot = upsert_snapshot!(existing, attrs)

        unless existing && existing.fingerprint == attrs.fingerprint do
          Repo.delete_all(from m in UniverseMember, where: m.universe_snapshot_id == ^snapshot.id)
          insert_members!(snapshot.id, members)
        end

        Repo.preload(snapshot, :members, force: true)
      end)
    end
  end

  def bind_snapshot_to_batch(%ResearchBatch{} = batch, %UniverseSnapshot{} = snapshot) do
    batch
    |> ResearchBatch.changeset(%{
      universe_snapshot_id: snapshot.id,
      status: if(snapshot.member_count < batch.target_count, do: "degraded", else: "collecting"),
      started_at: batch.started_at || DateTime.utc_now()
    })
    |> Repo.update()
  end

  def ensure_items(%ResearchBatch{universe_snapshot_id: nil}),
    do: {:error, :missing_universe_snapshot}

  def ensure_items(%ResearchBatch{} = batch) do
    now = DateTime.utc_now()

    members =
      Repo.all(
        from m in UniverseMember,
          where: m.universe_snapshot_id == ^batch.universe_snapshot_id,
          order_by: [asc: m.rank],
          limit: ^batch.target_count,
          select: %{ticker: m.ticker, liquidity_rank: m.rank}
      )

    rows =
      Enum.map(members, fn member ->
        Map.merge(member, %{
          research_batch_id: batch.id,
          status: "pending",
          llm_status: "pending",
          rag_status: "pending",
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, _} =
      Repo.insert_all(ResearchItem, rows,
        on_conflict: :nothing,
        conflict_target: [:research_batch_id, :ticker]
      )

    {:ok,
     Repo.all(
       from i in ResearchItem, where: i.research_batch_id == ^batch.id, order_by: i.liquidity_rank
     )}
  end

  def create_evidence_run(attrs) do
    key = "#{attrs.analysis_date}:#{attrs.slot}:#{attrs.lane}"
    attrs = Map.put(attrs, :idempotency_key, key)

    case %EvidenceRun{} |> EvidenceRun.changeset(attrs) |> Repo.insert() do
      {:ok, run} -> {:ok, run}
      {:error, _changeset} -> {:ok, Repo.get_by!(EvidenceRun, idempotency_key: key)}
    end
  end

  def mark_evidence_running(%EvidenceRun{} = run) do
    run
    |> EvidenceRun.changeset(%{
      status: "running",
      started_at: run.started_at || DateTime.utc_now(),
      last_error: nil
    })
    |> Repo.update()
  end

  def complete_evidence(%EvidenceRun{} = run, result) do
    failed = result["failed_count"] || 0
    reported_status = result["status"]

    status =
      cond do
        reported_status == "complete" and failed == 0 -> "complete"
        reported_status == "failed" -> "failed"
        true -> "degraded"
      end

    run
    |> EvidenceRun.changeset(%{
      status: status,
      target_count: result["target_count"] || run.target_count,
      processed_count: result["processed_count"] || 0,
      succeeded_count: result["succeeded_count"] || 0,
      failed_count: failed,
      watermark: sanitize_watermark(result["watermark"]),
      completed_at: DateTime.utc_now(),
      last_error: nil
    })
    |> Repo.update()
  end

  def schedule_evidence_retry(%EvidenceRun{} = run) do
    run
    |> EvidenceRun.changeset(%{status: "pending", completed_at: nil})
    |> Repo.update()
  end

  def record_evidence_retry(%EvidenceRun{} = run, result, error \\ nil) do
    run
    |> EvidenceRun.changeset(%{
      status: "pending",
      target_count: result["target_count"] || run.target_count,
      processed_count: result["processed_count"] || 0,
      succeeded_count: result["succeeded_count"] || 0,
      failed_count: result["failed_count"] || 0,
      watermark: sanitize_watermark(result["watermark"]),
      completed_at: nil,
      last_error: if(is_nil(error), do: nil, else: error_text(error))
    })
    |> Repo.update()
  end

  def record_evidence_error_retry(%EvidenceRun{} = run, error) do
    run
    |> EvidenceRun.changeset(%{
      status: "pending",
      completed_at: nil,
      last_error: error_text(error)
    })
    |> Repo.update()
  end

  def fail_evidence(%EvidenceRun{} = run, error) do
    run
    |> EvidenceRun.changeset(%{status: "failed", last_error: error_text(error)})
    |> Repo.update()
  end

  def claim_item(item_id) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(i in ResearchItem,
          where: i.id == ^item_id and i.status in ["pending", "running", "failed"]
        ),
        set: [status: "running", started_at: now, last_error: nil, updated_at: now]
      )

    if count == 1,
      do: {:ok, Repo.get!(ResearchItem, item_id)},
      else: {:already_complete, Repo.get!(ResearchItem, item_id)}
  end

  def complete_item(%ResearchItem{} = item, result, digest, source_updated_at) do
    status =
      if(result["status"] == "complete" and digest["status"] == "complete",
        do: "complete",
        else: "partial"
      )

    llm_status = normalize_llm_status(result["llm_status"], status)

    item
    |> ResearchItem.changeset(%{
      status: status,
      llm_status: llm_status,
      rag_status: "pending",
      identity_hash: result["identity_hash"],
      digest_hash: result["digest_hash"],
      artifact_path: result["artifact_path"],
      rag_envelope_path: result["rag_envelope_path"],
      digest: digest,
      source_updated_at: source_updated_at,
      completed_at: DateTime.utc_now(),
      last_error: nil
    })
    |> Repo.update()
  end

  def fail_item(%ResearchItem{} = item, error) do
    Repo.update_all(
      from(i in ResearchItem, where: i.id == ^item.id and i.status == "running"),
      set: [status: "failed", last_error: error_text(error), updated_at: DateTime.utc_now()]
    )

    {:ok, Repo.get!(ResearchItem, item.id)}
  end

  def claim_rag_items(batch_id, limit \\ 50) do
    Repo.transaction(fn ->
      items =
        Repo.all(
          from i in ResearchItem,
            where:
              i.research_batch_id == ^batch_id and i.status in ["complete", "partial"] and
                i.rag_status in ["pending", "failed"],
            order_by: [asc: i.liquidity_rank],
            limit: ^min(limit, 50),
            lock: "FOR UPDATE SKIP LOCKED"
        )

      ids = Enum.map(items, & &1.id)

      if ids != [] do
        Repo.update_all(from(i in ResearchItem, where: i.id in ^ids),
          set: [rag_status: "queued", updated_at: DateTime.utc_now()]
        )
      end

      Enum.map(items, &%{&1 | rag_status: "queued"})
    end)
  end

  def mark_rag_submitted(items, actions) do
    Enum.each(items, fn item ->
      action = Map.get(actions, item.ticker, "accepted")
      stale? = action == "stale"

      Repo.update_all(from(i in ResearchItem, where: i.id == ^item.id),
        set: [
          rag_status: if(stale?, do: "stale", else: "submitted"),
          rag_ready_at: nil,
          last_error: if(stale?, do: "rag_stale_source", else: nil),
          updated_at: DateTime.utc_now()
        ]
      )
    end)

    refresh_batch_counts(hd(items).research_batch_id)
  end

  def sync_rag_statuses(batch_id, remote_items) when is_list(remote_items) do
    now = DateTime.utc_now()

    remote_tickers =
      remote_items
      |> Enum.map(&(&1["ticker"] |> to_string() |> String.upcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Enum.each(remote_items, fn remote ->
      ticker = remote["ticker"] |> to_string() |> String.upcase()

      current = Repo.get_by(ResearchItem, research_batch_id: batch_id, ticker: ticker)

      {rag_status, ready_at, last_error} =
        case {current && current.rag_status, remote["status"]} do
          {"stale", _remote_status} ->
            {"stale", nil, "rag_stale_source"}

          {_current_status, "ready"} ->
            remote_ready_at = remote_ready_at(remote["updated_at"], now)
            {"ready", earliest_datetime(current && current.rag_ready_at, remote_ready_at), nil}

          {_current_status, "failed"} ->
            {"failed", nil, "rag_index_failed"}

          {_current_status, "indexing"} ->
            {"indexing", nil, nil}

          {_current_status, _remote_status} ->
            {"submitted", nil, if(current, do: current.last_error, else: nil)}
        end

      Repo.update_all(
        from(i in ResearchItem, where: i.research_batch_id == ^batch_id and i.ticker == ^ticker),
        set: [
          rag_status: rag_status,
          rag_ready_at: ready_at,
          last_error: last_error,
          updated_at: now
        ]
      )
    end)

    # A worker may die around POST and leave a queued/submitted row that never
    # became durable remotely. Reclaim only expired leases omitted from the
    # complete paginated snapshot. A present pending/indexing document refreshes
    # updated_at above and is never stolen while RAG is still processing it.
    lease_seconds = Application.get_env(:gx_portfolio_intelligence, :rag_claim_lease_seconds, 120)
    stale_before = DateTime.add(now, -lease_seconds, :second)

    missing_query =
      from i in ResearchItem,
        where:
          i.research_batch_id == ^batch_id and
            i.status in ["complete", "partial"] and
            i.rag_status in ["queued", "submitted", "indexing"] and
            i.updated_at <= ^stale_before

    missing_query =
      if remote_tickers == [] do
        missing_query
      else
        from i in missing_query, where: i.ticker not in ^remote_tickers
      end

    Repo.update_all(missing_query,
      set: [rag_status: "failed", last_error: "rag_document_missing", updated_at: now]
    )

    refresh_batch_counts(batch_id)
  end

  def release_rag_items(items, error) do
    ids = Enum.map(items, & &1.id)

    if ids != [] do
      Repo.update_all(from(i in ResearchItem, where: i.id in ^ids),
        set: [rag_status: "failed", last_error: error_text(error), updated_at: DateTime.utc_now()]
      )
    end

    :ok
  end

  def refresh_batch_counts(batch_id) do
    counts =
      Repo.one(
        from i in ResearchItem,
          where: i.research_batch_id == ^batch_id,
          select: %{
            total: count(i.id),
            completed: filter(count(i.id), i.status in ["complete", "partial"]),
            failed: filter(count(i.id), i.status == "failed"),
            rag_ready: filter(count(i.id), i.rag_status == "ready")
          }
      )

    batch = Repo.get!(ResearchBatch, batch_id)

    status =
      cond do
        counts.rag_ready >= batch.target_count -> "completed"
        counts.total < batch.target_count -> "degraded"
        counts.completed > 0 -> "indexing"
        batch.status == "degraded" -> "degraded"
        true -> "researching"
      end

    completed_at =
      cond do
        status == "completed" and not is_nil(batch.completed_at) -> batch.completed_at
        status == "completed" -> DateTime.utc_now()
        true -> nil
      end

    batch
    |> ResearchBatch.changeset(%{
      completed_count: counts.completed,
      failed_count: counts.failed,
      rag_ready_count: counts.rag_ready,
      status: status,
      completed_at: completed_at
    })
    |> Repo.update()
  end

  def set_sla(%ResearchBatch{} = batch, status) when status in ["met", "missed"] do
    batch |> ResearchBatch.changeset(%{sla_status: status}) |> Repo.update()
  end

  def retryable_items(batch_id) do
    Repo.all(
      from i in ResearchItem,
        where:
          i.research_batch_id == ^batch_id and
            (i.status in ["pending", "running", "failed"] or i.rag_status == "failed"),
        order_by: i.liquidity_rank
    )
  end

  def item_counts(batch_id) do
    Repo.one(
      from i in ResearchItem,
        where: i.research_batch_id == ^batch_id,
        select: %{
          total: count(i.id),
          pending_rag: filter(count(i.id), i.rag_status in ["pending", "failed"]),
          submitted: filter(count(i.id), i.rag_status in ["queued", "submitted", "indexing"]),
          ready: filter(count(i.id), i.rag_status == "ready"),
          stale: filter(count(i.id), i.rag_status == "stale")
        }
    )
  end

  def rag_ready_count_at(batch_id, %DateTime{} = deadline) do
    Repo.aggregate(
      from(i in ResearchItem,
        where:
          i.research_batch_id == ^batch_id and i.rag_status == "ready" and
            not is_nil(i.rag_ready_at) and i.rag_ready_at <= ^deadline
      ),
      :count
    )
  end

  def mark_sla_recovered(%ResearchBatch{} = batch) do
    batch
    |> ResearchBatch.changeset(%{sla_recovered_at: batch.sla_recovered_at || DateTime.utc_now()})
    |> Repo.update()
  end

  def reset_rag(%ResearchItem{} = item) do
    item |> ResearchItem.changeset(%{rag_status: "pending", last_error: nil}) |> Repo.update()
  end

  defp validate_universe(result, frozen?) do
    with {:ok, date} <- Date.from_iso8601(result["analysis_date"] || ""),
         {:ok, cutoff, _} <- DateTime.from_iso8601(result["cutoff"] || ""),
         slot when is_binary(slot) <- result["slot"],
         fingerprint when is_binary(fingerprint) <-
           result["fingerprint"],
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, fingerprint),
         members when is_list(members) <- result["members"],
         target when is_integer(target) and target in 1..600 <- result["target_count"],
         :ok <- validate_members(members, target, result["status"]) do
      status =
        if result["status"] in ["skipped", "non_trading_day"],
          do: "skipped",
          else: if(length(members) < target, do: "degraded", else: "complete")

      {:ok,
       %{
         analysis_date: date,
         slot: slot,
         cutoff_at: cutoff,
         member_limit: target,
         member_count: length(members),
         status: status,
         frozen: frozen?,
         fingerprint: fingerprint,
         artifact_path: result["artifact_path"],
         metadata:
           %{"schema_version" => result["schema_version"]}
           |> maybe_put_metadata("price_mode", result["price_mode"] || "live")
           |> maybe_put_metadata(
             "selection",
             if(result["requested_tickers"], do: "requested_tickers", else: result["selection"])
           )
           |> maybe_put_metadata("requested_tickers", result["requested_tickers"])
           |> maybe_put_metadata("selection_fingerprint", result["selection_fingerprint"])
           |> maybe_put_metadata("missing_tickers", result["missing_tickers"])
       }, members}
    else
      _ -> {:error, :invalid_universe_contract}
    end
  end

  defp validate_members([], _target, status) when status in ["skipped", "non_trading_day"],
    do: :ok

  defp validate_members([], _target, "degraded"), do: :ok

  defp validate_members(members, target, _status) do
    tickers =
      Enum.map(members, fn member ->
        ticker = member["ticker"]
        if is_binary(ticker), do: String.upcase(ticker), else: ""
      end)

    ranks = Enum.map(members, & &1["rank"])

    valid =
      length(members) <= target and
        length(Enum.uniq(tickers)) == length(tickers) and
        ranks == Enum.to_list(1..length(ranks)) and
        Enum.all?(members, &valid_member?/1)

    if valid, do: :ok, else: {:error, :invalid_universe_members}
  end

  defp valid_member?(member) when is_map(member) do
    allowed = ~w(ticker exchange adtv20 adv20 rank aliases)
    aliases = member["aliases"] || []

    Enum.all?(Map.keys(member), &(&1 in allowed)) and
      is_binary(member["ticker"]) and
      member["ticker"] == String.upcase(member["ticker"]) and
      Regex.match?(@universe_ticker, String.upcase(member["ticker"])) and
      member["exchange"] in @universe_exchanges and
      valid_decimal?(member["adtv20"]) and valid_decimal?(member["adv20"]) and
      is_list(aliases) and length(aliases) <= 20 and
      Enum.all?(aliases, &(is_binary(&1) and String.length(&1) in 1..200))
  end

  defp valid_member?(_), do: false

  defp upsert_snapshot!(%UniverseSnapshot{frozen: true} = snapshot, attrs) do
    if snapshot.fingerprint == attrs.fingerprint do
      snapshot
    else
      Repo.rollback(:frozen_snapshot_conflict)
    end
  end

  defp upsert_snapshot!(nil, attrs) do
    %UniverseSnapshot{} |> UniverseSnapshot.changeset(attrs) |> Repo.insert!()
  end

  defp upsert_snapshot!(snapshot, attrs) do
    snapshot |> UniverseSnapshot.changeset(attrs) |> Repo.update!()
  end

  defp insert_members!(snapshot_id, members) do
    now = DateTime.utc_now()

    rows =
      Enum.map(members, fn member ->
        %{
          universe_snapshot_id: snapshot_id,
          ticker: String.upcase(member["ticker"]),
          exchange: member["exchange"],
          rank: member["rank"],
          adtv20: decimal_value!(member["adtv20"]),
          adv20: decimal_value!(member["adv20"]),
          metadata: %{"aliases" => Enum.uniq(member["aliases"] || [])},
          inserted_at: now
        }
      end)

    case Repo.insert_all(UniverseMember, rows) do
      {count, _} when count == length(rows) -> :ok
      _ -> Repo.rollback(:universe_member_insert_failed)
    end
  end

  defp sanitize_watermark(value) when is_map(value) do
    value
    |> Map.take(~w(cursor since until count cutoff tickers_fingerprint))
    |> Map.new(fn {key, item} ->
      {key, if(is_binary(item) or is_number(item), do: item, else: inspect(item, limit: 10))}
    end)
  end

  defp sanitize_watermark(_), do: %{}

  defp normalize_llm_status(value, _status)
       when value in ["complete", "partial", "failed", "skipped"],
       do: value

  defp normalize_llm_status(_, status), do: status

  defp remote_ready_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} ->
        if DateTime.compare(parsed, now) == :gt, do: now, else: parsed

      _ ->
        now
    end
  end

  defp remote_ready_at(_value, now), do: now

  defp earliest_datetime(nil, second), do: second
  defp earliest_datetime(first, nil), do: first

  defp earliest_datetime(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp valid_decimal?(value) do
    case decimal_value(value) do
      {:ok, %Decimal{} = decimal} -> Decimal.compare(decimal, Decimal.new(0)) in [:eq, :gt]
      _ -> false
    end
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp decimal_value!(value) do
    case decimal_value(value) do
      {:ok, decimal} -> decimal
      :error -> raise ArgumentError, "invalid universe decimal"
    end
  end

  defp decimal_value(%Decimal{} = value), do: {:ok, value}
  defp decimal_value(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal_value(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  defp decimal_value(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal_value(_), do: :error

  def error_text(error), do: GxPortfolioIntelligence.SafeError.code(error)
end
