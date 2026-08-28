defmodule GxPortfolioIntelligence.Schemas.ResearchBatchRequestKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "research_batch_request_keys" do
    field :idempotency_key_hash, :string, primary_key: true
    field :request_fingerprint, :string

    belongs_to :research_batch, GxPortfolioIntelligence.Schemas.ResearchBatch

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(request_key, attrs) do
    request_key
    |> cast(attrs, [:idempotency_key_hash, :request_fingerprint, :research_batch_id])
    |> validate_required([:idempotency_key_hash, :request_fingerprint, :research_batch_id])
    |> validate_format(:idempotency_key_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:request_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint(:idempotency_key_hash, name: :research_batch_request_keys_pkey)
    |> foreign_key_constraint(:research_batch_id)
    |> check_constraint(:idempotency_key_hash, name: :research_batch_request_key_hashes)
  end
end
