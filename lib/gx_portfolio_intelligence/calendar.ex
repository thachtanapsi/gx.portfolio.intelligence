defmodule GxPortfolioIntelligence.Calendar do
  @moduledoc false

  def timezone, do: Application.get_env(:gx_portfolio_intelligence, :timezone, "Asia/Ho_Chi_Minh")

  def cutoff_at(%Date{} = date) do
    time = Application.get_env(:gx_portfolio_intelligence, :cutoff_time, ~T[15:45:00])

    with {:ok, local} <- DateTime.new(date, time, timezone()) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    end
  end

  def at_slot(%Date{} = date, <<hour::binary-size(2), ":", minute::binary-size(2)>>) do
    with {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {:ok, time} <- Time.new(hour, minute, 0),
         {:ok, local} <- DateTime.new(date, time, timezone()) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _ -> {:error, :invalid_slot}
    end
  end

  def at_slot(_, _), do: {:error, :invalid_slot}

  def today do
    DateTime.now!(timezone()) |> DateTime.to_date()
  end

  def previous_weekday(date \\ today()) do
    previous = Date.add(date, -1)
    if Date.day_of_week(previous) in [6, 7], do: previous_weekday(previous), else: previous
  end

  def sla_deadline(%Date{} = analysis_date, phase)
      when phase in ["early_sla", "final_sla"] do
    slot = if phase == "early_sla", do: "07:30", else: "08:00"
    at_slot(Date.add(analysis_date, 1), slot)
  end

  def iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
