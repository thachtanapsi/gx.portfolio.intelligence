defmodule GxPortfolioIntelligenceWeb.HealthController do
  use GxPortfolioIntelligenceWeb, :controller

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    {ready, checks} = GxPortfolioIntelligence.DependencyCheck.ready?()

    conn
    |> put_status(if(ready, do: :ok, else: :service_unavailable))
    |> json(%{status: if(ready, do: "ready", else: "not_ready"), checks: checks})
  end
end
