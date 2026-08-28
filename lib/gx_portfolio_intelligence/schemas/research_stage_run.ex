defmodule GxPortfolioIntelligence.Schemas.ResearchStageRun do
  use Ecto.Schema
  import Ecto.Changeset

  @stages ~w(market sentiment news fundamentals research trader risk)
  @statuses ~w(pending running complete partial unavailable failed)

  schema "research_stage_runs" do
    field :stage, :string
    field :ordinal, :integer
    field :status, :string, default: "pending"
    field :claim_key, :string
    field :lease_expires_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :input_fingerprint, :string
    field :output_fingerprint, :string
    field :artifact_path, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_error, :string
    field :metadata, :map, default: %{}

    belongs_to :full_analysis_item, GxPortfolioIntelligence.Schemas.FullAnalysisItem

    timestamps(type: :utc_datetime_usec)
  end

  def stages, do: @stages

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :full_analysis_item_id,
      :stage,
      :ordinal,
      :status,
      :claim_key,
      :lease_expires_at,
      :attempt_count,
      :input_fingerprint,
      :output_fingerprint,
      :artifact_path,
      :started_at,
      :completed_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:full_analysis_item_id, :stage, :ordinal, :status])
    |> validate_inclusion(:stage, @stages)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:ordinal, greater_than: 0, less_than_or_equal_to: 7)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_format(:claim_key, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint([:full_analysis_item_id, :stage])
    |> unique_constraint([:full_analysis_item_id, :ordinal])
    |> check_constraint(:stage, name: :research_stage_name)
    |> check_constraint(:status, name: :research_stage_status)
    |> check_constraint(:ordinal, name: :research_stage_ordinal)
    |> check_constraint(:status, name: :research_stage_claim)
  end
end
