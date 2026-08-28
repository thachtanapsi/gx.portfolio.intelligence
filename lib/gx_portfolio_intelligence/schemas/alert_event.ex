defmodule GxPortfolioIntelligence.Schemas.AlertEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "alert_events" do
    field :event_type, :string
    field :dedup_key, :string
    field :status, :string, default: "pending"
    field :payload, :map, default: %{}
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :delivered_at, :utc_datetime_usec

    belongs_to :research_batch, GxPortfolioIntelligence.Schemas.ResearchBatch

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_type,
      :dedup_key,
      :status,
      :payload,
      :attempts,
      :last_error,
      :delivered_at,
      :research_batch_id
    ])
    |> validate_required([:event_type, :dedup_key, :status])
    |> validate_inclusion(
      :event_type,
      ~w(batch_sla_missed batch_blocked batch_recovered dependency_unhealthy)
    )
    |> validate_inclusion(:status, ~w(pending delivered failed))
    |> unique_constraint(:dedup_key)
  end
end
