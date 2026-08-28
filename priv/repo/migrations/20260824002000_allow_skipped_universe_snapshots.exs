defmodule GxPortfolioIntelligence.Repo.Migrations.AllowSkippedUniverseSnapshots do
  use Ecto.Migration

  def up do
    drop constraint(:universe_snapshots, :universe_snapshot_status)

    create constraint(:universe_snapshots, :universe_snapshot_status,
             check: "status IN ('pending','running','complete','degraded','failed','skipped')"
           )
  end

  def down do
    drop constraint(:universe_snapshots, :universe_snapshot_status)

    create constraint(:universe_snapshots, :universe_snapshot_status,
             check: "status IN ('pending','running','complete','degraded','failed')"
           )
  end
end
