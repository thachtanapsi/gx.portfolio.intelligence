defmodule GxPortfolioIntelligence.FullReportEnvelopeTest do
  use ExUnit.Case, async: true

  alias GxPortfolioIntelligence.FullReportEnvelope

  @hash "2db5723b2a82446db0120b5d1705e33069486d35056b38b023b2a22e152ca381"

  test "accepts the frozen full-report contract and matches Python canonical JSON hashing" do
    envelope = envelope()

    assert {:ok, safe, ~U[2026-08-25 08:00:00Z]} =
             FullReportEnvelope.sanitize(envelope, expected())

    assert safe["full_report_hash"] == @hash
  end

  test "rejects a digest identity mismatch and incomplete core stage" do
    assert {:error, :full_report_identity_mismatch} =
             envelope()
             |> Map.put("parent_identity_hash", String.duplicate("f", 64))
             |> FullReportEnvelope.sanitize(expected())

    invalid =
      envelope()
      |> put_in(["stage_status", "risk"], "partial")
      |> put_in(["sections", "portfolio.decision", "status"], "partial")
      |> put_in(["sections", "risk.aggressive", "status"], "partial")
      |> put_in(["sections", "risk.conservative", "status"], "partial")
      |> put_in(["sections", "risk.neutral", "status"], "partial")

    assert {:error, :invalid_full_report_status} =
             FullReportEnvelope.sanitize(invalid, expected())
  end

  test "rejects spaced API-key and generic credential markers even with a valid content hash" do
    for forbidden <- ["API key: sk-test", "credential = token123", "secret: value"] do
      unsafe = put_in(envelope(), ["sections", "portfolio.decision", "text"], forbidden)
      unsafe = Map.put(unsafe, "full_report_hash", sections_hash(unsafe["sections"]))

      assert {:error, :invalid_full_report_sections} =
               FullReportEnvelope.sanitize(unsafe, expected())
    end
  end

  defp envelope do
    sections =
      Map.new(FullReportEnvelope.sections(), fn key ->
        {key, %{"status" => "complete", "text" => "Nội dung " <> key}}
      end)

    stages = ~w(market sentiment news fundamentals research trader risk)

    %{
      "schema_version" => 2,
      "content_kind" => "full_report_v1",
      "report_schema" => "full_report_v1",
      "source" => "tradingagents_adhoc_research",
      "ticker" => "SSI",
      "analysis_date" => "2026-08-25",
      "cutoff" => "2026-08-25T07:30:00Z",
      "source_updated_at" => "2026-08-25T08:00:00Z",
      "liquidity_rank" => 1,
      "research_mode" => "live",
      "data_provenance" => "request_cutoff",
      "identity_hash" => String.duplicate("a", 64),
      "parent_identity_hash" => String.duplicate("b", 64),
      "expected_digest_hash" => String.duplicate("c", 64),
      "full_report_hash" => @hash,
      "pipeline_version" => "gx_full_v1",
      "prompt_fingerprint" => String.duplicate("d", 64),
      "model_fingerprint" => String.duplicate("e", 64),
      "evidence_fingerprint" => String.duplicate("f", 64),
      "execution_generation" => 1,
      "contains_decision_content" => true,
      "status" => "complete",
      "stage_status" => Map.new(stages, &{&1, "complete"}),
      "stage_fingerprints" => Map.new(stages, &{&1, String.duplicate("1", 64)}),
      "sections" => sections
    }
  end

  defp expected do
    %{
      source: "tradingagents_adhoc_research",
      ticker: "SSI",
      analysis_date: ~D[2026-08-25],
      cutoff_at: ~U[2026-08-25 07:30:00Z],
      liquidity_rank: 1,
      research_mode: "live",
      data_provenance: "request_cutoff",
      identity_hash: String.duplicate("a", 64),
      parent_identity_hash: String.duplicate("b", 64),
      expected_digest_hash: String.duplicate("c", 64),
      execution_generation: 1
    }
  end

  defp sections_hash(sections) do
    sections
    |> canonical_iodata()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_iodata(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, nested} ->
        [Jason.encode!(to_string(key)), ":", canonical_iodata(nested)]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical_iodata(value), do: Jason.encode!(value)
end
