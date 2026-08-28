defmodule GxPortfolioIntelligence.Schemas.ResearchBatch do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending collecting researching indexing degraded completed failed blocked)
  @batch_types ~w(eod adhoc)
  @research_modes ~w(eod live historical)
  @sources ~w(tradingagents_daily_research tradingagents_adhoc_research)

  schema "research_batches" do
    field :analysis_date, :date
    field :cutoff_at, :utc_datetime_usec
    field :batch_type, :string, default: "eod"
    field :research_mode, :string, default: "eod"
    field :analysis_depth, :string, default: "digest"
    field :source, :string, default: "tradingagents_daily_research"
    field :idempotency_key_hash, :string
    field :status, :string, default: "pending"
    field :target_count, :integer, default: 500
    field :completed_count, :integer, default: 0
    field :rag_ready_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :sla_ready_count, :integer, default: 490
    field :sla_status, :string, default: "pending"
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :sla_recovered_at, :utc_datetime_usec
    field :last_error, :string
    field :metadata, :map, default: %{}

    belongs_to :universe_snapshot, GxPortfolioIntelligence.Schemas.UniverseSnapshot
    has_many :items, GxPortfolioIntelligence.Schemas.ResearchItem
    has_one :full_analysis_batch, GxPortfolioIntelligence.Schemas.FullAnalysisBatch

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :analysis_date,
      :cutoff_at,
      :batch_type,
      :research_mode,
      :analysis_depth,
      :source,
      :idempotency_key_hash,
      :status,
      :target_count,
      :completed_count,
      :rag_ready_count,
      :failed_count,
      :sla_ready_count,
      :sla_status,
      :started_at,
      :completed_at,
      :sla_recovered_at,
      :last_error,
      :metadata,
      :universe_snapshot_id
    ])
    |> validate_required([
      :analysis_date,
      :cutoff_at,
      :batch_type,
      :research_mode,
      :source,
      :status,
      :target_count,
      :sla_ready_count
    ])
    |> validate_inclusion(:batch_type, @batch_types)
    |> validate_inclusion(:research_mode, @research_modes)
    |> validate_inclusion(:analysis_depth, ~w(digest full))
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:sla_status, ~w(pending met missed not_applicable))
    |> validate_format(:idempotency_key_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_number(:target_count, greater_than: 0, less_than_or_equal_to: 500)
    |> validate_number(:sla_ready_count, greater_than: 0, less_than_or_equal_to: 500)
    |> validate_sla_threshold()
    |> validate_batch_contract()
    |> unique_constraint(:analysis_date, name: :research_batches_eod_analysis_date_index)
    |> unique_constraint(:analysis_date,
      name: :research_batches_historical_analysis_date_index
    )
    |> unique_constraint(:idempotency_key_hash,
      name: :research_batches_idempotency_key_hash_index
    )
    |> check_constraint(:target_count, name: :research_batch_counts)
    |> check_constraint(:batch_type, name: :research_batch_type)
    |> check_constraint(:research_mode, name: :research_batch_mode)
    |> check_constraint(:analysis_depth, name: :research_batch_analysis_depth)
    |> check_constraint(:source, name: :research_batch_source)
    |> check_constraint(:status, name: :research_batch_status)
    |> check_constraint(:sla_status, name: :research_batch_sla_status)
  end

  defp validate_sla_threshold(changeset) do
    target = get_field(changeset, :target_count)
    threshold = get_field(changeset, :sla_ready_count)

    if is_integer(target) and is_integer(threshold) and threshold > target do
      add_error(changeset, :sla_ready_count, "must not exceed target_count")
    else
      changeset
    end
  end

  defp validate_batch_contract(changeset) do
    case {
      get_field(changeset, :batch_type),
      get_field(changeset, :research_mode),
      get_field(changeset, :source),
      get_field(changeset, :idempotency_key_hash),
      get_field(changeset, :sla_status)
    } do
      {"eod", "eod", "tradingagents_daily_research", nil, sla}
      when sla in ~w(pending met missed) ->
        changeset

      {"adhoc", mode, "tradingagents_adhoc_research", key, "not_applicable"}
      when mode in ~w(live historical) and is_binary(key) ->
        changeset

      {"adhoc", _mode, _, nil, _} ->
        add_error(changeset, :idempotency_key_hash, "is required for an ad-hoc batch")

      {"adhoc", _, _, key, "not_applicable"}
      when is_binary(key) ->
        add_error(changeset, :research_mode, "does not match ad-hoc policy")

      _ ->
        add_error(changeset, :batch_type, "does not match source or SLA policy")
    end
  end
end
