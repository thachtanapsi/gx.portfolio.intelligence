defmodule GxPortfolioIntelligence.Repo.Migrations.AddFullAnalysisRestartKeys do
  use Ecto.Migration

  def up do
    create table(:full_analysis_restart_keys, primary_key: false) do
      add :idempotency_key_hash, :string, primary_key: true
      add :request_fingerprint, :string, null: false

      add :full_analysis_batch_id,
          references(:full_analysis_batches, on_delete: :restrict),
          null: false

      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:full_analysis_restart_keys, [:full_analysis_batch_id])

    create constraint(:full_analysis_restart_keys, :full_analysis_restart_hashes,
             check:
               "idempotency_key_hash ~ '^[0-9a-f]{64}$' AND " <>
                 "request_fingerprint ~ '^[0-9a-f]{64}$'"
           )
  end

  def down do
    drop table(:full_analysis_restart_keys)
  end
end
