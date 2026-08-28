defmodule GxPortfolioIntelligence.Repo.Migrations.AddFullAnalysisStageLeases do
  use Ecto.Migration

  def up do
    alter table(:research_stage_runs) do
      add :claim_key, :string
      add :lease_expires_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 0
    end

    drop constraint(:research_stage_runs, :research_stage_ordinal)

    create constraint(:research_stage_runs, :research_stage_ordinal,
             check: "ordinal > 0 AND ordinal <= 7 AND attempt_count >= 0"
           )

    create constraint(:research_stage_runs, :research_stage_claim,
             check:
               "(status = 'running' AND claim_key IS NOT NULL AND lease_expires_at IS NOT NULL) OR " <>
                 "(status <> 'running' AND claim_key IS NULL AND lease_expires_at IS NULL)"
           )
  end

  def down do
    drop constraint(:research_stage_runs, :research_stage_claim)
    drop constraint(:research_stage_runs, :research_stage_ordinal)

    alter table(:research_stage_runs) do
      remove :claim_key
      remove :lease_expires_at
      remove :attempt_count
    end

    create constraint(:research_stage_runs, :research_stage_ordinal,
             check: "ordinal > 0 AND ordinal <= 7"
           )
  end
end
