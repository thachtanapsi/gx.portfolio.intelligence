defmodule GxPortfolioIntelligence.Repo.Migrations.AddAdHocResearchBatches do
  use Ecto.Migration

  def up do
    alter table(:research_batches) do
      add :batch_type, :string, null: false, default: "eod"
      add :source, :string, null: false, default: "tradingagents_daily_research"
      add :idempotency_key_hash, :string
    end

    drop_if_exists unique_index(:research_batches, [:analysis_date])

    create unique_index(:research_batches, [:analysis_date],
             name: :research_batches_eod_analysis_date_index,
             where: "batch_type = 'eod'"
           )

    create unique_index(:research_batches, [:idempotency_key_hash],
             name: :research_batches_idempotency_key_hash_index,
             where: "idempotency_key_hash IS NOT NULL"
           )

    create constraint(:research_batches, :research_batch_type,
             check: "batch_type IN ('eod','adhoc')"
           )

    create constraint(:research_batches, :research_batch_source,
             check:
               "source IN ('tradingagents_daily_research','tradingagents_adhoc_research')"
           )

    drop constraint(:research_batches, :research_batch_sla_status)

    create constraint(:research_batches, :research_batch_sla_status,
             check: "sla_status IN ('pending','met','missed','not_applicable')"
           )
  end

  def down do
    raise "irreversible: ad-hoc batches are retained permanently and can coexist with EOD batches"
  end
end
