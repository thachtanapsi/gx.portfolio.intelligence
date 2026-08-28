defmodule GxPortfolioIntelligence.FullAnalysis do
  @moduledoc "Durable, best-effort orchestration state for trend and full analysis."

  import Ecto.Query

  alias GxPortfolioIntelligence.{Alerts, Repo, SafeError}

  alias GxPortfolioIntelligence.Schemas.{
    FullAnalysisBatch,
    FullAnalysisItem,
    FullAnalysisRestartKey,
    ResearchBatch,
    ResearchItem,
    ResearchStageRun,
    TrendMember,
    TrendSnapshot,
    UniverseSnapshot
  }

  alias GxPortfolioIntelligence.Workers.{FullAnalysisWorker, FullPromotionWorker}

  @stages ~w(market sentiment news fundamentals research trader risk)
  @trend_keys ~w(schema_version analysis_date cutoff previous_cutoff slot universe_fingerprint weights status target_count scored_count fingerprint members warnings)
  @trend_member_keys ~w(ticker liquidity_rank adtv20 adv20 market_core_available volume_ratio daily_move_abs_pct momentum20_abs_pct social_attention_velocity media_event_velocity coverage trend_score)
  @trend_fingerprint_member_decimals ~w(adtv20 adv20 volume_ratio daily_move_abs_pct momentum20_abs_pct social_attention_velocity media_event_velocity trend_score)
  @warning ~r/^[a-z][a-z0-9_:-]{0,127}$/
  @sha256 ~r/^[0-9a-f]{64}$/
  @idempotency_key ~r/^[A-Za-z0-9._:-]{8,128}$/

  def stages, do: @stages

  def trend_weights do
    Application.get_env(:gx_portfolio_intelligence, :trend_weights, %{
      "volume_ratio" => 30,
      "daily_move_abs" => 25,
      "momentum20_abs" => 15,
      "social_attention" => 15,
      "media_event" => 15
    })
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  def selection_limit,
    do: Application.get_env(:gx_portfolio_intelligence, :full_analysis_limit, 5)

  def backlog_warning_threshold,
    do:
      Application.get_env(
        :gx_portfolio_intelligence,
        :full_analysis_backlog_warning_threshold,
        20
      )

  def pinned_tickers do
    Application.get_env(:gx_portfolio_intelligence, :full_analysis_pinned_tickers, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def trend_fingerprint(result) when is_map(result) do
    with {:ok, normalized} <- normalize_trend_fingerprint_payload(result) do
      normalized
      |> canonical_json()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  def full_enabled?,
    do: Application.get_env(:gx_portfolio_intelligence, :full_analysis_enabled, false)

  def trend_enabled?,
    do: Application.get_env(:gx_portfolio_intelligence, :trend_enabled, false) or full_enabled?()

  def readiness_issues do
    limit = selection_limit()
    pinned = pinned_tickers()

    cond do
      not full_enabled?() -> []
      not is_integer(limit) or limit not in 1..500 -> ["invalid_full_analysis_limit"]
      length(pinned) > limit -> ["full_analysis_pinned_count_exceeds_limit"]
      true -> []
    end
  end

  def persist_trend(result, %UniverseSnapshot{} = universe, opts) when is_map(result) do
    with {:ok, attrs, members} <- validate_trend(result, universe, opts),
         {selected, selection_warnings} <- select_members(members, opts[:frozen] == true),
         attrs <-
           attrs
           |> Map.put(:selected_count, length(selected))
           |> Map.update!(:warnings, &Enum.uniq(&1 ++ selection_warnings)),
         {:ok, trend} <- persist_trend_transaction(attrs, members, selected) do
      maybe_alert_trend_warnings(trend)

      if trend.frozen do
        case Repo.get_by(ResearchBatch, universe_snapshot_id: universe.id) do
          nil -> :ok
          batch -> ensure_for_research_batch(batch, trend)
        end
      end

      {:ok, trend}
    end
  end

  def persist_trend(_, _, _), do: {:error, :invalid_trend_contract}

  def get_trend_snapshot(id) when is_integer(id), do: Repo.get(TrendSnapshot, id)

  def get_trend_snapshot(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> get_trend_snapshot(parsed)
      _ -> nil
    end
  end

  def list_trend_snapshots(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 30) |> min(100)
    date = Keyword.get(opts, :analysis_date)

    query =
      from t in TrendSnapshot,
        order_by: [desc: t.analysis_date, desc: t.cutoff_at],
        limit: ^limit

    query = if date, do: from(t in query, where: t.analysis_date == ^date), else: query
    Repo.all(query)
  end

  def latest_final_trend(date) do
    Repo.one(
      from t in TrendSnapshot,
        where: t.analysis_date == ^date and t.frozen == true,
        order_by: [desc: t.cutoff_at],
        limit: 1
    )
  end

  def previous_cutoff(%UniverseSnapshot{} = universe) do
    Repo.one(
      from u in UniverseSnapshot,
        where:
          (u.analysis_date < ^universe.analysis_date or
             (u.analysis_date == ^universe.analysis_date and u.cutoff_at < ^universe.cutoff_at)) and
            u.status in ["complete", "degraded"],
        order_by: [desc: u.analysis_date, desc: u.cutoff_at],
        limit: 1,
        select: u.cutoff_at
    )
  end

  def ensure_for_research_batch(batch_or_id, trend \\ nil)

  def ensure_for_research_batch(batch_id, trend) when is_integer(batch_id),
    do: ensure_for_research_batch(Repo.get!(ResearchBatch, batch_id), trend)

  def ensure_for_research_batch(
        %ResearchBatch{batch_type: "adhoc", analysis_depth: "digest"},
        _trend
      ),
      do: {:ok, nil}

  def ensure_for_research_batch(%ResearchBatch{} = batch, trend) do
    trend = trend || if(batch.batch_type == "eod", do: latest_final_trend(batch.analysis_date))

    cond do
      batch.batch_type == "eod" and not full_enabled?() ->
        {:ok, nil}

      batch.batch_type == "eod" and is_nil(trend) ->
        {:ok, nil}

      batch.batch_type == "eod" and not trend.frozen ->
        {:error, :final_trend_not_frozen}

      true ->
        case Repo.transaction(fn -> ensure_full_batch!(batch, trend) end) do
          {:ok, full_batch} = result ->
            maybe_warn_full_backlog(batch, full_batch)
            result

          error ->
            error
        end
    end
  end

  def maybe_schedule_item(%ResearchItem{status: status} = research_item)
      when status in ["complete", "partial"] do
    batch = Repo.get!(ResearchBatch, research_item.research_batch_id)

    with {:ok, %FullAnalysisItem{} = item} <- ensure_full_item(batch, research_item),
         {:ok, item} <- bind_digest_identity(item, research_item),
         {:ok, _job} <- FullAnalysisWorker.new(%{"item_id" => item.id}) |> Oban.insert() do
      {:ok, item}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  def maybe_schedule_item(_), do: {:ok, nil}

  def get_batch_for_research(research_batch_id) do
    Repo.get_by(FullAnalysisBatch, research_batch_id: research_batch_id)
  end

  def batch_summary_map(research_batch_ids) do
    Repo.all(
      from f in FullAnalysisBatch,
        where: f.research_batch_id in ^research_batch_ids,
        select: {f.research_batch_id, f}
    )
    |> Map.new()
  end

  def item_api_summaries(items, batch) do
    research_item_ids = Enum.map(items, & &1.id)

    full_items =
      Repo.all(
        from f in FullAnalysisItem,
          left_join: b in FullAnalysisBatch,
          on: b.id == f.full_analysis_batch_id,
          left_join: t in TrendMember,
          on: t.trend_snapshot_id == b.trend_snapshot_id and t.ticker == f.ticker,
          where: f.research_item_id in ^research_item_ids,
          select: {f.research_item_id, f, t.trend_score}
      )

    full_item_ids = Enum.map(full_items, fn {_research_id, item, _score} -> item.id end)

    stage_map =
      Repo.all(
        from s in ResearchStageRun,
          where: s.full_analysis_item_id in ^full_item_ids,
          order_by: [asc: s.ordinal]
      )
      |> Enum.group_by(& &1.full_analysis_item_id)

    full_map =
      Map.new(full_items, fn {research_id, full, trend_score} ->
        stages = stage_map[full.id] || []
        current = Enum.find(stages, &(&1.status not in ~w(complete partial unavailable)))

        {research_id,
         %{
           analysis_depth: "full",
           full_status: full.status,
           full_current_stage: current && current.stage,
           full_completed_stages:
             Enum.count(stages, &(&1.status in ~w(complete partial unavailable))),
           trend_score: trend_score,
           full_report_hash: full.full_report_hash,
           full_rag_status: full.rag_status
         }}
      end)

    Map.new(items, fn item ->
      {item.id,
       Map.get(full_map, item.id, %{
         analysis_depth: batch.analysis_depth,
         full_status: nil,
         full_current_stage: nil,
         full_completed_stages: 0,
         trend_score: nil,
         full_report_hash: nil,
         full_rag_status: nil
       })}
    end)
  end

  def list_items(full_batch_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(100)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    ticker = Keyword.get(opts, :ticker)
    status = Keyword.get(opts, :status)

    query =
      from i in FullAnalysisItem,
        where: i.full_analysis_batch_id == ^full_batch_id,
        order_by: [asc: i.selection_rank],
        limit: ^limit,
        offset: ^offset

    query =
      if ticker, do: from(i in query, where: i.ticker == ^String.upcase(ticker)), else: query

    query = if status, do: from(i in query, where: i.status == ^status), else: query
    Repo.all(query)
  end

  def item_for_ticker(full_batch_id, ticker) when is_binary(ticker),
    do:
      Repo.get_by(FullAnalysisItem,
        full_analysis_batch_id: full_batch_id,
        ticker: String.upcase(ticker)
      )

  def list_stages(item_id) do
    Repo.all(
      from s in ResearchStageRun,
        where: s.full_analysis_item_id == ^item_id,
        order_by: [asc: s.ordinal]
    )
  end

  def load_item!(item_id) do
    Repo.get!(FullAnalysisItem, item_id)
    |> Repo.preload([:research_item, full_analysis_batch: :research_batch, stage_runs: []])
  end

  def initialize_item(%FullAnalysisItem{} = item, result) do
    with :ok <- validate_init_result(item, result) do
      item
      |> FullAnalysisItem.changeset(%{
        status: "running",
        identity_hash: result["identity_hash"],
        session_path: result["session_path"],
        started_at: item.started_at || DateTime.utc_now(),
        last_error: nil
      })
      |> Repo.update()
      |> tap(fn
        {:ok, updated} -> refresh_batch(updated.full_analysis_batch_id)
        _ -> :ok
      end)
    end
  end

  def reconcile_status(%FullAnalysisItem{} = item, result) when is_map(result) do
    with true <-
           result["identity_hash"] == item.identity_hash or {:error, :full_identity_mismatch},
         true <-
           result["parent_identity_hash"] == item.parent_identity_hash or
             {:error, :parent_identity_mismatch},
         statuses when is_map(statuses) <- result["stage_status"],
         terminal when is_list(terminal) <- result["terminal_stages"],
         :ok <- validate_terminal_stages(terminal),
         :ok <-
           validate_terminal_payload(
             terminal,
             statuses,
             result["stage_fingerprints"] || %{}
           ) do
      Enum.each(terminal, fn stage ->
        status = statuses[stage]

        if status in ~w(complete partial unavailable) do
          fingerprint = (result["stage_fingerprints"] || %{})[stage]
          complete_stage_by_name(item.id, stage, status, fingerprint, nil)
        end
      end)

      {:ok, load_item!(item.id)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_analysis_status}
    end
  end

  def next_stage(%FullAnalysisItem{} = item) do
    item.id
    |> list_stages()
    |> Enum.find(&(&1.status not in ~w(complete partial unavailable)))
  end

  def claim_stage(%ResearchStageRun{} = run) do
    now = DateTime.utc_now()

    lease_seconds =
      Application.get_env(:gx_portfolio_intelligence, :full_stage_claim_lease_seconds, 2_100)

    claim_key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    {count, _} =
      Repo.update_all(
        from(s in ResearchStageRun,
          where:
            s.id == ^run.id and
              (s.status in ["pending", "failed"] or
                 (s.status == "running" and s.lease_expires_at <= ^now))
        ),
        set: [
          status: "running",
          claim_key: claim_key,
          lease_expires_at: DateTime.add(now, lease_seconds, :second),
          started_at: run.started_at || now,
          completed_at: nil,
          last_error: nil,
          updated_at: now
        ],
        inc: [attempt_count: 1]
      )

    if count == 1 do
      {:ok, Repo.get!(ResearchStageRun, run.id), claim_key}
    else
      current = Repo.get!(ResearchStageRun, run.id)

      if current.status in ["complete", "partial", "unavailable"],
        do: {:already_complete, current},
        else: {:busy, current}
    end
  end

  def complete_stage(%ResearchStageRun{} = run, claim_key, result) do
    expected_item = Repo.get!(FullAnalysisItem, run.full_analysis_item_id)

    with true <-
           result["identity_hash"] == expected_item.identity_hash or
             {:error, :full_identity_mismatch},
         true <- result["stage"] == run.stage or {:error, :stage_identity_mismatch},
         true <- result["stage_terminal"] == true or {:error, :stage_not_terminal},
         terminal when is_list(terminal) <- result["terminal_stages"],
         :ok <- validate_terminal_stages(terminal),
         true <- run.stage in terminal or {:error, :stage_not_terminal},
         status when status in ~w(complete partial unavailable) <-
           normalize_stage_status(result),
         fingerprint when is_binary(fingerprint) <- result["stage_fingerprint"],
         true <- Regex.match?(@sha256, fingerprint) or {:error, :invalid_stage_fingerprint} do
      now = DateTime.utc_now()

      {count, _} =
        Repo.update_all(
          from(s in ResearchStageRun,
            where: s.id == ^run.id and s.status == "running" and s.claim_key == ^claim_key
          ),
          set: [
            status: status,
            claim_key: nil,
            lease_expires_at: nil,
            output_fingerprint: fingerprint,
            artifact_path: result["artifact_path"],
            completed_at: now,
            last_error: nil,
            metadata: %{"next_stage" => result["next_stage"]},
            updated_at: now
          ]
        )

      if count == 1,
        do: {:ok, Repo.get!(ResearchStageRun, run.id)},
        else: {:error, :stage_claim_lost}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_stage_result}
    end
  end

  def mark_stage_failed(%ResearchStageRun{} = run, claim_key, reason) do
    code = SafeError.code(reason)

    {count, _} =
      Repo.update_all(
        from(s in ResearchStageRun,
          where: s.id == ^run.id and s.status == "running" and s.claim_key == ^claim_key
        ),
        set: [
          status: "failed",
          claim_key: nil,
          lease_expires_at: nil,
          last_error: code,
          updated_at: DateTime.utc_now()
        ]
      )

    if count == 1,
      do: mark_item_failed(run.full_analysis_item_id, code),
      else: {:error, :stage_claim_lost}
  end

  def release_stage_claim(%ResearchStageRun{} = run, claim_key) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(s in ResearchStageRun,
          where: s.id == ^run.id and s.status == "running" and s.claim_key == ^claim_key
        ),
        set: [
          status: "pending",
          claim_key: nil,
          lease_expires_at: nil,
          last_error: nil,
          updated_at: now
        ]
      )

    if count == 1, do: :ok, else: {:error, :stage_claim_lost}
  end

  def fail_item(%FullAnalysisItem{} = item, reason),
    do: mark_item_failed(item.id, SafeError.code(reason))

  def mark_promoting(%FullAnalysisItem{} = item, attrs) do
    item
    |> FullAnalysisItem.changeset(
      Map.merge(attrs, %{
        status: "promoting",
        rag_status: "queued",
        completed_at: DateTime.utc_now(),
        last_error: nil
      })
    )
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> refresh_batch(updated.full_analysis_batch_id)
      _ -> :ok
    end)
  end

  def mark_not_publishable(%FullAnalysisItem{} = item, reason) do
    code = SafeError.code(reason)

    item
    |> FullAnalysisItem.changeset(%{
      status: "blocked",
      rag_status: "pending",
      completed_at: DateTime.utc_now(),
      last_error: code
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> refresh_batch(updated.full_analysis_batch_id)
      _ -> :ok
    end)
  end

  def mark_promoted(%FullAnalysisItem{} = item, action)
      when action in ["promoted", "unchanged"] do
    item
    |> FullAnalysisItem.changeset(%{
      status: "complete",
      rag_status: "ready",
      promoted_at: item.promoted_at || DateTime.utc_now(),
      last_error: nil
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> refresh_batch(updated.full_analysis_batch_id)
      _ -> :ok
    end)
  end

  def mark_promotion_submitted(%FullAnalysisItem{} = item, remote_status) do
    rag_status = if(remote_status == "indexing", do: "indexing", else: "submitted")

    item
    |> FullAnalysisItem.changeset(%{status: "promoting", rag_status: rag_status, last_error: nil})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> refresh_batch(updated.full_analysis_batch_id)
      _ -> :ok
    end)
  end

  def mark_promotion_failed(%FullAnalysisItem{} = item, :stale) do
    update_promotion_failure(item, "stale", "full_report_stale")
  end

  def mark_promotion_failed(%FullAnalysisItem{} = item, reason) do
    update_promotion_failure(item, "failed", SafeError.code(reason))
  end

  def refresh_batch(full_batch_id) do
    counts =
      Repo.one(
        from i in FullAnalysisItem,
          where: i.full_analysis_batch_id == ^full_batch_id,
          select: %{
            total: count(i.id),
            completed: filter(count(i.id), i.status == "complete"),
            promoted: filter(count(i.id), i.rag_status == "ready"),
            failed:
              filter(
                count(i.id),
                (i.status == "failed" or i.rag_status == "failed") and
                  i.status != "blocked" and i.rag_status != "stale"
              ),
            blocked: filter(count(i.id), i.status == "blocked" or i.rag_status == "stale"),
            promoting: filter(count(i.id), i.status == "promoting")
          }
      )

    batch = Repo.get!(FullAnalysisBatch, full_batch_id)

    status =
      cond do
        counts.total == 0 ->
          "pending"

        counts.promoted == counts.total ->
          "completed"

        counts.promoting > 0 ->
          "promoting"

        counts.blocked == counts.total ->
          "blocked"

        counts.failed + counts.blocked > 0 and
            counts.completed + counts.failed + counts.blocked == counts.total ->
          "degraded"

        true ->
          "running"
      end

    completed_at =
      if status in ["completed", "degraded", "blocked"],
        do: batch.completed_at || DateTime.utc_now(),
        else: nil

    batch
    |> FullAnalysisBatch.changeset(%{
      status: status,
      target_count: counts.total,
      completed_count: counts.completed,
      promoted_count: counts.promoted,
      failed_count: counts.failed,
      blocked_count: counts.blocked,
      started_at: if(counts.total > 0, do: batch.started_at || DateTime.utc_now(), else: nil),
      completed_at: completed_at
    })
    |> Repo.update()
  end

  def retry(%FullAnalysisBatch{} = batch) do
    items =
      Repo.all(
        from i in FullAnalysisItem,
          where:
            i.full_analysis_batch_id == ^batch.id and
              (i.status in ["failed", "blocked"] or i.rag_status == "failed"),
          order_by: i.selection_rank
      )

    results =
      Enum.map(items, fn item ->
        now = DateTime.utc_now()

        Repo.update_all(
          from(s in ResearchStageRun,
            where:
              s.full_analysis_item_id == ^item.id and
                (s.status == "failed" or
                   (s.status == "running" and s.lease_expires_at <= ^now))
          ),
          set: [
            status: "pending",
            claim_key: nil,
            lease_expires_at: nil,
            last_error: nil,
            updated_at: now
          ]
        )

        {:ok, reset} =
          item
          |> FullAnalysisItem.changeset(%{
            status: if(item.session_path, do: "running", else: "pending"),
            rag_status: if(item.rag_status == "failed", do: "pending", else: item.rag_status),
            last_error: nil
          })
          |> Repo.update()

        FullAnalysisWorker.new(%{"item_id" => reset.id}) |> Oban.insert()
      end)

    refresh_batch(batch.id)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, length(items)}
      {:error, _} = error -> error
    end
  end

  def restart(%FullAnalysisBatch{} = batch, raw_key, tickers) do
    with {:ok, key_hash} <- restart_key_hash(raw_key),
         {:ok, normalized} <- normalize_restart_tickers(tickers),
         fingerprint <- restart_fingerprint(batch.id, normalized),
         {:ok, {items, replayed}} <-
           Repo.transaction(fn ->
             restart_transaction!(batch, key_hash, fingerprint, normalized)
           end),
         :ok <- enqueue_restarted(items) do
      {:ok, length(items), replayed}
    end
  end

  def recover_incomplete do
    items =
      Repo.all(
        from i in FullAnalysisItem,
          join: r in ResearchItem,
          on: r.id == i.research_item_id,
          where:
            r.status in ["complete", "partial"] and
              (i.status in ["pending", "running", "failed", "promoting"] or
                 i.rag_status in ["queued", "submitted", "indexing", "failed"]),
          select: {i, r}
      )

    Enum.each(items, fn {item, research_item} ->
      worker =
        if item.status == "promoting" or
             item.rag_status in ["queued", "submitted", "indexing", "failed"],
           do: FullPromotionWorker,
           else: FullAnalysisWorker

      case worker do
        FullAnalysisWorker ->
          with {:ok, bound_item} <- bind_digest_identity(item, research_item) do
            worker.new(%{"item_id" => bound_item.id}) |> Oban.insert()
          end

        FullPromotionWorker ->
          worker.new(%{"item_id" => item.id}) |> Oban.insert()
      end
    end)

    {:ok, length(items)}
  end

  defp ensure_full_batch!(batch, trend) do
    selection = selection_for(batch, trend)

    full_batch =
      case Repo.get_by(FullAnalysisBatch, research_batch_id: batch.id) do
        nil ->
          %FullAnalysisBatch{}
          |> FullAnalysisBatch.changeset(%{
            research_batch_id: batch.id,
            trend_snapshot_id: trend && trend.id,
            status: "pending",
            target_count: length(selection),
            metadata: %{"selection_policy" => selection_policy(batch)}
          })
          |> Repo.insert!()

        existing ->
          if existing.trend_snapshot_id && trend && existing.trend_snapshot_id != trend.id,
            do: Repo.rollback(:full_analysis_selection_conflict)

          existing
      end

    research_items =
      Repo.all(
        from i in ResearchItem,
          where: i.research_batch_id == ^batch.id,
          select: {i.ticker, i}
      )
      |> Map.new()

    Enum.each(selection, fn %{ticker: ticker, selection_rank: rank} ->
      case research_items[ticker] do
        nil ->
          :ok

        research_item ->
          attrs = %{
            full_analysis_batch_id: full_batch.id,
            research_item_id: research_item.id,
            ticker: ticker,
            selection_rank: rank,
            liquidity_rank: research_item.liquidity_rank,
            status: "pending",
            rag_status: "pending",
            execution_key: execution_key(batch, research_item),
            execution_generation: 1,
            metadata: %{"selection_policy" => selection_policy(batch)}
          }

          case Repo.get_by(FullAnalysisItem, research_item_id: research_item.id) do
            nil ->
              item = %FullAnalysisItem{} |> FullAnalysisItem.changeset(attrs) |> Repo.insert!()
              insert_stages!(item.id)

            existing ->
              if existing.full_analysis_batch_id != full_batch.id or
                   existing.selection_rank != rank,
                 do: Repo.rollback(:full_analysis_item_conflict)
          end
      end
    end)

    item_count =
      Repo.aggregate(
        from(i in FullAnalysisItem, where: i.full_analysis_batch_id == ^full_batch.id),
        :count
      )

    full_batch
    |> FullAnalysisBatch.changeset(%{
      target_count: item_count,
      trend_snapshot_id: trend && trend.id
    })
    |> Repo.update!()
  end

  defp ensure_full_item(batch, research_item) do
    case Repo.get_by(FullAnalysisItem, research_item_id: research_item.id) do
      %FullAnalysisItem{} = item ->
        {:ok, item}

      nil ->
        with {:ok, _full_batch} <- ensure_for_research_batch(batch) do
          {:ok, Repo.get_by(FullAnalysisItem, research_item_id: research_item.id)}
        end
    end
  end

  defp maybe_warn_full_backlog(
         %ResearchBatch{batch_type: "eod"} = batch,
         %FullAnalysisBatch{target_count: target_count}
       )
       when is_integer(target_count) do
    threshold = backlog_warning_threshold()

    if full_enabled?() and is_integer(threshold) and threshold >= 1 and target_count > threshold do
      _ =
        Alerts.emit(:dependency_unhealthy, batch, %{
          phase: "full_analysis",
          reason: "full_analysis_backlog_expected",
          target_count: target_count
        })
    end

    :ok
  end

  defp maybe_warn_full_backlog(_batch, _full_batch), do: :ok

  defp selection_for(%ResearchBatch{batch_type: "adhoc"} = batch, _trend) do
    Repo.all(
      from i in ResearchItem,
        where: i.research_batch_id == ^batch.id,
        order_by: [asc: i.liquidity_rank],
        select: %{ticker: i.ticker, selection_rank: i.liquidity_rank}
    )
  end

  defp selection_for(%ResearchBatch{batch_type: "eod"}, %TrendSnapshot{} = trend) do
    Repo.all(
      from m in TrendMember,
        where: m.trend_snapshot_id == ^trend.id and m.selected == true,
        order_by: [asc: m.selection_rank],
        select: %{ticker: m.ticker, selection_rank: m.selection_rank}
    )
  end

  defp selection_policy(%ResearchBatch{batch_type: "adhoc"}), do: "all_requested"
  defp selection_policy(_), do: "frozen_trend_top"

  defp insert_stages!(item_id) do
    now = DateTime.utc_now()

    rows =
      @stages
      |> Enum.with_index(1)
      |> Enum.map(fn {stage, ordinal} ->
        %{
          full_analysis_item_id: item_id,
          stage: stage,
          ordinal: ordinal,
          status: "pending",
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(ResearchStageRun, rows,
      on_conflict: :nothing,
      conflict_target: [:full_analysis_item_id, :stage]
    )
  end

  defp bind_digest_identity(item, research_item) do
    cond do
      not valid_hash?(research_item.identity_hash) or not valid_hash?(research_item.digest_hash) ->
        {:error, :digest_identity_unavailable}

      item.parent_identity_hash && item.parent_identity_hash != research_item.identity_hash ->
        mark_not_publishable(item, :parent_digest_identity_changed)

      item.expected_digest_hash && item.expected_digest_hash != research_item.digest_hash ->
        mark_not_publishable(item, :expected_digest_hash_changed)

      true ->
        item
        |> FullAnalysisItem.changeset(%{
          parent_identity_hash: research_item.identity_hash,
          expected_digest_hash: research_item.digest_hash,
          last_error: nil
        })
        |> Repo.update()
    end
  end

  defp validate_init_result(item, result) do
    with true <- result["schema_version"] == 1,
         true <- result["status"] in ["initialized", "existing"],
         :ok <- valid_hash(result["identity_hash"]),
         true <- result["parent_identity_hash"] == item.parent_identity_hash,
         session when is_binary(session) <- result["session_path"],
         :ok <- managed_path(session) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_analysis_init_contract}
    end
  end

  defp complete_stage_by_name(item_id, stage, status, fingerprint, artifact_path) do
    attrs = %{
      status: status,
      claim_key: nil,
      lease_expires_at: nil,
      output_fingerprint: if(valid_hash?(fingerprint), do: fingerprint, else: nil),
      artifact_path: artifact_path,
      completed_at: DateTime.utc_now(),
      last_error: nil
    }

    Repo.update_all(
      from(s in ResearchStageRun,
        where:
          s.full_analysis_item_id == ^item_id and s.stage == ^stage and
            s.status not in ["complete", "partial", "unavailable"]
      ),
      set: Map.to_list(Map.put(attrs, :updated_at, DateTime.utc_now()))
    )
  end

  defp normalize_stage_status(%{"stage_status" => status})
       when status in ~w(complete partial unavailable),
       do: status

  defp normalize_stage_status(%{"status" => "already_complete", "stage_status" => status})
       when status in ~w(complete partial unavailable),
       do: status

  defp normalize_stage_status(%{"status" => status})
       when status in ~w(complete partial unavailable),
       do: status

  defp normalize_stage_status(_), do: nil

  defp validate_terminal_stages(stages) do
    if stages == Enum.take(@stages, length(stages)) and length(stages) <= length(@stages),
      do: :ok,
      else: {:error, :invalid_terminal_stages}
  end

  defp validate_terminal_payload(stages, statuses, fingerprints)
       when is_map(statuses) and is_map(fingerprints) do
    if Enum.all?(stages, fn stage ->
         statuses[stage] in ~w(complete partial unavailable) and
           valid_hash?(fingerprints[stage])
       end),
       do: :ok,
       else: {:error, :invalid_terminal_stage_payload}
  end

  defp validate_terminal_payload(_, _, _), do: {:error, :invalid_terminal_stage_payload}

  defp mark_item_failed(item_id, code) do
    item = Repo.get!(FullAnalysisItem, item_id)

    result =
      item
      |> FullAnalysisItem.changeset(%{status: "failed", last_error: code})
      |> Repo.update()

    refresh_batch(item.full_analysis_batch_id)
    result
  end

  defp update_promotion_failure(item, rag_status, code) do
    item
    |> FullAnalysisItem.changeset(%{status: "failed", rag_status: rag_status, last_error: code})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> refresh_batch(updated.full_analysis_batch_id)
      _ -> :ok
    end)
  end

  defp execution_key(batch, research_item) do
    :crypto.hash(
      :sha256,
      "full:v1:#{batch.source}:#{batch.id}:#{research_item.id}:#{research_item.ticker}"
    )
    |> Base.encode16(case: :lower)
  end

  defp restart_transaction!(batch, key_hash, fingerprint, tickers) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           ["gx_pi_full_restart:#{batch.id}"]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    case Repo.get(FullAnalysisRestartKey, key_hash) do
      %FullAnalysisRestartKey{
        request_fingerprint: ^fingerprint,
        full_analysis_batch_id: existing_batch_id
      } = existing
      when existing_batch_id == batch.id ->
        ids = existing.metadata["item_ids"] || []
        {Repo.all(from i in FullAnalysisItem, where: i.id in ^ids), true}

      %FullAnalysisRestartKey{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        items =
          Repo.all(
            from i in FullAnalysisItem,
              where: i.full_analysis_batch_id == ^batch.id and i.ticker in ^tickers,
              order_by: i.selection_rank,
              lock: "FOR UPDATE"
          )

        if Enum.sort(Enum.map(items, & &1.ticker)) != tickers,
          do: Repo.rollback(:invalid_restart_tickers)

        cond do
          Enum.any?(items, &(&1.rag_status == "ready" or not is_nil(&1.promoted_at))) ->
            Repo.rollback(:full_analysis_already_promoted)

          Enum.any?(items, fn item ->
            item.status not in ["failed", "blocked"] or item.rag_status != "pending" or
              not is_nil(item.full_report_hash) or not is_nil(item.promoted_at)
          end) ->
            Repo.rollback(:full_analysis_restart_not_allowed)

          true ->
            restarted = Enum.map(items, &restart_item!/1)

            %FullAnalysisRestartKey{}
            |> FullAnalysisRestartKey.changeset(%{
              idempotency_key_hash: key_hash,
              request_fingerprint: fingerprint,
              full_analysis_batch_id: batch.id,
              metadata: %{
                "item_ids" => Enum.map(restarted, & &1.id),
                "tickers" => tickers,
                "pipeline_version" => "gx_full_v1"
              }
            })
            |> Repo.insert!()

            {restarted, false}
        end
    end
  end

  defp restart_item!(item) do
    generation = item.execution_generation + 1

    restarted =
      item
      |> FullAnalysisItem.changeset(%{
        status: "pending",
        rag_status: "pending",
        execution_generation: generation,
        execution_key: restart_execution_key(item, generation),
        identity_hash: nil,
        session_path: nil,
        envelope_path: nil,
        full_report_hash: nil,
        source_updated_at: nil,
        started_at: nil,
        completed_at: nil,
        promoted_at: nil,
        last_error: nil
      })
      |> Repo.update!()

    Repo.update_all(
      from(s in ResearchStageRun, where: s.full_analysis_item_id == ^item.id),
      set: [
        status: "pending",
        claim_key: nil,
        lease_expires_at: nil,
        input_fingerprint: nil,
        output_fingerprint: nil,
        artifact_path: nil,
        started_at: nil,
        completed_at: nil,
        last_error: nil,
        metadata: %{},
        updated_at: DateTime.utc_now()
      ]
    )

    restarted
  end

  defp enqueue_restarted(items) do
    case Enum.find_value(items, fn item ->
           case FullAnalysisWorker.new(%{"item_id" => item.id}) |> Oban.insert() do
             {:ok, _job} -> nil
             {:error, reason} -> {:error, reason}
           end
         end) do
      nil -> :ok
      error -> error
    end
  end

  defp restart_key_hash(value) when is_binary(value) do
    normalized = String.trim(value)

    if Regex.match?(@idempotency_key, normalized),
      do: {:ok, sha256(normalized)},
      else: {:error, :invalid_idempotency_key}
  end

  defp restart_key_hash(_), do: {:error, :missing_idempotency_key}

  defp normalize_restart_tickers(tickers) when is_list(tickers) and tickers != [] do
    if not Enum.all?(tickers, &is_binary/1) do
      {:error, :invalid_restart_tickers}
    else
      normalized = Enum.map(tickers, &(String.trim(&1) |> String.upcase()))

      if Enum.all?(normalized, &Regex.match?(~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/, &1)) and
           length(Enum.uniq(normalized)) == length(normalized),
         do: {:ok, Enum.sort(normalized)},
         else: {:error, :invalid_restart_tickers}
    end
  end

  defp normalize_restart_tickers(_), do: {:error, :invalid_restart_tickers}

  defp restart_fingerprint(full_analysis_batch_id, tickers) do
    sha256(
      Jason.encode!(%{
        "schema_version" => 1,
        "mode" => "restart",
        "pipeline_version" => "gx_full_v1",
        "full_analysis_batch_id" => full_analysis_batch_id,
        "tickers" => tickers
      })
    )
  end

  defp restart_execution_key(item, generation),
    do: sha256("full:v1:restart:#{item.id}:#{item.ticker}:#{generation}")

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp persist_trend_transaction(attrs, members, selected) do
    selected_by_ticker = Map.new(selected, &{&1.ticker, &1})

    Repo.transaction(fn ->
      case Repo.get_by(TrendSnapshot,
             analysis_date: attrs.analysis_date,
             slot: attrs.slot
           ) do
        %TrendSnapshot{fingerprint: fingerprint} = existing
        when fingerprint == attrs.fingerprint ->
          Repo.preload(existing, :members)

        %TrendSnapshot{} ->
          Repo.rollback(:trend_snapshot_conflict)

        nil ->
          snapshot = %TrendSnapshot{} |> TrendSnapshot.changeset(attrs) |> Repo.insert!()
          now = DateTime.utc_now()

          rows =
            Enum.map(members, fn member ->
              selected_member = selected_by_ticker[member.ticker]

              %{
                trend_snapshot_id: snapshot.id,
                ticker: member.ticker,
                liquidity_rank: member.liquidity_rank,
                adtv20: member.adtv20,
                adv20: member.adv20,
                market_core_available: member.market_core_available,
                volume_ratio: member.volume_ratio,
                daily_move_abs_pct: member.daily_move_abs_pct,
                momentum20_abs_pct: member.momentum20_abs_pct,
                social_attention_velocity: member.social_attention_velocity,
                media_event_velocity: member.media_event_velocity,
                coverage: member.coverage,
                trend_score: member.trend_score,
                selected: not is_nil(selected_member),
                selection_rank: selected_member && selected_member.selection_rank,
                pinned: (selected_member && selected_member.pinned) || false,
                metadata: %{},
                inserted_at: now
              }
            end)

          {count, _} = Repo.insert_all(TrendMember, rows)
          if count != length(rows), do: Repo.rollback(:trend_member_insert_failed)
          Repo.preload(snapshot, :members)
      end
    end)
  end

  defp validate_trend(result, universe, opts) do
    with true <- Enum.sort(Map.keys(result)) == Enum.sort(@trend_keys),
         true <- result["schema_version"] == 1,
         true <- result["analysis_date"] == Date.to_iso8601(universe.analysis_date),
         {:ok, cutoff} <- parse_datetime(result["cutoff"]),
         true <- DateTime.compare(cutoff, opts[:cutoff]) == :eq,
         {:ok, previous_cutoff} <- parse_datetime(result["previous_cutoff"]),
         true <- DateTime.compare(previous_cutoff, opts[:previous_cutoff]) == :eq,
         true <- result["slot"] == universe.slot,
         true <- result["universe_fingerprint"] == universe.fingerprint,
         :ok <- validate_weights(result["weights"]),
         true <- result["status"] in ["complete", "degraded"],
         true <- result["target_count"] == universe.member_count,
         true <- is_integer(result["scored_count"]),
         true <- valid_hash?(result["fingerprint"]),
         true <- result["fingerprint"] == trend_fingerprint(result),
         true <- valid_warnings?(result["warnings"]),
         {:ok, members} <- validate_trend_members(result["members"], universe),
         true <- result["scored_count"] == Enum.count(members, &valid_score?(&1.trend_score)),
         :ok <- validate_trend_order(members) do
      {:ok,
       %{
         universe_snapshot_id: universe.id,
         analysis_date: universe.analysis_date,
         cutoff_at: cutoff,
         previous_cutoff_at: previous_cutoff,
         slot: universe.slot,
         status: result["status"],
         target_count: result["target_count"],
         scored_count: result["scored_count"],
         selected_count: 0,
         universe_fingerprint: universe.fingerprint,
         fingerprint: result["fingerprint"],
         weights: result["weights"],
         warnings: result["warnings"],
         artifact_path: opts[:artifact_path],
         frozen: opts[:frozen] == true,
         metadata: %{"schema_version" => 1}
       }, members}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_trend_contract}
    end
  end

  defp validate_trend_members(members, universe) when is_list(members) do
    official =
      universe
      |> Repo.preload(:members)
      |> Map.fetch!(:members)
      |> Map.new(&{&1.ticker, &1})

    Enum.reduce_while(members, {:ok, []}, fn raw, {:ok, acc} ->
      with true <- is_map(raw) and Enum.sort(Map.keys(raw)) == Enum.sort(@trend_member_keys),
           ticker when is_binary(ticker) <- raw["ticker"],
           %{} = source <- official[ticker],
           true <- raw["liquidity_rank"] == source.rank,
           {:ok, adtv20} <- decimal(raw["adtv20"]),
           true <- Decimal.equal?(adtv20, source.adtv20),
           {:ok, adv20} <- decimal(raw["adv20"]),
           true <- Decimal.positive?(adv20) and Decimal.equal?(adv20, source.adv20),
           true <- is_boolean(raw["market_core_available"]),
           {:ok, score} <- optional_decimal(raw["trend_score"]),
           :ok <- validate_coverage(raw["coverage"], raw["market_core_available"]),
           {:ok, factors} <- validate_factor_decimals(raw),
           :ok <- validate_market_core(raw["market_core_available"], score, factors) do
        member =
          struct!(TrendMember, %{
            ticker: ticker,
            liquidity_rank: source.rank,
            adtv20: adtv20,
            adv20: adv20,
            market_core_available: raw["market_core_available"],
            trend_score: score,
            coverage: raw["coverage"],
            volume_ratio: factors.volume_ratio,
            daily_move_abs_pct: factors.daily_move_abs_pct,
            momentum20_abs_pct: factors.momentum20_abs_pct,
            social_attention_velocity: factors.social_attention_velocity,
            media_event_velocity: factors.media_event_velocity,
            metadata: %{}
          })

        {:cont, {:ok, [member | acc]}}
      else
        _ -> {:halt, {:error, :invalid_trend_member}}
      end
    end)
    |> case do
      {:ok, parsed} ->
        parsed = Enum.reverse(parsed)
        tickers = Enum.map(parsed, & &1.ticker)

        if length(parsed) == universe.member_count and
             MapSet.new(tickers) == MapSet.new(Map.keys(official)) and
             length(Enum.uniq(tickers)) == length(tickers),
           do: {:ok, parsed},
           else: {:error, :invalid_trend_members}

      error ->
        error
    end
  end

  defp validate_trend_members(_, _), do: {:error, :invalid_trend_members}

  defp validate_factor_decimals(raw) do
    keys =
      ~w(volume_ratio daily_move_abs_pct momentum20_abs_pct social_attention_velocity media_event_velocity)

    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case optional_decimal(raw[key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, String.to_atom(key), value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_coverage(coverage, market_core) when is_map(coverage) do
    if Enum.sort(Map.keys(coverage)) == ~w(market_core media_event social_attention) and
         Enum.all?(Map.values(coverage), &is_boolean/1) and
         coverage["market_core"] == market_core,
       do: :ok,
       else: {:error, :invalid_trend_coverage}
  end

  defp validate_coverage(_, _), do: {:error, :invalid_trend_coverage}

  defp validate_market_core(true, %Decimal{}, factors) do
    if Enum.all?(
         [factors.volume_ratio, factors.daily_move_abs_pct, factors.momentum20_abs_pct],
         &match?(%Decimal{}, &1)
       ),
       do: :ok,
       else: {:error, :missing_market_core_factor}
  end

  defp validate_market_core(false, nil, factors) do
    if Enum.all?(
         [factors.volume_ratio, factors.daily_move_abs_pct, factors.momentum20_abs_pct],
         &is_nil/1
       ),
       do: :ok,
       else: {:error, :unexpected_market_core_factor}
  end

  defp validate_market_core(_, _, _), do: {:error, :invalid_market_core}

  defp validate_trend_order(members) do
    eligible = Enum.filter(members, &(&1.market_core_available and valid_score?(&1.trend_score)))
    sorted = Enum.sort(eligible, &trend_before?/2)
    if eligible == sorted, do: :ok, else: {:error, :invalid_trend_order}
  end

  defp select_members(members, frozen?) do
    if frozen? do
      top500 = Enum.filter(members, &(&1.liquidity_rank <= 500))
      eligible = Enum.filter(top500, &(&1.market_core_available and valid_score?(&1.trend_score)))
      by_ticker = Map.new(eligible, &{&1.ticker, &1})
      configured = pinned_tickers()

      pinned =
        Enum.flat_map(configured, fn ticker ->
          if by_ticker[ticker], do: [by_ticker[ticker]], else: []
        end)

      pinned_set = MapSet.new(Enum.map(pinned, & &1.ticker))

      ranked =
        eligible
        |> Enum.reject(&MapSet.member?(pinned_set, &1.ticker))
        |> Enum.sort(&trend_before?/2)

      selected = Enum.take(pinned ++ ranked, selection_limit())

      selected =
        selected
        |> Enum.with_index(1)
        |> Enum.map(fn {member, rank} ->
          %{member | selection_rank: rank, pinned: MapSet.member?(pinned_set, member.ticker)}
        end)

      missing = configured -- Map.keys(by_ticker)
      warnings = Enum.map(missing, fn _ -> "pinned_ticker_outside_frozen_top500" end)

      warnings =
        if length(configured) > selection_limit(),
          do: ["pinned_count_exceeds_limit" | warnings],
          else: warnings

      {selected, Enum.uniq(warnings)}
    else
      {[], []}
    end
  end

  defp trend_before?(left, right) do
    case Decimal.compare(left.trend_score, right.trend_score) do
      :gt ->
        true

      :lt ->
        false

      :eq ->
        case Decimal.compare(left.adtv20, right.adtv20) do
          :gt -> true
          :lt -> false
          :eq -> left.ticker <= right.ticker
        end
    end
  end

  defp canonical_json(value), do: value |> canonical_iodata() |> IO.iodata_to_binary()

  defp normalize_trend_fingerprint_payload(result) do
    payload = Map.delete(result, "fingerprint")

    with weights when is_map(weights) <- payload["weights"],
         members when is_list(members) <- payload["members"],
         {:ok, normalized_weights} <- normalize_trend_weights_for_fingerprint(weights),
         {:ok, normalized_members} <- normalize_trend_members_for_fingerprint(members) do
      {:ok,
       payload
       |> Map.put("weights", normalized_weights)
       |> Map.put("members", normalized_members)}
    else
      _ -> {:error, :invalid_trend_fingerprint_payload}
    end
  end

  defp normalize_trend_weights_for_fingerprint(weights) do
    Enum.reduce_while(weights, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case canonical_decimal_string(value) do
        {:ok, decimal} -> {:cont, {:ok, Map.put(acc, to_string(key), decimal)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_trend_members_for_fingerprint(members) do
    Enum.reduce_while(members, {:ok, []}, fn
      member, {:ok, acc} when is_map(member) ->
        case normalize_trend_member_for_fingerprint(member) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_trend_fingerprint_member}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_trend_member_for_fingerprint(member) do
    Enum.reduce_while(@trend_fingerprint_member_decimals, {:ok, member}, fn key, {:ok, acc} ->
      case Map.fetch(acc, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case canonical_decimal_string(value) do
            {:ok, decimal} -> {:cont, {:ok, Map.put(acc, key, decimal)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp canonical_decimal_string(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: {:error, :invalid_trend_fingerprint_decimal},
      else: {:ok, render_canonical_decimal(value)}
  end

  defp canonical_decimal_string(value) when is_integer(value),
    do: canonical_decimal_string(Decimal.new(value))

  defp canonical_decimal_string(value) when is_float(value) do
    canonical_decimal_string(Float.to_string(value))
  end

  defp canonical_decimal_string(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = parsed, ""} -> canonical_decimal_string(parsed)
      _ -> {:error, :invalid_trend_fingerprint_decimal}
    end
  end

  defp canonical_decimal_string(_), do: {:error, :invalid_trend_fingerprint_decimal}

  defp render_canonical_decimal(value) do
    if Decimal.equal?(value, Decimal.new(0)) do
      "0"
    else
      value
      |> Decimal.to_string(:normal)
      |> trim_decimal_fraction()
    end
  end

  defp trim_decimal_fraction(value) do
    case String.split(value, ".", parts: 2) do
      [integer, fraction] ->
        case String.trim_trailing(fraction, "0") do
          "" -> integer
          trimmed -> integer <> "." <> trimmed
        end

      [_integer] ->
        value
    end
  end

  defp canonical_iodata(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, nested} ->
        [Jason.encode!(to_string(key)), ":", canonical_iodata(nested)]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical_iodata(value) when is_list(value),
    do: ["[", value |> Enum.map(&canonical_iodata/1) |> Enum.intersperse(","), "]"]

  defp canonical_iodata(value), do: Jason.encode!(value)

  defp validate_weights(weights) when is_map(weights) do
    expected = trend_weights()

    if Enum.sort(Map.keys(weights)) == Enum.sort(Map.keys(expected)) and
         Enum.all?(expected, fn {key, value} -> numeric_equal?(weights[key], value) end),
       do: :ok,
       else: {:error, :invalid_trend_weights}
  end

  defp validate_weights(_), do: {:error, :invalid_trend_weights}

  defp valid_warnings?(warnings) when is_list(warnings) and length(warnings) <= 100,
    do: Enum.all?(warnings, &(is_binary(&1) and Regex.match?(@warning, &1)))

  defp valid_warnings?(_), do: false

  defp maybe_alert_trend_warnings(%{frozen: true, warnings: warnings} = trend) do
    if Enum.any?(
         warnings,
         &(&1 in ["pinned_ticker_outside_frozen_top500", "pinned_count_exceeds_limit"])
       ) do
      Alerts.emit_global(:dependency_unhealthy, trend.analysis_date, %{
        reason: "full_analysis_pinned_selection_invalid"
      })
    end

    :ok
  end

  defp maybe_alert_trend_warnings(_), do: :ok

  defp managed_path(path) do
    with {:ok, root} <- GxPortfolioIntelligence.ArtifactStore.root(),
         :ok <- GxPortfolioIntelligence.ArtifactStore.ensure_within(path, root) do
      :ok
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _} -> {:ok, parsed}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp decimal(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: {:error, :invalid_decimal},
      else: {:ok, value}
  end

  defp decimal(value) when is_integer(value) or is_float(value),
    do: {:ok, Decimal.from_float(value * 1.0)}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = parsed, ""} -> decimal(parsed)
      _ -> {:error, :invalid_decimal}
    end
  end

  defp decimal(_), do: {:error, :invalid_decimal}

  defp optional_decimal(nil), do: {:ok, nil}
  defp optional_decimal(value), do: decimal(value)

  defp numeric_equal?(left, right) do
    with {:ok, left} <- decimal(left),
         {:ok, right} <- decimal(right),
         do: Decimal.equal?(left, right)
  end

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(@sha256, value)
  defp valid_hash(value), do: if(valid_hash?(value), do: :ok, else: {:error, :invalid_hash})
  defp valid_score?(%Decimal{}), do: true
  defp valid_score?(_), do: false
end
