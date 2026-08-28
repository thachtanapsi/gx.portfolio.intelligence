defmodule GxPortfolioIntelligence.Repo.Migrations.AddWorkflowConstraints do
  use Ecto.Migration

  def up do
    create constraint(:universe_snapshots, :universe_snapshot_member_count,
             check: "member_count >= 0 AND member_count <= member_limit"
           )

    create constraint(:universe_snapshots, :universe_snapshot_status,
             check: "status IN ('pending','running','complete','degraded','failed')"
           )

    create constraint(:universe_members, :universe_member_rank,
             check: "rank > 0 AND rank <= 600"
           )

    create constraint(:universe_members, :universe_member_liquidity,
             check: "adtv20 >= 0 AND adv20 >= 0"
           )

    create constraint(:research_batches, :research_batch_counts,
             check:
               "target_count > 0 AND target_count <= 500 AND sla_ready_count > 0 AND sla_ready_count <= target_count AND completed_count >= 0 AND completed_count <= target_count AND rag_ready_count >= 0 AND rag_ready_count <= completed_count AND failed_count >= 0 AND failed_count <= target_count"
           )

    create constraint(:research_batches, :research_batch_status,
             check:
               "status IN ('pending','collecting','researching','indexing','degraded','completed','failed','blocked')"
           )

    create constraint(:research_batches, :research_batch_sla_status,
             check: "sla_status IN ('pending','met','missed')"
           )

    create constraint(:evidence_runs, :evidence_run_counts,
             check:
               "target_count >= 0 AND target_count <= 600 AND processed_count >= 0 AND succeeded_count >= 0 AND failed_count >= 0"
           )

    create constraint(:evidence_runs, :evidence_run_lane,
             check: "lane IN ('social','media','macro')"
           )

    create constraint(:evidence_runs, :evidence_run_status,
             check: "status IN ('pending','running','complete','degraded','failed')"
           )

    create unique_index(:research_items, [:research_batch_id, :liquidity_rank],
             name: :research_items_batch_rank_index
           )

    create constraint(:research_items, :research_item_rank,
             check: "liquidity_rank > 0 AND liquidity_rank <= 500"
           )

    create constraint(:research_items, :research_item_status,
             check: "status IN ('pending','running','complete','partial','failed')"
           )

    create constraint(:research_items, :research_item_llm_status,
             check: "llm_status IN ('pending','claimed','complete','partial','failed','skipped')"
           )

    create constraint(:research_items, :research_item_rag_status,
             check:
               "rag_status IN ('pending','queued','submitted','indexing','ready','failed','stale')"
           )

    create constraint(:alert_events, :alert_event_attempts, check: "attempts >= 0")

    create constraint(:alert_events, :alert_event_type,
             check:
               "event_type IN ('batch_sla_missed','batch_blocked','batch_recovered','dependency_unhealthy')"
           )

    create constraint(:alert_events, :alert_event_status,
             check: "status IN ('pending','delivered','failed')"
           )
  end

  def down do
    drop constraint(:alert_events, :alert_event_status)
    drop constraint(:alert_events, :alert_event_type)
    drop constraint(:alert_events, :alert_event_attempts)
    drop constraint(:research_items, :research_item_rag_status)
    drop constraint(:research_items, :research_item_llm_status)
    drop constraint(:research_items, :research_item_status)
    drop constraint(:research_items, :research_item_rank)
    drop index(:research_items, [:research_batch_id, :liquidity_rank],
           name: :research_items_batch_rank_index
         )

    drop constraint(:evidence_runs, :evidence_run_status)
    drop constraint(:evidence_runs, :evidence_run_lane)
    drop constraint(:evidence_runs, :evidence_run_counts)
    drop constraint(:research_batches, :research_batch_sla_status)
    drop constraint(:research_batches, :research_batch_status)
    drop constraint(:research_batches, :research_batch_counts)
    drop constraint(:universe_members, :universe_member_liquidity)
    drop constraint(:universe_members, :universe_member_rank)
    drop constraint(:universe_snapshots, :universe_snapshot_status)
    drop constraint(:universe_snapshots, :universe_snapshot_member_count)
  end
end
