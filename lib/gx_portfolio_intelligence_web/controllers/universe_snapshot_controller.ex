defmodule GxPortfolioIntelligenceWeb.UniverseSnapshotController do
  use GxPortfolioIntelligenceWeb, :controller

  alias GxPortfolioIntelligence.Research

  def index(conn, params) do
    with {:ok, date} <- optional_date(params["analysis_date"]) do
      snapshots = Research.list_snapshots(analysis_date: date, limit: 100)
      json(conn, %{data: Enum.map(snapshots, &Serializers.snapshot/1)})
    else
      _ -> conn |> put_status(:bad_request) |> json(%{error: %{code: "invalid_analysis_date"}})
    end
  end

  defp optional_date(nil), do: {:ok, nil}
  defp optional_date(""), do: {:ok, nil}
  defp optional_date(value), do: Date.from_iso8601(value)
end
