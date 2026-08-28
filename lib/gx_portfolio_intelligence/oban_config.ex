defmodule GxPortfolioIntelligence.ObanConfig do
  @moduledoc false

  alias GxPortfolioIntelligence.Workers.{MaintenanceWorker, ScheduleWorker}

  @candidate_slots ~w(09:15 10:15 11:15 13:15 14:15)

  def candidate_slots, do: @candidate_slots

  def cron_entries do
    candidate =
      Enum.map(@candidate_slots, fn slot ->
        [minute, hour] = slot |> String.split(":") |> Enum.map(&String.to_integer/1)

        {"#{minute} #{hour} * * 1-5", ScheduleWorker,
         args: %{"action" => "candidate", "slot" => slot}}
      end)

    candidate ++
      [
        {"15 15 * * 1-5", ScheduleWorker, args: %{"action" => "freeze", "slot" => "15:15"}},
        {"20 15 * * 1-5", ScheduleWorker,
         args: %{"action" => "collect_final", "slot" => "15:20"}},
        {"30 15 * * 1-5", ScheduleWorker, args: %{"action" => "macro_final", "slot" => "15:30"}},
        {"45 15 * * 1-5", ScheduleWorker, args: %{"action" => "fanout", "slot" => "15:45"}},
        {"30 7 * * 2-6", ScheduleWorker, args: %{"action" => "early_sla"}},
        {"0 8 * * 2-6", ScheduleWorker, args: %{"action" => "final_sla"}},
        {"*/15 * * * *", MaintenanceWorker, args: %{}}
      ]
  end
end
