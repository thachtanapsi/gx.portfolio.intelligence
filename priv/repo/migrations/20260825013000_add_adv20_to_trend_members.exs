defmodule GxPortfolioIntelligence.Repo.Migrations.AddAdv20ToTrendMembers do
  use Ecto.Migration

  def up do
    alter table(:trend_members) do
      add :adv20, :decimal, precision: 24, scale: 4
    end

    # Existing pre-release trend rows predate the wire field. Recover ADV20 from
    # the exact immutable universe snapshot that produced each trend snapshot.
    # ADTV20 is traded value while ADV20 is volume, so the two must never be
    # substituted for one another. The following NOT NULL change deliberately
    # fails closed if an orphaned legacy row cannot be matched.
    execute("""
    UPDATE trend_members AS tm
    SET adv20 = um.adv20
    FROM trend_snapshots AS ts
    JOIN universe_members AS um
      ON um.universe_snapshot_id = ts.universe_snapshot_id
    WHERE tm.trend_snapshot_id = ts.id
      AND tm.ticker = um.ticker
      AND tm.adv20 IS NULL
    """)

    alter table(:trend_members) do
      modify :adv20, :decimal, precision: 24, scale: 4, null: false
    end

    create constraint(:trend_members, :trend_member_adv20, check: "adv20 > 0")
  end

  def down do
    drop constraint(:trend_members, :trend_member_adv20)

    alter table(:trend_members) do
      remove :adv20
    end
  end
end
