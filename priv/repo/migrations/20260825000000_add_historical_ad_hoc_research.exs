defmodule GxPortfolioIntelligence.Repo.Migrations.AddHistoricalAdHocResearch do
  use Ecto.Migration

  def up do
    alter table(:research_batches) do
      add :research_mode, :string, null: false, default: "eod"
    end

    execute("UPDATE research_batches SET research_mode = 'live' WHERE batch_type = 'adhoc'")

    create constraint(:research_batches, :research_batch_mode,
             check:
               "(batch_type = 'eod' AND research_mode = 'eod') OR " <>
                 "(batch_type = 'adhoc' AND research_mode IN ('live','historical'))"
           )

    create unique_index(:research_batches, [:analysis_date],
             name: :research_batches_historical_analysis_date_index,
             where: "batch_type = 'adhoc' AND research_mode = 'historical'"
           )

    create table(:research_batch_request_keys, primary_key: false) do
      add :idempotency_key_hash, :string, primary_key: true
      add :request_fingerprint, :string, null: false

      add :research_batch_id,
          references(:research_batches, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:research_batch_request_keys, [:research_batch_id])

    create constraint(:research_batch_request_keys, :research_batch_request_key_hashes,
             check:
               "idempotency_key_hash ~ '^[0-9a-f]{64}$' AND " <>
                 "request_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    INSERT INTO research_batch_request_keys
      (idempotency_key_hash, request_fingerprint, research_batch_id, inserted_at)
    SELECT idempotency_key_hash,
           metadata->>'request_fingerprint',
           id,
           inserted_at
    FROM research_batches
    WHERE batch_type = 'adhoc'
      AND idempotency_key_hash ~ '^[0-9a-f]{64}$'
      AND metadata->>'request_fingerprint' ~ '^[0-9a-f]{64}$'
    ON CONFLICT (idempotency_key_hash) DO NOTHING
    """)
  end

  def down do
    raise "irreversible: historical canonical batches and idempotency aliases are retained"
  end
end
