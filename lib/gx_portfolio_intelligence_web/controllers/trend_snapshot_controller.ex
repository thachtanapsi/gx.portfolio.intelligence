defmodule GxPortfolioIntelligenceWeb.TrendSnapshotController do
  use GxPortfolioIntelligenceWeb, :controller

  alias GxPortfolioIntelligence.FullAnalysis
  alias GxPortfolioIntelligenceWeb.Serializers

  def index(conn, params) do
    with {:ok, limit} <- integer_param(params["limit"], 30, 1, 100),
         {:ok, date} <- optional_date(params["analysis_date"]) do
      snapshots = FullAnalysis.list_trend_snapshots(limit: limit, analysis_date: date)
      json(conn, %{data: Enum.map(snapshots, &Serializers.trend/1)})
    else
      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: %{code: to_string(reason)}})
    end
  end

  defp optional_date(nil), do: {:ok, nil}
  defp optional_date(value), do: Date.from_iso8601(value)

  defp integer_param(nil, default, _min, _max), do: {:ok, default}

  defp integer_param(value, _default, min, max) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> {:error, :invalid_pagination}
    end
  end
end
