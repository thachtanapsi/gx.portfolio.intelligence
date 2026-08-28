defmodule GxPortfolioIntelligence.Alerts.Dispatcher do
  @moduledoc false
  @callback deliver(map()) :: :ok | {:error, term()}
end

defmodule GxPortfolioIntelligence.Alerts do
  @moduledoc false

  alias GxPortfolioIntelligence.Repo
  alias GxPortfolioIntelligence.Schemas.AlertEvent
  alias GxPortfolioIntelligence.Workers.AlertWorker

  @allowed_payload ~w(batch_id analysis_date cutoff status target_count completed_count rag_ready_count failed_count sla_ready_count reason disk_used_percent)a

  def emit(event_type, batch, payload \\ %{}) do
    event = to_string(event_type)
    phase = payload[:phase] || payload["phase"] || batch.sla_status || batch.status
    reason = payload[:reason] || payload["reason"] || "none"
    suffix = dedup_suffix(phase, reason)
    dedup_key = "#{event}:#{batch.id}:#{suffix}"

    supplied_payload =
      payload
      |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
      |> Map.take(Enum.map(@allowed_payload, &to_string/1))

    safe_payload =
      %{
        "batch_id" => batch.id,
        "analysis_date" => Date.to_iso8601(batch.analysis_date),
        "cutoff" => DateTime.to_iso8601(batch.cutoff_at),
        "status" => batch.status,
        "target_count" => batch.target_count,
        "completed_count" => batch.completed_count,
        "rag_ready_count" => batch.rag_ready_count,
        "failed_count" => batch.failed_count,
        "sla_ready_count" => batch.sla_ready_count
      }
      |> Map.merge(supplied_payload)

    changeset =
      AlertEvent.changeset(%AlertEvent{}, %{
        event_type: event,
        dedup_key: dedup_key,
        payload: safe_payload,
        research_batch_id: batch.id
      })

    case Repo.transaction(fn -> insert_with_job(changeset) end) do
      {:ok, alert} ->
        {:ok, alert}

      {:error, {:alert_insert_failed, _changeset}} ->
        case Repo.get_by(AlertEvent, dedup_key: dedup_key) do
          nil -> {:error, :invalid_alert}
          alert -> ensure_delivery(alert)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def emit_global(event_type, %Date{} = analysis_date, payload \\ %{}) do
    event = to_string(event_type)
    phase = payload[:phase] || payload["phase"] || "global"
    reason = payload[:reason] || payload["reason"] || "none"
    dedup_key = "#{event}:global:#{Date.to_iso8601(analysis_date)}:#{dedup_suffix(phase, reason)}"

    safe_payload =
      payload
      |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
      |> Map.take(Enum.map(@allowed_payload, &to_string/1))
      |> Map.put("analysis_date", Date.to_iso8601(analysis_date))

    changeset =
      AlertEvent.changeset(%AlertEvent{}, %{
        event_type: event,
        dedup_key: dedup_key,
        payload: safe_payload
      })

    case Repo.transaction(fn -> insert_with_job(changeset) end) do
      {:ok, alert} ->
        {:ok, alert}

      {:error, {:alert_insert_failed, _changeset}} ->
        case Repo.get_by(AlertEvent, dedup_key: dedup_key) do
          nil -> {:error, :invalid_alert}
          alert -> ensure_delivery(alert)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def dispatcher, do: Application.fetch_env!(:gx_portfolio_intelligence, :alert_dispatcher)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp dedup_suffix(phase, reason) do
    [to_string(phase), to_string(reason)]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp insert_with_job(changeset) do
    case Repo.insert(changeset) do
      {:ok, alert} ->
        case AlertWorker.new(%{"alert_id" => alert.id}) |> Oban.insert() do
          {:ok, _job} -> alert
          {:error, reason} -> Repo.rollback({:alert_job_insert_failed, reason})
        end

      {:error, failed_changeset} ->
        Repo.rollback({:alert_insert_failed, failed_changeset})
    end
  end

  defp ensure_delivery(%{status: "delivered"} = alert), do: {:ok, alert}

  defp ensure_delivery(alert) do
    case AlertWorker.new(%{"alert_id" => alert.id}) |> Oban.insert() do
      {:ok, _job} -> {:ok, alert}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule GxPortfolioIntelligence.Alerts.Webhook do
  @behaviour GxPortfolioIntelligence.Alerts.Dispatcher

  @impl true
  def deliver(payload) do
    case Application.get_env(:gx_portfolio_intelligence, :webhook_url) do
      nil -> :ok
      "" -> :ok
      url when is_binary(url) -> request(url, payload)
    end
  end

  defp request(url, payload) do
    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url) do
      headers = [{"content-type", "application/json"}]

      headers =
        case payload["idempotency_key"] do
          key when is_binary(key) and key != "" -> [{"idempotency-key", key} | headers]
          _ -> headers
        end

      headers =
        case Application.get_env(:gx_portfolio_intelligence, :webhook_token) do
          token when is_binary(token) and token != "" ->
            [{"authorization", "Bearer " <> token} | headers]

          _ ->
            headers
        end

      request = Finch.build(:post, url, headers, Jason.encode_to_iodata!(payload))

      case Finch.request(request, GxPortfolioIntelligence.Finch, receive_timeout: 15_000) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Finch.Response{status: status}} -> {:error, {:webhook_http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_webhook_url}
    end
  end
end
