defmodule GxPortfolioIntelligence.DigestEnvelope do
  @moduledoc false

  @daily_source "tradingagents_daily_research"
  @sources ~w(tradingagents_daily_research tradingagents_adhoc_research)
  @sections ~w(summary market fundamentals news_events sentiment macro catalysts risks_unknowns next_session_watch)
  @fingerprints ~w(prompt_fingerprint model_fingerprint evidence_fingerprint)
  @allowed_keys ~w(schema_version source ticker analysis_date cutoff research_mode data_provenance source_updated_at liquidity_rank prompt_fingerprint model_fingerprint evidence_fingerprint identity_hash digest_hash status sections)
  @provenance %{
    "eod" => "eod_cutoff",
    "live" => "request_cutoff",
    "historical" => "historical_replay"
  }
  @sha256 ~r/^[0-9a-f]{64}$/
  @evidence_id ~r/^[A-Za-z0-9][A-Za-z0-9:_.\/-]{0,127}$/
  @confidence ~w(low medium high)

  def sections, do: @sections

  def sanitize(envelope, expected) when is_map(envelope) do
    sections = envelope["sections"]
    expected_source = Map.get(expected, :source, @daily_source)

    with :ok <- validate_top_level(envelope),
         :ok <- validate_source(envelope["source"], expected_source),
         :ok <- validate_identity(envelope, expected),
         :ok <- validate_provenance(envelope, expected),
         {:ok, source_updated_at} <- required_datetime(envelope["source_updated_at"]),
         :ok <- validate_status(envelope["status"]),
         {:ok, fingerprints} <- required_fingerprints(envelope),
         true <- is_map(sections) or {:error, :invalid_sections},
         true <-
           Enum.sort(Map.keys(sections)) == Enum.sort(@sections) or {:error, :invalid_section_set},
         {:ok, safe_sections} <- sanitize_sections(sections),
         true <-
           Enum.any?(safe_sections, fn {_section, claims} -> claims != [] end) or
             {:error, :empty_digest} do
      safe = %{
        "schema_version" => 1,
        "source" => expected_source,
        "ticker" => expected.ticker,
        "analysis_date" => Date.to_iso8601(expected.analysis_date),
        "cutoff" => envelope["cutoff"],
        "research_mode" => expected.research_mode,
        "data_provenance" => expected.data_provenance,
        "source_updated_at" => DateTime.to_iso8601(source_updated_at),
        "liquidity_rank" => expected.liquidity_rank,
        "identity_hash" => envelope["identity_hash"],
        "digest_hash" => envelope["digest_hash"],
        "status" => envelope["status"],
        "sections" => safe_sections
      }

      {:ok, Map.merge(safe, fingerprints), source_updated_at}
    else
      false -> {:error, :invalid_envelope}
      {:error, _} = error -> error
    end
  end

  def sanitize(_, _), do: {:error, :invalid_envelope}

  defp validate_top_level(envelope) do
    if envelope["schema_version"] == 1 and
         Enum.sort(Map.keys(envelope)) == Enum.sort(@allowed_keys),
       do: :ok,
       else: {:error, :invalid_envelope_fields}
  end

  defp validate_source(source, expected) when source in @sources and source == expected, do: :ok
  defp validate_source(_, _), do: {:error, :invalid_source}

  defp validate_identity(envelope, expected) do
    with ticker when is_binary(ticker) <- envelope["ticker"],
         true <- String.upcase(ticker) == expected.ticker,
         {:ok, date} <- Date.from_iso8601(envelope["analysis_date"] || ""),
         true <- date == expected.analysis_date,
         {:ok, cutoff} <- required_datetime(envelope["cutoff"]),
         true <- DateTime.compare(cutoff, expected.cutoff_at) == :eq,
         rank when is_integer(rank) <- envelope["liquidity_rank"],
         true <- rank == expected.liquidity_rank,
         identity when is_binary(identity) <- envelope["identity_hash"],
         true <- Regex.match?(@sha256, identity),
         true <- identity == expected.identity_hash,
         digest when is_binary(digest) <- envelope["digest_hash"],
         true <- Regex.match?(@sha256, digest),
         true <- digest == expected.digest_hash do
      :ok
    else
      _ -> {:error, :identity_mismatch}
    end
  end

  defp validate_provenance(envelope, expected) do
    mode = envelope["research_mode"]
    provenance = envelope["data_provenance"]

    if mode == expected.research_mode and provenance == expected.data_provenance and
         @provenance[mode] == provenance,
       do: :ok,
       else: {:error, :provenance_mismatch}
  end

  defp required_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp required_datetime(_), do: {:error, :missing_datetime}

  defp sanitize_sections(sections) do
    Enum.reduce_while(@sections, {:ok, %{}}, fn section, {:ok, acc} ->
      case sanitize_claims(sections[section]) do
        {:ok, claims} -> {:cont, {:ok, Map.put(acc, section, claims)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp sanitize_claims(claims) when is_list(claims) and length(claims) <= 8 do
    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, acc} ->
      case sanitize_claim(claim) do
        {:ok, safe} -> {:cont, {:ok, [safe | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp sanitize_claims(_), do: {:error, :invalid_claim_list}

  defp sanitize_claim(
         %{"text" => text, "confidence" => confidence, "evidence_ids" => evidence_ids} = claim
       )
       when map_size(claim) == 3 and is_binary(text) and is_list(evidence_ids) and
              length(evidence_ids) <= 12 do
    with true <- byte_size(text) in 1..2_000 or {:error, :invalid_claim_text},
         :ok <- validate_confidence(confidence),
         true <-
           Enum.all?(evidence_ids, &(is_binary(&1) and Regex.match?(@evidence_id, &1))) or
             {:error, :invalid_evidence_id},
         true <-
           length(Enum.uniq(evidence_ids)) == length(evidence_ids) or
             {:error, :duplicate_evidence_id} do
      {:ok, %{"text" => text, "confidence" => confidence, "evidence_ids" => evidence_ids}}
    else
      false -> {:error, :invalid_claim}
      {:error, _} = error -> error
    end
  end

  defp sanitize_claim(_), do: {:error, :invalid_claim}

  defp validate_confidence(value) when value in @confidence, do: :ok
  defp validate_confidence(value) when is_number(value) and value >= 0 and value <= 1, do: :ok
  defp validate_confidence(_), do: {:error, :invalid_confidence}

  defp validate_status(value) when value in ["complete", "partial"], do: :ok
  defp validate_status(_), do: {:error, :invalid_status}

  defp required_fingerprints(envelope) do
    if Enum.all?(
         @fingerprints,
         &(is_binary(envelope[&1]) and Regex.match?(@sha256, envelope[&1]))
       ) do
      {:ok, Map.take(envelope, @fingerprints)}
    else
      {:error, :invalid_fingerprint}
    end
  end
end
