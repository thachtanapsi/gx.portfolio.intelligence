defmodule GxPortfolioIntelligence.Schemas.FullAnalysisRestartKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:idempotency_key_hash, :string, autogenerate: false}
  @foreign_key_type :id

  schema "full_analysis_restart_keys" do
    field :request_fingerprint, :string
    field :metadata, :map, default: %{}
    belongs_to :full_analysis_batch, GxPortfolioIntelligence.Schemas.FullAnalysisBatch
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :idempotency_key_hash,
      :request_fingerprint,
      :full_analysis_batch_id,
      :metadata
    ])
    |> validate_required([
      :idempotency_key_hash,
      :request_fingerprint,
      :full_analysis_batch_id
    ])
    |> validate_format(:idempotency_key_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:request_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint(:idempotency_key_hash)
    |> check_constraint(:idempotency_key_hash, name: :full_analysis_restart_hashes)
  end
end
