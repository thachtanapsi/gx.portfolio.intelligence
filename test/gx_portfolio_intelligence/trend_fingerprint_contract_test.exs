defmodule GxPortfolioIntelligence.TrendFingerprintContractTest do
  use ExUnit.Case, async: true

  alias GxPortfolioIntelligence.FullAnalysis

  @known "6b1f3f49e2fe0794958a2510df769af8b3294b2f581810f25e4c0186e24e0ecd"

  test "matches the Python known vector across decimal renderings including 0.000001" do
    payload = payload()
    assert FullAnalysis.trend_fingerprint(payload) == @known

    normalized_variant =
      payload
      |> put_in(["weights", "volume_ratio"], 30)
      |> put_in(["weights", "daily_move_abs"], 25)
      |> put_in(["weights", "momentum20_abs"], 15)
      |> put_in(["weights", "social_attention"], 15)
      |> put_in(["weights", "media_event"], 15)
      |> put_in(["members", Access.at(0), "adtv20"], "1000000.0000")
      |> put_in(["members", Access.at(0), "adv20"], Decimal.new("1000.0000"))
      |> put_in(["members", Access.at(0), "volume_ratio"], "1e-6")
      |> put_in(["members", Access.at(0), "daily_move_abs_pct"], Decimal.new("2.500000"))
      |> put_in(["members", Access.at(0), "momentum20_abs_pct"], "4.000000")
      |> put_in(["members", Access.at(0), "media_event_velocity"], "-0.000000")
      |> put_in(["members", Access.at(0), "trend_score"], Decimal.new("30.0000010"))

    assert FullAnalysis.trend_fingerprint(normalized_variant) == @known
  end

  test "keeps integer identity fields typed" do
    changed_rank = put_in(payload(), ["members", Access.at(0), "liquidity_rank"], 1.0)
    refute FullAnalysis.trend_fingerprint(changed_rank) == @known
  end

  defp payload do
    %{
      "schema_version" => 1,
      "analysis_date" => "2026-08-25",
      "cutoff" => "2026-08-25T08:00:00+00:00",
      "previous_cutoff" => "2026-08-25T07:15:00+00:00",
      "slot" => "15:15",
      "universe_fingerprint" => String.duplicate("a", 64),
      "weights" => %{
        "volume_ratio" => 30.0,
        "daily_move_abs" => 25.0,
        "momentum20_abs" => 15.0,
        "social_attention" => 15.0,
        "media_event" => 15.0
      },
      "status" => "complete",
      "target_count" => 1,
      "scored_count" => 1,
      "members" => [
        %{
          "ticker" => "SSI",
          "liquidity_rank" => 1,
          "adtv20" => 1_000_000.0,
          "adv20" => 1_000.0,
          "market_core_available" => true,
          "volume_ratio" => 0.000001,
          "daily_move_abs_pct" => 2.5,
          "momentum20_abs_pct" => 4.0,
          "social_attention_velocity" => nil,
          "media_event_velocity" => 0.0,
          "coverage" => %{
            "market_core" => true,
            "social_attention" => false,
            "media_event" => true
          },
          "trend_score" => 30.000001
        }
      ],
      "warnings" => []
    }
  end
end
