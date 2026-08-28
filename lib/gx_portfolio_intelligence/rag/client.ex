defmodule GxPortfolioIntelligence.RAG.ClientBehaviour do
  @moduledoc false

  @callback put_batch(map()) :: {:ok, map()} | {:error, term()}
  @callback put_documents(integer(), [map()]) :: {:ok, map()} | {:error, term()}
  @callback promote(integer(), [map()]) :: {:ok, map()} | {:error, term()}
  @callback seal(integer()) :: {:ok, map()} | {:error, term()}
  @callback status(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback full_report(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback health() :: {:ok, map()} | {:error, term()}
  @optional_callbacks promote: 2
end

defmodule GxPortfolioIntelligence.RAG do
  @moduledoc false

  defp client, do: Application.fetch_env!(:gx_portfolio_intelligence, :rag_client)

  def put_batch(batch), do: client().put_batch(batch)
  def put_documents(batch_id, documents), do: client().put_documents(batch_id, documents)
  def promote(batch_id, documents), do: client().promote(batch_id, documents)
  def seal(batch_id), do: client().seal(batch_id)
  def status(batch_id, opts \\ []), do: client().status(batch_id, opts)
  def full_report(batch_id, ticker), do: client().full_report(batch_id, ticker)
  def health, do: client().health()
end

defmodule GxPortfolioIntelligence.RAG.Client do
  @behaviour GxPortfolioIntelligence.RAG.ClientBehaviour

  @impl true
  def put_batch(batch) do
    request(:put, "/internal/v1/digest-batches/#{batch.id}", %{
      analysis_date: Date.to_iso8601(batch.analysis_date),
      cutoff: DateTime.to_iso8601(batch.cutoff_at),
      target_count: batch.target_count,
      source: batch.source,
      research_mode: batch.research_mode,
      data_provenance:
        batch.metadata["data_provenance"] ||
          if(batch.batch_type == "eod", do: "eod_cutoff", else: "request_cutoff")
    })
  end

  @impl true
  def put_documents(batch_id, documents) when length(documents) <= 50 do
    request(:post, "/internal/v1/digest-batches/#{batch_id}/documents:batch", %{
      documents: documents
    })
  end

  def put_documents(_batch_id, _documents), do: {:error, :too_many_documents}

  @impl true
  def promote(batch_id, documents) when length(documents) <= 50 do
    request(:post, "/internal/v1/digest-batches/#{batch_id}/documents:promote", %{
      documents: documents
    })
  end

  def promote(_batch_id, _documents), do: {:error, :too_many_documents}

  @impl true
  def seal(batch_id), do: request(:post, "/internal/v1/digest-batches/#{batch_id}:seal", %{})

  @impl true
  def status(batch_id, opts) do
    query = URI.encode_query(%{page: opts[:page] || 1, page_size: opts[:page_size] || 50})
    request(:get, "/internal/v1/digest-batches/#{batch_id}?#{query}", nil)
  end

  @impl true
  def full_report(batch_id, ticker) when is_integer(batch_id) and is_binary(ticker) do
    ticker = String.upcase(ticker)

    if Regex.match?(~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/, ticker) do
      request(
        :get,
        "/internal/v1/digest-batches/#{batch_id}/documents/#{ticker}/full-report",
        nil
      )
    else
      {:error, :invalid_ticker}
    end
  end

  def full_report(_batch_id, _ticker), do: {:error, :invalid_full_report_identity}

  @impl true
  def health, do: request(:get, "/api/health", nil)

  defp request(method, path, body) do
    config = Application.get_env(:gx_portfolio_intelligence, :rag, [])
    base_url = config[:base_url]
    api_key = config[:api_key]

    cond do
      not is_binary(base_url) or not String.starts_with?(base_url, ["http://", "https://"]) ->
        {:error, :invalid_rag_url}

      not is_binary(api_key) or api_key == "" ->
        {:error, :rag_api_key_not_configured}

      true ->
        url = String.trim_trailing(base_url, "/") <> path
        headers = [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}]
        encoded = if is_nil(body), do: nil, else: Jason.encode_to_iodata!(body)

        finch =
          Application.get_env(:gx_portfolio_intelligence, :finch, [])[:name] ||
            GxPortfolioIntelligence.Finch

        case Finch.build(method, url, headers, encoded)
             |> Finch.request(finch, receive_timeout: config[:timeout_ms] || 60_000) do
          {:ok, %Finch.Response{status: status, body: response}} when status in 200..299 ->
            decode_response(response)

          {:ok, %Finch.Response{status: status}} ->
            {:error, {:rag_http_error, status}}

          {:error, reason} ->
            {:error, {:rag_unavailable, reason}}
        end
    end
  end

  defp decode_response(""), do: {:ok, %{}}

  defp decode_response(response) do
    case Jason.decode(response) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_rag_response}
    end
  end
end
