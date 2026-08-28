defmodule GxPortfolioIntelligenceWeb.FullAnalysisController do
  use GxPortfolioIntelligenceWeb, :controller

  alias GxPortfolioIntelligence.{FullAnalysis, FullReportResponse, RAG, Research}
  alias GxPortfolioIntelligenceWeb.Serializers

  def show(conn, %{"id" => research_batch_id}) do
    with batch when not is_nil(batch) <- Research.get_batch(research_batch_id),
         full when not is_nil(full) <- FullAnalysis.get_batch_for_research(batch.id) do
      json(conn, %{data: Serializers.full_batch(full)})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "full_analysis_not_found"}})
    end
  end

  def items(conn, %{"id" => research_batch_id} = params) do
    with batch when not is_nil(batch) <- Research.get_batch(research_batch_id),
         full when not is_nil(full) <- FullAnalysis.get_batch_for_research(batch.id),
         {:ok, limit} <- integer_param(params["limit"], 50, 1, 100),
         {:ok, offset} <- integer_param(params["offset"], 0, 0, 1_000_000) do
      items =
        FullAnalysis.list_items(full.id,
          limit: limit,
          offset: offset,
          ticker: blank(params["ticker"]),
          status: blank(params["status"])
        )

      json(conn, %{
        data: Enum.map(items, &Serializers.full_item/1),
        pagination: %{limit: limit, offset: offset, returned: length(items)}
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "full_analysis_not_found"}})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: %{code: to_string(reason)}})
    end
  end

  def stages(conn, %{"id" => research_batch_id, "ticker" => ticker}) do
    with batch when not is_nil(batch) <- Research.get_batch(research_batch_id),
         full when not is_nil(full) <- FullAnalysis.get_batch_for_research(batch.id),
         item when not is_nil(item) <- FullAnalysis.item_for_ticker(full.id, ticker) do
      json(conn, %{
        data: %{
          item: Serializers.full_item(item),
          stages: item.id |> FullAnalysis.list_stages() |> Enum.map(&Serializers.stage/1)
        }
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "full_analysis_item_not_found"}})
    end
  end

  def report(conn, %{"id" => research_batch_id, "ticker" => ticker}) do
    with batch when not is_nil(batch) <- Research.get_batch(research_batch_id),
         full when not is_nil(full) <- FullAnalysis.get_batch_for_research(batch.id),
         item when not is_nil(item) <- FullAnalysis.item_for_ticker(full.id, ticker),
         true <-
           item.status == "complete" and item.rag_status == "ready" and
             not is_nil(item.promoted_at),
         {:ok, response} <- RAG.full_report(batch.id, item.ticker),
         {:ok, data} <- FullReportResponse.validate(response, report_expected(batch, item)) do
      json(conn, %{data: data})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "full_analysis_item_not_found"}})

      false ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "full_report_not_ready"}})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "full_report_unavailable"}})
    end
  end

  def retry(conn, %{"id" => research_batch_id} = params) do
    with batch when not is_nil(batch) <- Research.get_batch(research_batch_id),
         full when not is_nil(full) <- FullAnalysis.get_batch_for_research(batch.id) do
      perform_retry(conn, batch, full, Map.drop(params, ["id"]))
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "full_analysis_not_found"}})

      {:error, _} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "full_analysis_retry_not_scheduled"}})
    end
  end

  defp perform_retry(conn, batch, full, params) when params in [%{}, %{"mode" => "resume"}] do
    case FullAnalysis.retry(full) do
      {:ok, count} ->
        conn
        |> put_status(:accepted)
        |> json(%{
          data: %{
            mode: "resume",
            research_batch_id: batch.id,
            full_analysis_batch_id: full.id,
            retry_items: count
          }
        })

      {:error, _} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "full_analysis_retry_not_scheduled"}})
    end
  end

  defp perform_retry(conn, batch, full, %{"mode" => "restart", "tickers" => tickers} = params) do
    if Enum.sort(Map.keys(params)) == ["mode", "tickers"] do
      with {:ok, key} <- idempotency_key(conn),
           {:ok, count, replayed} <- FullAnalysis.restart(full, key, tickers) do
        conn
        |> put_status(:accepted)
        |> json(%{
          data: %{
            mode: "restart",
            research_batch_id: batch.id,
            full_analysis_batch_id: full.id,
            restart_items: count,
            replayed: replayed
          }
        })
      else
        {:error, reason}
        when reason in [
               :idempotency_conflict,
               :full_analysis_already_promoted,
               :full_analysis_restart_not_allowed
             ] ->
          conn |> put_status(:conflict) |> json(%{error: %{code: to_string(reason)}})

        {:error, reason}
        when reason in [
               :missing_idempotency_key,
               :invalid_idempotency_key,
               :invalid_restart_tickers
             ] ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: to_string(reason)}})

        {:error, _} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: %{code: "full_analysis_restart_not_scheduled"}})
      end
    else
      conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_retry_fields"}})
    end
  end

  defp perform_retry(conn, _batch, _full, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: %{code: "invalid_retry_fields"}})

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      [] -> {:error, :missing_idempotency_key}
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  defp report_expected(batch, item) do
    %{
      source: batch.source,
      ticker: item.ticker,
      analysis_date: batch.analysis_date,
      cutoff_at: batch.cutoff_at,
      liquidity_rank: item.liquidity_rank,
      research_mode: batch.research_mode,
      data_provenance:
        batch.metadata["data_provenance"] ||
          if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff"),
      identity_hash: item.identity_hash,
      parent_identity_hash: item.parent_identity_hash,
      expected_digest_hash: item.expected_digest_hash,
      execution_generation: item.execution_generation,
      full_report_hash: item.full_report_hash
    }
  end

  defp integer_param(nil, default, _min, _max), do: {:ok, default}

  defp integer_param(value, _default, min, max) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> {:error, :invalid_pagination}
    end
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
