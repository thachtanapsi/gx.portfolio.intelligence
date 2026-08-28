defmodule GxPortfolioIntelligenceWeb.Serializers do
  @moduledoc false

  def batch(batch, full \\ nil) do
    %{
      id: batch.id,
      batch_type: batch.batch_type,
      research_mode: batch.research_mode,
      analysis_depth: batch.analysis_depth,
      source: batch.source,
      analysis_date: batch.analysis_date,
      cutoff_at: batch.cutoff_at,
      status: batch.status,
      target_count: batch.target_count,
      completed_count: batch.completed_count,
      rag_ready_count: batch.rag_ready_count,
      failed_count: batch.failed_count,
      sla_ready_count: batch.sla_ready_count,
      sla_status: batch.sla_status,
      universe_snapshot_id: batch.universe_snapshot_id,
      started_at: batch.started_at,
      completed_at: batch.completed_at,
      sla_recovered_at: batch.sla_recovered_at,
      evidence_policy: batch.metadata["evidence_policy"],
      data_provenance:
        batch.metadata["data_provenance"] ||
          if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff"),
      last_error_code: batch.last_error,
      full_analysis_status: full && full.status,
      full_status: full && full.status,
      full_analysis_target_count: full && full.target_count,
      full_analysis_completed_count: full && full.completed_count,
      full_analysis_promoted_count: full && full.promoted_count,
      full_analysis_failed_count: full && full.failed_count,
      requested_tickers:
        if(batch.batch_type == "adhoc", do: batch.metadata["requested_tickers"], else: nil),
      inserted_at: batch.inserted_at,
      updated_at: batch.updated_at
    }
  end

  def full_batch(batch) do
    %{
      id: batch.id,
      research_batch_id: batch.research_batch_id,
      trend_snapshot_id: batch.trend_snapshot_id,
      status: batch.status,
      target_count: batch.target_count,
      completed_count: batch.completed_count,
      promoted_count: batch.promoted_count,
      failed_count: batch.failed_count,
      blocked_count: batch.blocked_count,
      started_at: batch.started_at,
      completed_at: batch.completed_at,
      last_error_code: batch.last_error,
      inserted_at: batch.inserted_at,
      updated_at: batch.updated_at
    }
  end

  def full_item(item) do
    %{
      id: item.id,
      ticker: item.ticker,
      selection_rank: item.selection_rank,
      liquidity_rank: item.liquidity_rank,
      status: item.status,
      rag_status: item.rag_status,
      execution_generation: item.execution_generation,
      parent_identity_hash: item.parent_identity_hash,
      expected_digest_hash: item.expected_digest_hash,
      identity_hash: item.identity_hash,
      full_report_hash: item.full_report_hash,
      started_at: item.started_at,
      completed_at: item.completed_at,
      promoted_at: item.promoted_at,
      last_error_code: item.last_error
    }
  end

  def stage(run) do
    %{
      stage: run.stage,
      ordinal: run.ordinal,
      status: run.status,
      input_fingerprint: run.input_fingerprint,
      output_fingerprint: run.output_fingerprint,
      started_at: run.started_at,
      completed_at: run.completed_at,
      last_error_code: run.last_error
    }
  end

  def trend(snapshot) do
    %{
      id: snapshot.id,
      universe_snapshot_id: snapshot.universe_snapshot_id,
      analysis_date: snapshot.analysis_date,
      cutoff_at: snapshot.cutoff_at,
      previous_cutoff_at: snapshot.previous_cutoff_at,
      slot: snapshot.slot,
      status: snapshot.status,
      target_count: snapshot.target_count,
      scored_count: snapshot.scored_count,
      selected_count: snapshot.selected_count,
      frozen: snapshot.frozen,
      universe_fingerprint: snapshot.universe_fingerprint,
      fingerprint: snapshot.fingerprint,
      weights: snapshot.weights,
      warnings: snapshot.warnings,
      last_error_code: snapshot.last_error,
      inserted_at: snapshot.inserted_at
    }
  end

  def item(item, full \\ nil) do
    %{
      id: item.id,
      ticker: item.ticker,
      liquidity_rank: item.liquidity_rank,
      rank_scope: "batch",
      status: item.status,
      llm_status: item.llm_status,
      rag_status: item.rag_status,
      identity_hash: item.identity_hash,
      digest_hash: item.digest_hash,
      analysis_depth: full && full.analysis_depth,
      full_status: full && full.full_status,
      full_current_stage: full && full.full_current_stage,
      full_completed_stages: full && full.full_completed_stages,
      trend_score: full && full.trend_score,
      full_report_hash: full && full.full_report_hash,
      full_rag_status: full && full.full_rag_status,
      started_at: item.started_at,
      completed_at: item.completed_at,
      rag_ready_at: item.rag_ready_at,
      last_error: item.last_error,
      last_error_code: item.last_error
    }
  end

  def snapshot(snapshot) do
    %{
      id: snapshot.id,
      analysis_date: snapshot.analysis_date,
      slot: snapshot.slot,
      cutoff_at: snapshot.cutoff_at,
      member_limit: snapshot.member_limit,
      member_count: snapshot.member_count,
      status: snapshot.status,
      frozen: snapshot.frozen,
      fingerprint: snapshot.fingerprint,
      inserted_at: snapshot.inserted_at
    }
  end
end
