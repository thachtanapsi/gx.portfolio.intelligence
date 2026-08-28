defmodule GxPortfolioIntelligence.Schemas.FullAnalysisItem do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running promoting complete failed blocked)
  @rag_statuses ~w(pending queued submitted indexing ready failed stale)

  schema "full_analysis_items" do
    field :ticker, :string
    field :selection_rank, :integer
    field :liquidity_rank, :integer
    field :status, :string, default: "pending"
    field :rag_status, :string, default: "pending"
    field :execution_key, :string
    field :execution_generation, :integer, default: 1
    field :expected_digest_hash, :string
    field :parent_identity_hash, :string
    field :identity_hash, :string
    field :session_path, :string
    field :envelope_path, :string
    field :full_report_hash, :string
    field :source_updated_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :promoted_at, :utc_datetime_usec
    field :last_error, :string
    field :metadata, :map, default: %{}

    belongs_to :full_analysis_batch, GxPortfolioIntelligence.Schemas.FullAnalysisBatch
    belongs_to :research_item, GxPortfolioIntelligence.Schemas.ResearchItem
    has_many :stage_runs, GxPortfolioIntelligence.Schemas.ResearchStageRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :full_analysis_batch_id,
      :research_item_id,
      :ticker,
      :selection_rank,
      :liquidity_rank,
      :status,
      :rag_status,
      :execution_key,
      :execution_generation,
      :expected_digest_hash,
      :parent_identity_hash,
      :identity_hash,
      :session_path,
      :envelope_path,
      :full_report_hash,
      :source_updated_at,
      :started_at,
      :completed_at,
      :promoted_at,
      :last_error,
      :metadata
    ])
    |> update_change(:ticker, &String.upcase/1)
    |> validate_required([
      :full_analysis_batch_id,
      :research_item_id,
      :ticker,
      :selection_rank,
      :liquidity_rank,
      :status,
      :rag_status,
      :execution_key,
      :execution_generation
    ])
    |> validate_format(:ticker, ~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/)
    |> validate_format(:execution_key, ~r/^[0-9a-f]{64}$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:rag_status, @rag_statuses)
    |> validate_number(:selection_rank, greater_than: 0)
    |> validate_number(:liquidity_rank, greater_than: 0, less_than_or_equal_to: 600)
    |> validate_number(:execution_generation, greater_than: 0)
    |> unique_constraint([:full_analysis_batch_id, :ticker])
    |> unique_constraint([:full_analysis_batch_id, :selection_rank])
    |> unique_constraint(:research_item_id)
    |> unique_constraint(:execution_key)
    |> check_constraint(:status, name: :full_analysis_item_status)
    |> check_constraint(:rag_status, name: :full_analysis_item_rag_status)
    |> check_constraint(:selection_rank, name: :full_analysis_item_rank)
  end
end
