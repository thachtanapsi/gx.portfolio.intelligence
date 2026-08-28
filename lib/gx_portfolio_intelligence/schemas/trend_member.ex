defmodule GxPortfolioIntelligence.Schemas.TrendMember do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trend_members" do
    field :ticker, :string
    field :liquidity_rank, :integer
    field :adtv20, :decimal
    field :adv20, :decimal
    field :market_core_available, :boolean, default: false
    field :volume_ratio, :decimal
    field :daily_move_abs_pct, :decimal
    field :momentum20_abs_pct, :decimal
    field :social_attention_velocity, :decimal
    field :media_event_velocity, :decimal
    field :coverage, :map, default: %{}
    field :trend_score, :decimal
    field :selected, :boolean, default: false
    field :selection_rank, :integer
    field :pinned, :boolean, default: false
    field :metadata, :map, default: %{}

    belongs_to :trend_snapshot, GxPortfolioIntelligence.Schemas.TrendSnapshot

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :trend_snapshot_id,
      :ticker,
      :liquidity_rank,
      :adtv20,
      :adv20,
      :market_core_available,
      :volume_ratio,
      :daily_move_abs_pct,
      :momentum20_abs_pct,
      :social_attention_velocity,
      :media_event_velocity,
      :coverage,
      :trend_score,
      :selected,
      :selection_rank,
      :pinned,
      :metadata
    ])
    |> update_change(:ticker, &String.upcase/1)
    |> validate_required([
      :trend_snapshot_id,
      :ticker,
      :liquidity_rank,
      :adtv20,
      :adv20,
      :market_core_available
    ])
    |> validate_format(:ticker, ~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/)
    |> validate_number(:liquidity_rank, greater_than: 0, less_than_or_equal_to: 600)
    |> validate_number(:adv20, greater_than: 0)
    |> unique_constraint([:trend_snapshot_id, :ticker])
    |> unique_constraint([:trend_snapshot_id, :liquidity_rank])
    |> unique_constraint([:trend_snapshot_id, :selection_rank])
    |> check_constraint(:liquidity_rank, name: :trend_member_rank)
    |> check_constraint(:selected, name: :trend_member_selection)
    |> check_constraint(:adv20, name: :trend_member_adv20)
  end
end
