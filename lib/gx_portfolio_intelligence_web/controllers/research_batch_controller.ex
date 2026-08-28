defmodule GxPortfolioIntelligenceWeb.ResearchBatchController do
  use GxPortfolioIntelligenceWeb, :controller

  alias GxPortfolioIntelligence.{Orchestrator, Research}

  def create(conn, params) do
    with {:ok, date} <- parse_date(params["analysis_date"]),
         {:ok, limit} <- integer_param(params["limit"], 500, 1, 500),
         {:ok, operation} <- Orchestrator.create_manual_batch(date, limit) do
      conn |> put_status(:accepted) |> json(%{data: operation})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch", details: errors(changeset)}})

      {:error, reason} ->
        require Logger

        Logger.warning("manual batch scheduling failed",
          error_code: GxPortfolioIntelligence.SafeError.code(reason)
        )

        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "batch_not_created"}})
    end
  end

  def create_adhoc(conn, params) do
    with :ok <- validate_adhoc_params(params),
         {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, operation} <-
           Orchestrator.create_adhoc_batch(
             params["tickers"],
             idempotency_key,
             adhoc_analysis_date(params),
             adhoc_analysis_depth(params)
           ) do
      conn
      |> put_resp_header("location", "/api/v1/research-batches/#{operation.batch_id}")
      |> put_status(:accepted)
      |> json(%{data: operation})
    else
      {:error, :idempotency_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "idempotency_conflict"}})

      {:error, :historical_batch_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "historical_batch_conflict"}})

      {:error, reason}
      when reason in [
             :missing_idempotency_key,
             :invalid_idempotency_key,
             :invalid_tickers,
             :invalid_ticker_count,
             :invalid_ticker,
             :duplicate_ticker,
             :invalid_adhoc_fields,
             :invalid_analysis_date,
             :future_analysis_date,
             :invalid_analysis_depth
           ] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: to_string(reason)}})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_adhoc_batch", details: errors(changeset)}})

      {:error, reason} ->
        require Logger

        Logger.warning("ad-hoc batch scheduling failed",
          error_code: GxPortfolioIntelligence.SafeError.code(reason)
        )

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "adhoc_batch_not_scheduled"}})
    end
  end

  def index(conn, params) do
    with {:ok, limit} <- integer_param(params["limit"], 50, 1, 100),
         {:ok, date} <- optional_date(params["analysis_date"]),
         {:ok, batch_type} <- optional_batch_type(params["batch_type"]) do
      batches = Research.list_batches(limit: limit, analysis_date: date, batch_type: batch_type)
      full = GxPortfolioIntelligence.FullAnalysis.batch_summary_map(Enum.map(batches, & &1.id))
      json(conn, %{data: Enum.map(batches, &Serializers.batch(&1, full[&1.id]))})
    else
      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: %{code: to_string(reason)}})
    end
  end

  def show(conn, %{"id" => id}) do
    case Research.get_batch(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "not_found"}})

      batch ->
        full = GxPortfolioIntelligence.FullAnalysis.get_batch_for_research(batch.id)
        json(conn, %{data: Serializers.batch(batch, full)})
    end
  end

  def items(conn, %{"id" => id} = params) do
    with batch when not is_nil(batch) <- Research.get_batch(id),
         {:ok, limit} <- integer_param(params["limit"], 50, 1, 100),
         {:ok, offset} <- integer_param(params["offset"], 0, 0, 1_000_000) do
      items =
        Research.list_items(batch.id,
          limit: limit,
          offset: offset,
          status: blank_to_nil(params["status"]),
          ticker: blank_to_nil(params["ticker"])
        )

      full = GxPortfolioIntelligence.FullAnalysis.item_api_summaries(items, batch)

      json(conn, %{
        data: Enum.map(items, &Serializers.item(&1, full[&1.id])),
        pagination: %{limit: limit, offset: offset, returned: length(items)}
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "not_found"}})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: %{code: to_string(reason)}})
    end
  end

  def retry(conn, %{"id" => id}) do
    case Research.get_batch(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "not_found"}})

      batch ->
        case Orchestrator.retry(batch) do
          {:ok, count} ->
            conn
            |> put_status(:accepted)
            |> json(%{data: %{batch_id: batch.id, retry_items: count}})

          {:error, _reason} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: %{code: "retry_not_scheduled"}})
        end
    end
  end

  defp parse_date(nil), do: {:ok, GxPortfolioIntelligence.Calendar.today()}
  defp parse_date(value), do: Date.from_iso8601(value)

  defp optional_date(nil), do: {:ok, nil}
  defp optional_date(value), do: Date.from_iso8601(value)

  defp optional_batch_type(nil), do: {:ok, nil}
  defp optional_batch_type(value) when value in ["eod", "adhoc"], do: {:ok, value}
  defp optional_batch_type(_), do: {:error, :invalid_batch_type}

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      [] -> {:error, :missing_idempotency_key}
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  defp validate_adhoc_params(%{"tickers" => _} = params) do
    keys = params |> Map.keys() |> Enum.sort()

    if keys in [
         ["tickers"],
         ["analysis_date", "tickers"],
         ["analysis_depth", "tickers"],
         ["analysis_date", "analysis_depth", "tickers"]
       ],
       do: :ok,
       else: {:error, :invalid_adhoc_fields}
  end

  defp validate_adhoc_params(_), do: {:error, :invalid_adhoc_fields}

  defp adhoc_analysis_date(params) do
    if Map.has_key?(params, "analysis_date"), do: params["analysis_date"], else: :omitted
  end

  defp adhoc_analysis_depth(params) do
    if Map.has_key?(params, "analysis_depth"), do: params["analysis_depth"], else: :omitted
  end

  defp integer_param(nil, default, _min, _max), do: {:ok, default}

  defp integer_param(value, _default, min, max) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= min and integer <= max -> {:ok, integer}
      _ -> {:error, :invalid_pagination}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
