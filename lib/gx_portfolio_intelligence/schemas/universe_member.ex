defmodule GxPortfolioIntelligence.Schemas.UniverseMember do
  use Ecto.Schema
  import Ecto.Changeset

  schema "universe_members" do
    field :ticker, :string
    field :exchange, :string
    field :rank, :integer
    field :adtv20, :decimal
    field :adv20, :decimal
    field :metadata, :map, default: %{}

    belongs_to :universe_snapshot, GxPortfolioIntelligence.Schemas.UniverseSnapshot

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :universe_snapshot_id,
      :ticker,
      :exchange,
      :rank,
      :adtv20,
      :adv20,
      :metadata
    ])
    |> update_change(:ticker, &String.upcase/1)
    |> validate_required([:universe_snapshot_id, :ticker, :exchange, :rank, :adtv20, :adv20])
    |> validate_format(:ticker, ~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/)
    |> validate_number(:rank, greater_than: 0, less_than_or_equal_to: 600)
    |> unique_constraint([:universe_snapshot_id, :ticker])
    |> unique_constraint([:universe_snapshot_id, :rank])
  end
end
