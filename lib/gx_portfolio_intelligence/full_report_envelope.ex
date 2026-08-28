defmodule GxPortfolioIntelligence.FullReportEnvelope do
  @moduledoc false

  @max_bytes 262_144
  @sha256 ~r/^[0-9a-f]{64}$/
  @statuses ~w(complete partial)
  @section_statuses ~w(complete partial unavailable)
  @forbidden_text ~r/(?:[a-z][a-z0-9+.-]{1,15}:\/\/|www\.|raw[\s_-]*(?:sentinel|evidence)|(?:authorization|api[\s_-]*key|credential|password|secret)\s*[:=]\s*\S+)/i
  @stages ~w(market sentiment news fundamentals research trader risk)

  @sections [
    "analyst.market",
    "analyst.sentiment",
    "analyst.news",
    "analyst.fundamentals",
    "research.bull",
    "research.bear",
    "research.manager",
    "trading.plan",
    "risk.aggressive",
    "risk.conservative",
    "risk.neutral",
    "portfolio.decision"
  ]

  @allowed_keys ~w(schema_version content_kind report_schema source ticker analysis_date cutoff source_updated_at liquidity_rank research_mode data_provenance identity_hash parent_identity_hash expected_digest_hash full_report_hash pipeline_version prompt_fingerprint model_fingerprint evidence_fingerprint execution_generation contains_decision_content status stage_status stage_fingerprints sections)

  @section_stage %{
    "analyst.market" => "market",
    "analyst.sentiment" => "sentiment",
    "analyst.news" => "news",
    "analyst.fundamentals" => "fundamentals",
    "research.bull" => "research",
    "research.bear" => "research",
    "research.manager" => "research",
    "trading.plan" => "trader",
    "risk.aggressive" => "risk",
    "risk.conservative" => "risk",
    "risk.neutral" => "risk",
    "portfolio.decision" => "risk"
  }

  def sections, do: @sections

  def canonical_sha256(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def sanitize(envelope, expected) when is_map(envelope) do
    with {:ok, encoded} <- Jason.encode(envelope),
         true <- byte_size(encoded) <= @max_bytes or {:error, :full_report_too_large},
         :ok <- exact_keys(envelope, @allowed_keys, :invalid_full_report_fields),
         :ok <- validate_header(envelope, expected),
         {:ok, source_updated_at} <- datetime(envelope["source_updated_at"]),
         :ok <- validate_stage_maps(envelope),
         {:ok, sections} <- validate_sections(envelope["sections"], envelope["stage_status"]),
         :ok <- validate_hash(envelope["full_report_hash"], sections) do
      {:ok, Map.put(envelope, "sections", sections), source_updated_at}
    else
      false -> {:error, :invalid_full_report}
      {:error, _} = error -> error
    end
  end

  def sanitize(_, _), do: {:error, :invalid_full_report}

  defp validate_header(envelope, expected) do
    with true <- envelope["schema_version"] == 2,
         true <- envelope["content_kind"] == "full_report_v1",
         true <- envelope["report_schema"] == "full_report_v1",
         true <- envelope["source"] == expected.source,
         true <- envelope["ticker"] == expected.ticker,
         true <- envelope["analysis_date"] == Date.to_iso8601(expected.analysis_date),
         {:ok, cutoff} <- datetime(envelope["cutoff"]),
         true <- DateTime.compare(cutoff, expected.cutoff_at) == :eq,
         true <- envelope["liquidity_rank"] == expected.liquidity_rank,
         true <- envelope["research_mode"] == expected.research_mode,
         true <- envelope["data_provenance"] == expected.data_provenance,
         :ok <- hash(envelope["identity_hash"]),
         true <- envelope["identity_hash"] == expected.identity_hash,
         :ok <- hash(envelope["parent_identity_hash"]),
         true <- envelope["parent_identity_hash"] == expected.parent_identity_hash,
         :ok <- hash(envelope["expected_digest_hash"]),
         true <- envelope["expected_digest_hash"] == expected.expected_digest_hash,
         :ok <- hash(envelope["full_report_hash"]),
         :ok <- hash(envelope["prompt_fingerprint"]),
         :ok <- hash(envelope["model_fingerprint"]),
         :ok <- hash(envelope["evidence_fingerprint"]),
         true <- envelope["pipeline_version"] == "gx_full_v1",
         true <- envelope["execution_generation"] == expected.execution_generation,
         true <- envelope["contains_decision_content"] == true,
         true <- envelope["status"] in @statuses,
         :ok <- validate_overall_status(envelope["status"], envelope["stage_status"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :full_report_identity_mismatch}
    end
  end

  defp validate_stage_maps(envelope) do
    statuses = envelope["stage_status"]
    fingerprints = envelope["stage_fingerprints"]

    with true <- is_map(statuses) and is_map(fingerprints),
         true <- Enum.sort(Map.keys(statuses)) == Enum.sort(@stages),
         true <- Enum.sort(Map.keys(fingerprints)) == Enum.sort(@stages),
         true <- Enum.all?(statuses, fn {_stage, status} -> status in @section_statuses end),
         true <- Enum.all?(fingerprints, fn {_stage, value} -> match?(:ok, hash(value)) end),
         true <- Enum.all?(~w(research trader risk), &(statuses[&1] == "complete")) do
      :ok
    else
      _ -> {:error, :invalid_full_report_stages}
    end
  end

  defp validate_overall_status("complete", statuses) when is_map(statuses) do
    if Enum.all?(@stages, &(statuses[&1] == "complete")),
      do: :ok,
      else: {:error, :invalid_full_report_status}
  end

  defp validate_overall_status("partial", statuses) when is_map(statuses) do
    if Enum.any?(@stages, &(statuses[&1] in ["partial", "unavailable"])),
      do: :ok,
      else: {:error, :invalid_full_report_status}
  end

  defp validate_overall_status(_, _), do: {:error, :invalid_full_report_status}

  defp validate_sections(sections, stage_status) when is_map(sections) do
    with true <- Enum.sort(Map.keys(sections)) == Enum.sort(@sections),
         true <-
           Enum.all?(@sections, fn key ->
             section = sections[key]

             is_map(section) and Enum.sort(Map.keys(section)) == ["status", "text"] and
               section["status"] in @section_statuses and
               section["status"] == stage_status[@section_stage[key]] and
               is_binary(section["text"]) and byte_size(section["text"]) in 1..32_768 and
               not Regex.match?(@forbidden_text, section["text"])
           end) do
      {:ok, Map.take(sections, @sections)}
    else
      _ -> {:error, :invalid_full_report_sections}
    end
  end

  defp validate_sections(_, _), do: {:error, :invalid_full_report_sections}

  defp validate_hash(expected_hash, sections) do
    actual = canonical_sha256(sections)

    if actual == expected_hash, do: :ok, else: {:error, :full_report_hash_mismatch}
  end

  def canonical_json(value), do: value |> canonical_iodata() |> IO.iodata_to_binary()

  defp canonical_iodata(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, nested} ->
        [Jason.encode!(to_string(key)), ":", canonical_iodata(nested)]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical_iodata(value) when is_list(value),
    do: ["[", value |> Enum.map(&canonical_iodata/1) |> Enum.intersperse(","), "]"]

  defp canonical_iodata(value), do: Jason.encode!(value)

  defp exact_keys(value, keys, error) do
    if Enum.sort(Map.keys(value)) == Enum.sort(keys), do: :ok, else: {:error, error}
  end

  defp hash(value) when is_binary(value) do
    if Regex.match?(@sha256, value), do: :ok, else: {:error, :invalid_hash}
  end

  defp hash(_), do: {:error, :invalid_hash}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _} -> {:ok, parsed}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp datetime(_), do: {:error, :invalid_datetime}
end
