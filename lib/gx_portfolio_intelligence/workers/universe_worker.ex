defmodule GxPortfolioIntelligence.Workers.UniverseWorker do
  use Oban.Worker,
    queue: :control,
    max_attempts: 5,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias GxPortfolioIntelligence.{
    Alerts,
    ArtifactStore,
    Calendar,
    FullAnalysis,
    Orchestrator,
    Repo,
    Research
  }

  alias GxPortfolioIntelligence.TradingAgents.Runner
  alias GxPortfolioIntelligence.Workers.{EvidenceWorker, TrendWorker}

  @impl true
  def perform(%Oban.Job{args: args}) do
    with {:ok, date} <- Date.from_iso8601(args["analysis_date"] || ""),
         {:ok, cutoff} <- resolve_cutoff(date, args),
         {:ok, output} <-
           ArtifactStore.path(["universes", Date.to_iso8601(date), args["slot"] <> ".json"]) do
      case cached_frozen_snapshot(date, cutoff, args) do
        {:ok, snapshot} -> finish_snapshot(snapshot, args)
        {:skipped, snapshot} -> maybe_bind_and_block_adhoc(args, snapshot, :non_trading_day)
        :missing -> execute_universe(date, cutoff, output, args)
        {:error, _} = error -> error
      end
    end
  end

  defp execute_universe(date, cutoff, output, args) do
    with {:ok, result} <-
           Runner.universe(
             date: date,
             cutoff: cutoff,
             slot: args["slot"],
             limit: args["limit"],
             price_mode: args["price_mode"] || "live",
             tickers: args["tickers"] || [],
             output: output
           ),
         :ok <- validate_result_identity(result, date, cutoff, args, output),
         :ok <- handle_result(result, args) do
      :ok
    end
  end

  defp cached_frozen_snapshot(date, cutoff, %{"frozen" => true} = args) do
    case Research.snapshot_for(date, args["slot"]) do
      %{frozen: true} = snapshot ->
        cond do
          snapshot.member_limit != args["limit"] or
            DateTime.compare(snapshot.cutoff_at, cutoff) != :eq or
            (snapshot.metadata["price_mode"] || "live") != (args["price_mode"] || "live") or
              not cached_selection_matches?(snapshot, args) ->
            {:error, :frozen_snapshot_identity_mismatch}

          snapshot.status == "skipped" ->
            {:skipped, Repo.preload(snapshot, :members)}

          true ->
            {:ok, Repo.preload(snapshot, :members)}
        end

      _ ->
        :missing
    end
  end

  defp cached_frozen_snapshot(_date, _cutoff, _args), do: :missing

  defp handle_result(%{"status" => status} = result, args)
       when status in ["skipped", "non_trading_day"] do
    case Research.persist_universe(result, args["frozen"] == true) do
      {:ok, snapshot} -> maybe_bind_and_block_adhoc(args, snapshot, :non_trading_day)
      {:error, _} = error -> error
    end
  end

  defp handle_result(%{"members" => []} = result, %{"batch_type" => "adhoc"} = args) do
    case Research.persist_universe(result, args["frozen"] == true) do
      {:ok, snapshot} ->
        maybe_bind_and_block_adhoc(args, snapshot, :requested_tickers_unavailable)

      {:error, _} = error ->
        error
    end
  end

  defp handle_result(%{"members" => []}, _args), do: {:error, :empty_universe}

  defp handle_result(result, args) do
    with {:ok, snapshot} <- Research.persist_universe(result, args["frozen"] == true) do
      finish_snapshot(snapshot, args)
    end
  end

  defp finish_snapshot(snapshot, args) do
    with {:ok, manifest} <- write_manifest(snapshot),
         {:ok, batch} <- maybe_create_or_bind_batch(args["batch_id"], snapshot),
         :ok <- maybe_alert_degraded(snapshot, batch),
         :ok <- maybe_schedule_final(snapshot, batch) do
      maybe_schedule_trend(snapshot, manifest, args)

      if not snapshot.frozen do
        Enum.each(~w(social media), fn lane ->
          EvidenceWorker.new(%{
            "snapshot_id" => snapshot.id,
            "lane" => lane,
            "slot" => snapshot.slot,
            "tickers_file" => manifest
          })
          |> Oban.insert()
        end)
      end

      :ok
    end
  end

  defp write_manifest(snapshot) do
    members = Enum.sort_by(snapshot.members, & &1.rank)

    ArtifactStore.write_json(
      ["manifests", Date.to_iso8601(snapshot.analysis_date), snapshot.slot <> ".json"],
      %{
        schema_version: "1.0",
        analysis_date: Date.to_iso8601(snapshot.analysis_date),
        cutoff: DateTime.to_iso8601(snapshot.cutoff_at),
        fingerprint: snapshot.fingerprint,
        members:
          Enum.map(
            members,
            &%{
              ticker: &1.ticker,
              exchange: &1.exchange,
              liquidity_rank: &1.rank,
              adtv20: Decimal.to_string(&1.adtv20, :normal),
              adv20: Decimal.to_string(&1.adv20, :normal),
              aliases: &1.metadata["aliases"] || []
            }
          )
      }
    )
  end

  defp maybe_create_or_bind_batch(nil, %{frozen: false}), do: {:ok, nil}

  defp maybe_create_or_bind_batch(nil, %{frozen: true} = snapshot) do
    with {:ok, cutoff} <- Calendar.cutoff_at(snapshot.analysis_date),
         {:ok, batch} <-
           Research.create_batch(%{
             analysis_date: snapshot.analysis_date,
             cutoff_at: cutoff,
             status:
               if(snapshot.member_count < snapshot.member_limit,
                 do: "degraded",
                 else: "collecting"
               ),
             target_count: snapshot.member_limit,
             sla_ready_count:
               min(
                 Application.get_env(:gx_portfolio_intelligence, :sla_ready_count, 490),
                 snapshot.member_limit
               )
           }) do
      Research.bind_snapshot_to_batch(batch, snapshot)
    end
  end

  defp maybe_create_or_bind_batch(batch_id, snapshot) do
    batch_id |> Research.get_batch!() |> Research.bind_snapshot_to_batch(snapshot)
  end

  defp validate_result_identity(result, date, cutoff, args, output) when is_map(result) do
    with {:ok, result_date} <- Date.from_iso8601(result["analysis_date"] || ""),
         true <- result_date == date,
         {:ok, result_cutoff, _} <- DateTime.from_iso8601(result["cutoff"] || ""),
         true <- DateTime.compare(result_cutoff, cutoff) == :eq,
         true <- result["slot"] == args["slot"],
         true <- result["target_count"] == args["limit"],
         true <- (result["price_mode"] || "live") == (args["price_mode"] || "live"),
         :ok <- validate_selection(result, args),
         true <- is_binary(result["fingerprint"]),
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, result["fingerprint"]),
         :ok <- validate_result_path(result, output) do
      :ok
    else
      _ -> {:error, :universe_identity_mismatch}
    end
  end

  defp validate_result_identity(_, _, _, _, _), do: {:error, :invalid_universe_contract}

  defp validate_result_path(%{"status" => status}, _output)
       when status in ["skipped", "non_trading_day"],
       do: :ok

  defp validate_result_path(result, output) do
    if result["artifact_path"] == output, do: :ok, else: {:error, :universe_artifact_mismatch}
  end

  defp maybe_alert_degraded(
         %{frozen: true, member_count: count},
         %{batch_type: "adhoc"} = batch
       )
       when count < batch.target_count do
    reason = :requested_tickers_unavailable

    with {:ok, blocked} <- Research.block_batch(batch, reason),
         {:ok, _alert} <-
           Alerts.emit(:batch_blocked, blocked, %{reason: Atom.to_string(reason)}) do
      :ok
    end
  end

  defp maybe_alert_degraded(%{frozen: true, member_count: count}, batch)
       when not is_nil(batch) and count < batch.target_count do
    case Alerts.emit(:batch_blocked, batch, %{reason: "universe_below_target"}) do
      {:ok, _alert} -> :ok
      {:error, _} = error -> error
    end
  end

  defp maybe_alert_degraded(_snapshot, _batch), do: :ok

  defp maybe_schedule_final(
         %{frozen: true, member_count: count},
         %{batch_type: "adhoc", target_count: count} = batch
       ) do
    case Orchestrator.ensure_final_pipeline(batch) do
      {:ok, _count} -> :ok
      {:error, _} = error -> error
    end
  end

  defp maybe_schedule_final(%{frozen: true}, %{batch_type: "adhoc"}), do: :ok

  defp maybe_schedule_final(%{frozen: true}, batch) when not is_nil(batch) do
    case Orchestrator.ensure_final_pipeline(batch) do
      {:ok, _count} -> :ok
      {:error, _} = error -> error
    end
  end

  defp maybe_schedule_final(_snapshot, _batch), do: :ok

  # Ad-hoc full analysis intentionally runs every requested ticker and does not
  # participate in the official top-500 hot selection. Scheduling a trend job
  # here would also reinterpret a live ad-hoc cutoff as the frozen 15:00 slot.
  defp maybe_schedule_trend(_snapshot, _manifest, %{"batch_type" => "adhoc"}), do: :ok

  defp maybe_schedule_trend(snapshot, manifest, _args) do
    if FullAnalysis.trend_enabled?() and snapshot.status in ["complete", "degraded"] do
      case TrendWorker.new(%{"snapshot_id" => snapshot.id, "manifest_path" => manifest})
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning("trend scheduling failed",
            error_code: GxPortfolioIntelligence.SafeError.code(reason)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp resolve_cutoff(date, %{"batch_type" => "adhoc", "cutoff" => value})
       when is_binary(value) do
    with {:ok, cutoff, _offset} <- DateTime.from_iso8601(value),
         {:ok, local} <- DateTime.shift_zone(cutoff, Calendar.timezone()),
         true <- DateTime.to_date(local) == date,
         true <- DateTime.compare(cutoff, DateTime.utc_now()) != :gt do
      {:ok, cutoff}
    else
      _ -> {:error, :invalid_adhoc_cutoff}
    end
  end

  defp resolve_cutoff(date, args), do: Calendar.at_slot(date, args["slot"])

  defp validate_selection(result, %{"batch_type" => "adhoc", "tickers" => tickers}) do
    members = result["members"] || []
    actual = Enum.map(members, & &1["ticker"])
    requested = Enum.sort(tickers)
    missing = Enum.sort(requested -- actual)

    cond do
      Enum.sort(result["requested_tickers"] || []) != requested ->
        {:error, :universe_selection_mismatch}

      result["selection_fingerprint"] != selection_fingerprint(requested) ->
        {:error, :universe_selection_mismatch}

      Enum.sort(result["missing_tickers"] || []) != missing ->
        {:error, :universe_selection_mismatch}

      Enum.any?(actual, &(&1 not in requested)) ->
        {:error, :universe_selection_mismatch}

      true ->
        :ok
    end
  end

  defp validate_selection(_result, _args), do: :ok

  defp cached_selection_matches?(snapshot, %{"batch_type" => "adhoc", "tickers" => tickers}) do
    snapshot.metadata["selection"] == "requested_tickers" and
      Enum.sort(snapshot.metadata["requested_tickers"] || []) == Enum.sort(tickers) and
      snapshot.metadata["selection_fingerprint"] == selection_fingerprint(Enum.sort(tickers))
  end

  defp cached_selection_matches?(_snapshot, _args), do: true

  defp selection_fingerprint(tickers) do
    tickers
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_block_adhoc(%{"batch_type" => "adhoc", "batch_id" => batch_id}, reason) do
    batch = Research.get_batch!(batch_id)

    with {:ok, blocked} <- Research.block_batch(batch, reason),
         {:ok, _alert} <- Alerts.emit(:batch_blocked, blocked, %{reason: Atom.to_string(reason)}) do
      :ok
    end
  end

  defp maybe_block_adhoc(_args, _reason), do: :ok

  defp maybe_bind_and_block_adhoc(
         %{"batch_type" => "adhoc", "batch_id" => batch_id} = args,
         snapshot,
         reason
       ) do
    with {:ok, _batch} <-
           batch_id |> Research.get_batch!() |> Research.bind_snapshot_to_batch(snapshot) do
      maybe_block_adhoc(args, reason)
    end
  end

  defp maybe_bind_and_block_adhoc(args, _snapshot, reason), do: maybe_block_adhoc(args, reason)
end
