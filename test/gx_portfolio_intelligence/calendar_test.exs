defmodule GxPortfolioIntelligence.CalendarTest do
  use ExUnit.Case, async: true

  alias GxPortfolioIntelligence.Calendar

  test "tzdata autoupdate is disabled for the immutable release image" do
    assert Application.get_env(:tzdata, :autoupdate) == :disabled
  end

  test "a delayed retry retains the requested point-in-time slot" do
    date = ~D[2026-08-21]
    assert {:ok, timestamp} = Calendar.at_slot(date, "09:15")
    assert DateTime.to_iso8601(timestamp) == "2026-08-21T02:15:00Z"
    assert {:ok, cutoff} = Calendar.cutoff_at(date)
    assert DateTime.to_iso8601(cutoff) == "2026-08-21T08:45:00Z"
  end

  test "rejects malformed slots" do
    assert {:error, :invalid_slot} = Calendar.at_slot(~D[2026-08-21], "9:15")
    assert {:error, :invalid_slot} = Calendar.at_slot(~D[2026-08-21], "25:00")
  end

  test "maintenance cron bypasses the hourly schedule-worker uniqueness window" do
    assert {"*/15 * * * *", GxPortfolioIntelligence.Workers.MaintenanceWorker, args: %{}} in GxPortfolioIntelligence.ObanConfig.cron_entries()
  end
end
