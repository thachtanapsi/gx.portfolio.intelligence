defmodule GxPortfolioIntelligence.Schemas.TrendSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending complete degraded failed)

  schema "trend_snapshots" do
    field :analysis_date, :date
    field :cutoff_at, :utc_datetime_usec
    field :previous_cutoff_at, :utc_datetime_usec
    field :slot, :string
    field :status, :string, default: "pending"
    field :target_count, :integer
    field :scored_count, :integer, default: 0
    field :selected_count, :integer, default: 0
    field :universe_fingerprint, :string
    field :fingerprint, :string
    field :weights, :map, default: %{}
    field :warnings, {:array, :string}, default: []
    field :artifact_path, :string
    field :frozen, :boolean, default: false
    field :last_error, :string
    field :metadata, :map, default: %{}

    belongs_to :universe_snapshot, GxPortfolioIntelligence.Schemas.UniverseSnapshot
    has_many :members, GxPortfolioIntelligence.Schemas.TrendMember
    has_many :full_analysis_batches, GxPortfolioIntelligence.Schemas.FullAnalysisBatch

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :universe_snapshot_id,
      :analysis_date,
      :cutoff_at,
      :previous_cutoff_at,
      :slot,
      :status,
      :target_count,
      :scored_count,
      :selected_count,
      :universe_fingerprint,
      :fingerprint,
      :weights,
      :warnings,
      :artifact_path,
      :frozen,
      :last_error,
      :metadata
    ])
    |> validate_required([
      :universe_snapshot_id,
      :analysis_date,
      :cutoff_at,
      :slot,
      :status,
      :target_count,
      :universe_fingerprint
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:target_count, greater_than: 0, less_than_or_equal_to: 600)
    |> validate_number(:scored_count, greater_than_or_equal_to: 0)
    |> validate_number(:selected_count, greater_than_or_equal_to: 0)
    |> validate_format(:universe_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:fingerprint, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint([:analysis_date, :slot])
    |> check_constraint(:status, name: :trend_snapshot_status)
    |> check_constraint(:target_count, name: :trend_snapshot_counts)
  end
end
