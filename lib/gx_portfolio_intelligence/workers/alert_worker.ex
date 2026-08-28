defmodule GxPortfolioIntelligence.Workers.AlertWorker do
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias GxPortfolioIntelligence.{Alerts, Repo}
  alias GxPortfolioIntelligence.Schemas.AlertEvent

  @impl true
  def perform(%Oban.Job{args: %{"alert_id" => alert_id}}) do
    alert = Repo.get!(AlertEvent, alert_id)

    if alert.status == "delivered" do
      :ok
    else
      payload =
        alert.payload
        |> Map.put("event", alert.event_type)
        |> Map.put("idempotency_key", alert.dedup_key)

      case Alerts.dispatcher().deliver(payload) do
        :ok ->
          alert
          |> AlertEvent.changeset(%{
            status: "delivered",
            attempts: alert.attempts + 1,
            delivered_at: DateTime.utc_now(),
            last_error: nil
          })
          |> Repo.update()

          :ok

        {:error, reason} = error ->
          alert
          |> AlertEvent.changeset(%{
            status: "failed",
            attempts: alert.attempts + 1,
            last_error: GxPortfolioIntelligence.Research.error_text(reason)
          })
          |> Repo.update()

          error
      end
    end
  end
end
