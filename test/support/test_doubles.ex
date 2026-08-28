defmodule GxPortfolioIntelligence.TestRunner do
  @behaviour GxPortfolioIntelligence.TradingAgents.Runner
  def universe(_opts), do: {:error, :not_configured}
  def collect(_opts), do: {:error, :not_configured}
  def run_one(_opts), do: {:error, :not_configured}
  def status(_opts), do: {:error, :not_configured}
  def trend(_opts), do: {:error, :not_configured}
  def analysis_init(_opts), do: {:error, :not_configured}
  def analysis_run_stage(_opts), do: {:error, :not_configured}
  def analysis_export_rag(_opts), do: {:error, :not_configured}
  def analysis_status(_opts), do: {:error, :not_configured}
end

defmodule GxPortfolioIntelligence.SlotCapturingRunner do
  @behaviour GxPortfolioIntelligence.TradingAgents.Runner

  def universe(opts) do
    send(Application.fetch_env!(:gx_portfolio_intelligence, :test_pid), {:universe_opts, opts})

    {:ok,
     %{
       "schema_version" => 1,
       "status" => "skipped",
       "analysis_date" => Date.to_iso8601(opts[:date]),
       "cutoff" => DateTime.to_iso8601(opts[:cutoff]),
       "price_mode" => opts[:price_mode],
       "slot" => opts[:slot],
       "target_count" => opts[:limit],
       "fingerprint" => String.duplicate("a", 64),
       "members" => []
     }}
  end

  def collect(_opts), do: {:error, :not_configured}
  def run_one(_opts), do: {:error, :not_configured}
  def status(_opts), do: {:error, :not_configured}
  def trend(_opts), do: {:error, :not_configured}
  def analysis_init(_opts), do: {:error, :not_configured}
  def analysis_run_stage(_opts), do: {:error, :not_configured}
  def analysis_export_rag(_opts), do: {:error, :not_configured}
  def analysis_status(_opts), do: {:error, :not_configured}
end

defmodule GxPortfolioIntelligence.WrongIdentityRunner do
  @behaviour GxPortfolioIntelligence.TradingAgents.Runner

  def universe(opts) do
    {:ok,
     %{
       "schema_version" => 1,
       "status" => "non_trading_day",
       "analysis_date" => "2026-08-20",
       "cutoff" => DateTime.to_iso8601(opts[:cutoff]),
       "slot" => opts[:slot],
       "target_count" => opts[:limit],
       "fingerprint" => String.duplicate("a", 64),
       "members" => []
     }}
  end

  def collect(_opts), do: {:error, :not_configured}
  def run_one(_opts), do: {:error, :not_configured}
  def status(_opts), do: {:error, :not_configured}
  def trend(_opts), do: {:error, :not_configured}
  def analysis_init(_opts), do: {:error, :not_configured}
  def analysis_run_stage(_opts), do: {:error, :not_configured}
  def analysis_export_rag(_opts), do: {:error, :not_configured}
  def analysis_status(_opts), do: {:error, :not_configured}
end

defmodule GxPortfolioIntelligence.AdhocCapturingRunner do
  @behaviour GxPortfolioIntelligence.TradingAgents.Runner

  def universe(opts) do
    send(Application.fetch_env!(:gx_portfolio_intelligence, :test_pid), {:adhoc_universe, opts})

    available =
      if Application.get_env(:gx_portfolio_intelligence, :test_adhoc_missing_ticker, false),
        do: Enum.drop(opts[:tickers], -1),
        else: opts[:tickers]

    members =
      available
      |> Enum.with_index(1)
      |> Enum.map(fn {ticker, rank} ->
        %{
          "ticker" => ticker,
          "exchange" => "HOSE",
          "rank" => rank,
          "adtv20" => Integer.to_string(1_000_000 - rank),
          "adv20" => Integer.to_string(100_000 - rank),
          "aliases" => []
        }
      end)

    {:ok,
     %{
       "schema_version" => 1,
       "status" => if(length(available) == opts[:limit], do: "complete", else: "degraded"),
       "analysis_date" => Date.to_iso8601(opts[:date]),
       "cutoff" => DateTime.to_iso8601(opts[:cutoff]),
       "price_mode" => opts[:price_mode],
       "slot" => opts[:slot],
       "target_count" => opts[:limit],
       "requested_tickers" => opts[:tickers],
       "selection_fingerprint" =>
         opts[:tickers]
         |> Jason.encode!()
         |> then(&:crypto.hash(:sha256, &1))
         |> Base.encode16(case: :lower),
       "missing_tickers" => opts[:tickers] -- available,
       "fingerprint" => String.duplicate("b", 64),
       "artifact_path" => opts[:output],
       "members" => members
     }}
  end

  def collect(_opts), do: {:error, :not_configured}
  def run_one(_opts), do: {:error, :not_configured}
  def status(_opts), do: {:error, :not_configured}
  def trend(_opts), do: {:error, :not_configured}
  def analysis_init(_opts), do: {:error, :not_configured}
  def analysis_run_stage(_opts), do: {:error, :not_configured}
  def analysis_export_rag(_opts), do: {:error, :not_configured}
  def analysis_status(_opts), do: {:error, :not_configured}
end

defmodule GxPortfolioIntelligence.TestRAGClient do
  @behaviour GxPortfolioIntelligence.RAG.ClientBehaviour
  def put_batch(_batch), do: {:ok, %{}}
  def put_documents(_batch_id, _documents), do: {:ok, %{"items" => []}}
  def promote(_batch_id, _documents), do: {:ok, %{"items" => []}}
  def seal(_batch_id), do: {:ok, %{}}
  def status(_batch_id, _opts), do: {:ok, %{"items" => []}}

  def full_report(_batch_id, _ticker) do
    Application.get_env(
      :gx_portfolio_intelligence,
      :test_full_report_response,
      {:error, :not_configured}
    )
  end

  def health, do: {:ok, %{"status" => "ok"}}
end

defmodule GxPortfolioIntelligence.TestAlertDispatcher do
  @behaviour GxPortfolioIntelligence.Alerts.Dispatcher
  def deliver(_payload), do: :ok
end
