defmodule GxPortfolioIntelligence.Repo.Migrations.AddFullAnalysisWorkflow do
  use Ecto.Migration

  def up do
    alter table(:research_batches) do
      add :analysis_depth, :string, null: false, default: "digest"
    end

    create constraint(:research_batches, :research_batch_analysis_depth,
             check: "analysis_depth IN ('digest','full')"
           )

    create table(:trend_snapshots) do
      add :universe_snapshot_id, references(:universe_snapshots, on_delete: :restrict), null: false
      add :analysis_date, :date, null: false
      add :cutoff_at, :utc_datetime_usec, null: false
      add :previous_cutoff_at, :utc_datetime_usec
      add :slot, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :target_count, :integer, null: false
      add :scored_count, :integer, null: false, default: 0
      add :selected_count, :integer, null: false, default: 0
      add :universe_fingerprint, :string, null: false
      add :fingerprint, :string
      add :weights, :map, null: false, default: %{}
      add :warnings, {:array, :string}, null: false, default: []
      add :artifact_path, :text
      add :frozen, :boolean, null: false, default: false
      add :last_error, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trend_snapshots, [:analysis_date, :slot])
    create index(:trend_snapshots, [:universe_snapshot_id])
    create index(:trend_snapshots, [:analysis_date, :cutoff_at])

    create constraint(:trend_snapshots, :trend_snapshot_status,
             check: "status IN ('pending','complete','degraded','failed')"
           )

    create constraint(:trend_snapshots, :trend_snapshot_counts,
             check:
               "target_count > 0 AND target_count <= 600 AND scored_count >= 0 AND " <>
                 "scored_count <= target_count AND selected_count >= 0 AND selected_count <= scored_count"
           )

    create table(:trend_members) do
      add :trend_snapshot_id, references(:trend_snapshots, on_delete: :delete_all), null: false
      add :ticker, :string, null: false
      add :liquidity_rank, :integer, null: false
      add :adtv20, :decimal, precision: 24, scale: 4, null: false
      add :market_core_available, :boolean, null: false, default: false
      add :volume_ratio, :decimal, precision: 20, scale: 8
      add :daily_move_abs_pct, :decimal, precision: 20, scale: 8
      add :momentum20_abs_pct, :decimal, precision: 20, scale: 8
      add :social_attention_velocity, :decimal, precision: 20, scale: 8
      add :media_event_velocity, :decimal, precision: 20, scale: 8
      add :coverage, :map, null: false, default: %{}
      add :trend_score, :decimal, precision: 20, scale: 8
      add :selected, :boolean, null: false, default: false
      add :selection_rank, :integer
      add :pinned, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:trend_members, [:trend_snapshot_id, :ticker])
    create unique_index(:trend_members, [:trend_snapshot_id, :liquidity_rank])

    create unique_index(:trend_members, [:trend_snapshot_id, :selection_rank],
             where: "selection_rank IS NOT NULL"
           )

    create index(:trend_members, [:ticker])

    create constraint(:trend_members, :trend_member_rank,
             check:
               "liquidity_rank > 0 AND liquidity_rank <= 600 AND " <>
                 "(selection_rank IS NULL OR selection_rank > 0)"
           )

    create constraint(:trend_members, :trend_member_selection,
             check:
               "NOT selected OR (market_core_available AND trend_score IS NOT NULL AND selection_rank IS NOT NULL)"
           )

    create table(:full_analysis_batches) do
      add :research_batch_id, references(:research_batches, on_delete: :delete_all), null: false
      add :trend_snapshot_id, references(:trend_snapshots, on_delete: :nilify_all)
      add :status, :string, null: false, default: "pending"
      add :target_count, :integer, null: false, default: 0
      add :completed_count, :integer, null: false, default: 0
      add :promoted_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :blocked_count, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_error, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:full_analysis_batches, [:research_batch_id])
    create index(:full_analysis_batches, [:status, :inserted_at])

    create constraint(:full_analysis_batches, :full_analysis_batch_status,
             check: "status IN ('pending','running','promoting','completed','degraded','blocked')"
           )

    create constraint(:full_analysis_batches, :full_analysis_batch_counts,
             check:
               "target_count >= 0 AND completed_count >= 0 AND promoted_count >= 0 AND " <>
                 "failed_count >= 0 AND blocked_count >= 0 AND completed_count <= target_count AND " <>
                 "promoted_count <= target_count AND failed_count <= target_count AND blocked_count <= target_count"
           )

    create table(:full_analysis_items) do
      add :full_analysis_batch_id, references(:full_analysis_batches, on_delete: :delete_all),
        null: false

      add :research_item_id, references(:research_items, on_delete: :restrict), null: false
      add :ticker, :string, null: false
      add :selection_rank, :integer, null: false
      add :liquidity_rank, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :rag_status, :string, null: false, default: "pending"
      add :execution_key, :string, null: false
      add :execution_generation, :integer, null: false, default: 1
      add :expected_digest_hash, :string
      add :parent_identity_hash, :string
      add :identity_hash, :string
      add :session_path, :text
      add :envelope_path, :text
      add :full_report_hash, :string
      add :source_updated_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :promoted_at, :utc_datetime_usec
      add :last_error, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:full_analysis_items, [:full_analysis_batch_id, :ticker])
    create unique_index(:full_analysis_items, [:full_analysis_batch_id, :selection_rank])
    create unique_index(:full_analysis_items, [:research_item_id])
    create unique_index(:full_analysis_items, [:execution_key])
    create index(:full_analysis_items, [:status, :rag_status])

    create constraint(:full_analysis_items, :full_analysis_item_status,
             check: "status IN ('pending','running','promoting','complete','failed','blocked')"
           )

    create constraint(:full_analysis_items, :full_analysis_item_rag_status,
             check:
               "rag_status IN ('pending','queued','submitted','indexing','ready','failed','stale')"
           )

    create constraint(:full_analysis_items, :full_analysis_item_rank,
             check:
               "selection_rank > 0 AND liquidity_rank > 0 AND liquidity_rank <= 600 AND execution_generation > 0"
           )

    create table(:research_stage_runs) do
      add :full_analysis_item_id, references(:full_analysis_items, on_delete: :delete_all),
        null: false

      add :stage, :string, null: false
      add :ordinal, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :input_fingerprint, :string
      add :output_fingerprint, :string
      add :artifact_path, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_error, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:research_stage_runs, [:full_analysis_item_id, :stage])
    create unique_index(:research_stage_runs, [:full_analysis_item_id, :ordinal])
    create index(:research_stage_runs, [:status, :stage])

    create constraint(:research_stage_runs, :research_stage_name,
             check:
               "stage IN ('market','sentiment','news','fundamentals','research','trader','risk')"
           )

    create constraint(:research_stage_runs, :research_stage_status,
             check: "status IN ('pending','running','complete','partial','unavailable','failed')"
           )

    create constraint(:research_stage_runs, :research_stage_ordinal,
             check: "ordinal > 0 AND ordinal <= 7"
           )
  end

  def down do
    drop table(:research_stage_runs)
    drop table(:full_analysis_items)
    drop table(:full_analysis_batches)
    drop table(:trend_members)
    drop table(:trend_snapshots)

    drop constraint(:research_batches, :research_batch_analysis_depth)

    alter table(:research_batches) do
      remove :analysis_depth
    end
  end
end
