defmodule GxPortfolioIntelligence.Repo.Migrations.AddSlaRecoveryTimestamp do
  use Ecto.Migration

  def change do
    alter table(:research_batches) do
      add :sla_recovered_at, :utc_datetime_usec
    end
  end
end
