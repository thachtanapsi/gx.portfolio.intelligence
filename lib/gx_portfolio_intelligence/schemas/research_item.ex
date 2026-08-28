defmodule GxPortfolioIntelligence.Schemas.ResearchItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "research_items" do
    field :ticker, :string
    field :liquidity_rank, :integer
    field :status, :string, default: "pending"
    field :llm_status, :string, default: "pending"
    field :rag_status, :string, default: "pending"
    field :identity_hash, :string
    field :digest_hash, :string
    field :artifact_path, :string
    field :rag_envelope_path, :string
    field :digest, :map
    field :source_updated_at, :utc_datetime_usec
    field :last_error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :rag_ready_at, :utc_datetime_usec

    belongs_to :research_batch, GxPortfolioIntelligence.Schemas.ResearchBatch
    has_one :full_analysis_item, GxPortfolioIntelligence.Schemas.FullAnalysisItem

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :research_batch_id,
      :ticker,
      :liquidity_rank,
      :status,
      :llm_status,
      :rag_status,
      :identity_hash,
      :digest_hash,
      :artifact_path,
      :rag_envelope_path,
      :digest,
      :source_updated_at,
      :last_error,
      :started_at,
      :completed_at,
      :rag_ready_at
    ])
    |> update_change(:ticker, &String.upcase/1)
    |> validate_required([:research_batch_id, :ticker, :liquidity_rank, :status])
    |> validate_format(:ticker, ~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/)
    |> validate_inclusion(:status, ~w(pending running complete partial failed))
    |> validate_inclusion(:llm_status, ~w(pending claimed complete partial failed skipped))
    |> validate_inclusion(:rag_status, ~w(pending queued submitted indexing ready failed stale))
    |> unique_constraint([:research_batch_id, :ticker])
    |> unique_constraint([:research_batch_id, :liquidity_rank],
      name: :research_items_batch_rank_index
    )
    |> check_constraint(:liquidity_rank, name: :research_item_rank)
    |> check_constraint(:status, name: :research_item_status)
    |> check_constraint(:llm_status, name: :research_item_llm_status)
    |> check_constraint(:rag_status, name: :research_item_rag_status)
  end
end
