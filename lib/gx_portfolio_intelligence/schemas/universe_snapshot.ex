defmodule GxPortfolioIntelligence.Schemas.UniverseSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "universe_snapshots" do
    field :analysis_date, :date
    field :slot, :string
    field :cutoff_at, :utc_datetime_usec
    field :member_limit, :integer
    field :member_count, :integer, default: 0
    field :status, :string, default: "pending"
    field :frozen, :boolean, default: false
    field :fingerprint, :string
    field :artifact_path, :string
    field :metadata, :map, default: %{}

    has_many :members, GxPortfolioIntelligence.Schemas.UniverseMember
    has_many :research_batches, GxPortfolioIntelligence.Schemas.ResearchBatch
    has_one :trend_snapshot, GxPortfolioIntelligence.Schemas.TrendSnapshot

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :analysis_date,
      :slot,
      :cutoff_at,
      :member_limit,
      :member_count,
      :status,
      :frozen,
      :fingerprint,
      :artifact_path,
      :metadata
    ])
    |> validate_required([:analysis_date, :slot, :cutoff_at, :member_limit, :status])
    |> validate_number(:member_limit, greater_than: 0, less_than_or_equal_to: 600)
    |> validate_number(:member_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, ~w(pending running complete degraded failed skipped))
    |> unique_constraint([:analysis_date, :slot])
  end
end
