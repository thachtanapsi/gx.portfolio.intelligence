defmodule GxPortfolioIntelligence.Schemas.EvidenceRun do
  use Ecto.Schema
  import Ecto.Changeset

  schema "evidence_runs" do
    field :analysis_date, :date
    field :slot, :string
    field :lane, :string
    field :status, :string, default: "pending"
    field :target_count, :integer, default: 0
    field :processed_count, :integer, default: 0
    field :succeeded_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :watermark, :map, default: %{}
    field :idempotency_key, :string
    field :last_error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :universe_snapshot, GxPortfolioIntelligence.Schemas.UniverseSnapshot

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :analysis_date,
      :slot,
      :lane,
      :status,
      :target_count,
      :processed_count,
      :succeeded_count,
      :failed_count,
      :watermark,
      :idempotency_key,
      :last_error,
      :started_at,
      :completed_at,
      :universe_snapshot_id
    ])
    |> validate_required([:analysis_date, :slot, :lane, :status, :idempotency_key])
    |> validate_inclusion(:lane, ~w(social media macro))
    |> validate_inclusion(:status, ~w(pending running complete degraded failed))
    |> unique_constraint([:analysis_date, :slot, :lane])
    |> unique_constraint(:idempotency_key)
  end
end
