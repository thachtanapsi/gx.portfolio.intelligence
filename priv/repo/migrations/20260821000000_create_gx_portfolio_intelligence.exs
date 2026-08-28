defmodule GxPortfolioIntelligence.Repo.Migrations.CreateGxPortfolioIntelligence do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:universe_snapshots) do
      add :analysis_date, :date, null: false
      add :slot, :string, null: false
      add :cutoff_at, :utc_datetime_usec, null: false
      add :member_limit, :integer, null: false
      add :member_count, :integer, null: false, default: 0
      add :status, :string, null: false, default: "pending"
      add :frozen, :boolean, null: false, default: false
      add :fingerprint, :string
      add :artifact_path, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:universe_snapshots, [:analysis_date, :slot])
    create constraint(:universe_snapshots, :universe_member_limit,
             check: "member_limit > 0 AND member_limit <= 600"
           )

    create table(:universe_members) do
      add :universe_snapshot_id, references(:universe_snapshots, on_delete: :delete_all), null: false
      add :ticker, :string, null: false
      add :exchange, :string, null: false
      add :rank, :integer, null: false
      add :adtv20, :decimal, precision: 24, scale: 4, null: false
      add :adv20, :decimal, precision: 24, scale: 4, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:universe_members, [:universe_snapshot_id, :ticker])
    create unique_index(:universe_members, [:universe_snapshot_id, :rank])
    create index(:universe_members, [:ticker])

    create table(:research_batches) do
      add :analysis_date, :date, null: false
      add :cutoff_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :target_count, :integer, null: false, default: 500
      add :completed_count, :integer, null: false, default: 0
      add :rag_ready_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :sla_ready_count, :integer, null: false, default: 490
      add :sla_status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_error, :text
      add :metadata, :map, null: false, default: %{}
      add :universe_snapshot_id, references(:universe_snapshots, on_delete: :restrict)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:research_batches, [:analysis_date])
    create index(:research_batches, [:status, :analysis_date])

    create table(:evidence_runs) do
      add :analysis_date, :date, null: false
      add :slot, :string, null: false
      add :lane, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :target_count, :integer, null: false, default: 0
      add :processed_count, :integer, null: false, default: 0
      add :succeeded_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :watermark, :map, null: false, default: %{}
      add :idempotency_key, :string, null: false
      add :last_error, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :universe_snapshot_id, references(:universe_snapshots, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:evidence_runs, [:analysis_date, :slot, :lane])
    create unique_index(:evidence_runs, [:idempotency_key])

    create table(:research_items) do
      add :research_batch_id, references(:research_batches, on_delete: :delete_all), null: false
      add :ticker, :string, null: false
      add :liquidity_rank, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :llm_status, :string, null: false, default: "pending"
      add :rag_status, :string, null: false, default: "pending"
      add :identity_hash, :string
      add :digest_hash, :string
      add :artifact_path, :text
      add :rag_envelope_path, :text
      add :digest, :map
      add :source_updated_at, :utc_datetime_usec
      add :last_error, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :rag_ready_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:research_items, [:research_batch_id, :ticker])
    create index(:research_items, [:research_batch_id, :rag_status])
    create index(:research_items, [:status])

    create table(:alert_events) do
      add :research_batch_id, references(:research_batches, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :dedup_key, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :map, null: false, default: %{}
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_events, [:dedup_key])
    create index(:alert_events, [:status])
  end

  def down do
    drop table(:alert_events)
    drop table(:research_items)
    drop table(:evidence_runs)
    drop table(:research_batches)
    drop table(:universe_members)
    drop table(:universe_snapshots)
    Oban.Migrations.down()
  end
end
