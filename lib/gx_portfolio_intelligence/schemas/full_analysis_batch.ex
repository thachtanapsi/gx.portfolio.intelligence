defmodule GxPortfolioIntelligence.Schemas.FullAnalysisBatch do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running promoting completed degraded blocked)

  schema "full_analysis_batches" do
    field :status, :string, default: "pending"
    field :target_count, :integer, default: 0
    field :completed_count, :integer, default: 0
    field :promoted_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :blocked_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_error, :string
    field :metadata, :map, default: %{}

    belongs_to :research_batch, GxPortfolioIntelligence.Schemas.ResearchBatch
    belongs_to :trend_snapshot, GxPortfolioIntelligence.Schemas.TrendSnapshot
    has_many :items, GxPortfolioIntelligence.Schemas.FullAnalysisItem

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :research_batch_id,
      :trend_snapshot_id,
      :status,
      :target_count,
      :completed_count,
      :promoted_count,
      :failed_count,
      :blocked_count,
      :started_at,
      :completed_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:research_batch_id, :status, :target_count])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:target_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:research_batch_id)
    |> check_constraint(:status, name: :full_analysis_batch_status)
    |> check_constraint(:target_count, name: :full_analysis_batch_counts)
  end
end
