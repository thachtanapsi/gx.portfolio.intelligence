defmodule GxPortfolioIntelligence.DigestEnvelopeTest do
  use ExUnit.Case, async: true

  alias GxPortfolioIntelligence.DigestEnvelope

  @expected %{
    ticker: "HPG",
    analysis_date: ~D[2026-08-21],
    cutoff_at: ~U[2026-08-21 08:45:00Z],
    liquidity_rank: 3,
    research_mode: "eod",
    data_provenance: "eod_cutoff",
    identity_hash: String.duplicate("d", 64),
    digest_hash: String.duplicate("e", 64)
  }

  test "accepts the TradingAgents claim-array contract and retains only allowlisted fields" do
    envelope = envelope()

    assert {:ok, safe, ~U[2026-08-21 08:46:00Z]} = DigestEnvelope.sanitize(envelope, @expected)
    assert safe["source"] == "tradingagents_daily_research"
    assert safe["cutoff"] == "2026-08-21T15:45:00+07:00"

    assert get_in(safe, ["sections", "risks_unknowns", Access.at(0), "evidence_ids"]) == [
             "ev-a1b2"
           ]

    assert safe["identity_hash"] == String.duplicate("d", 64)
    assert safe["digest_hash"] == String.duplicate("e", 64)
    assert safe["research_mode"] == "eod"
    assert safe["data_provenance"] == "eod_cutoff"
  end

  test "uses the shared 2000-byte limit for multi-byte Vietnamese text" do
    text = String.duplicate("á", 1_000)
    candidate = put_in(envelope(), ["sections", "summary", Access.at(0), "text"], text)

    assert {:ok, safe, _source_updated_at} = DigestEnvelope.sanitize(candidate, @expected)
    assert get_in(safe, ["sections", "summary", Access.at(0), "text"]) == text

    too_long =
      put_in(
        envelope(),
        ["sections", "summary", Access.at(0), "text"],
        String.duplicate("á", 1_001)
      )

    assert {:error, :invalid_claim_text} = DigestEnvelope.sanitize(too_long, @expected)
  end

  test "accepts the isolated ad-hoc source only when the batch expects it" do
    envelope =
      envelope()
      |> Map.put("source", "tradingagents_adhoc_research")
      |> Map.put("research_mode", "live")
      |> Map.put("data_provenance", "request_cutoff")

    expected =
      @expected
      |> Map.put(:source, "tradingagents_adhoc_research")
      |> Map.put(:research_mode, "live")
      |> Map.put(:data_provenance, "request_cutoff")

    assert {:ok, safe, _source_updated_at} = DigestEnvelope.sanitize(envelope, expected)
    assert safe["source"] == "tradingagents_adhoc_research"

    assert {:error, :invalid_source} = DigestEnvelope.sanitize(envelope, @expected)
  end

  test "rejects unknown claim keys, missing sections and identity drift" do
    assert {:error, :invalid_envelope_fields} =
             envelope()
             |> Map.put("raw_articles", [%{"body" => "SECRET_RAW_SENTINEL"}])
             |> DigestEnvelope.sanitize(@expected)

    bad_claim =
      put_in(envelope(), ["sections", "summary", Access.at(0), "raw_title"], "not allowed")

    assert {:error, :invalid_claim} = DigestEnvelope.sanitize(bad_claim, @expected)

    assert {:error, :invalid_section_set} =
             envelope()
             |> update_in(["sections"], &Map.delete(&1, "macro"))
             |> DigestEnvelope.sanitize(@expected)

    assert {:error, :identity_mismatch} =
             envelope() |> Map.put("liquidity_rank", 4) |> DigestEnvelope.sanitize(@expected)

    assert {:error, :empty_digest} =
             envelope()
             |> Map.put("sections", Map.new(DigestEnvelope.sections(), &{&1, []}))
             |> DigestEnvelope.sanitize(@expected)

    assert {:error, :provenance_mismatch} =
             envelope()
             |> Map.put("data_provenance", "historical_replay")
             |> DigestEnvelope.sanitize(@expected)
  end

  defp envelope do
    claim = [
      %{
        "text" => "Một số nguồn còn thiếu.",
        "confidence" => "high",
        "evidence_ids" => ["ev-a1b2"]
      }
    ]

    %{
      "schema_version" => 1,
      "source" => "tradingagents_daily_research",
      "ticker" => "HPG",
      "analysis_date" => "2026-08-21",
      "cutoff" => "2026-08-21T15:45:00+07:00",
      "research_mode" => "eod",
      "data_provenance" => "eod_cutoff",
      "source_updated_at" => "2026-08-21T08:46:00Z",
      "liquidity_rank" => 3,
      "status" => "complete",
      "prompt_fingerprint" => String.duplicate("a", 64),
      "model_fingerprint" => String.duplicate("b", 64),
      "evidence_fingerprint" => String.duplicate("c", 64),
      "identity_hash" => String.duplicate("d", 64),
      "digest_hash" => String.duplicate("e", 64),
      "sections" => Map.new(DigestEnvelope.sections(), &{&1, claim})
    }
  end
end
