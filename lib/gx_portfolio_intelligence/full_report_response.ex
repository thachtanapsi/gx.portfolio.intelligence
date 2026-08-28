defmodule GxPortfolioIntelligence.FullReportResponse do
  @moduledoc false

  alias GxPortfolioIntelligence.FullReportEnvelope

  @report_bytes 262_144
  @decision_bytes 65_536
  @sha256 ~r/^[0-9a-f]{64}$/
  @document_id ~r/^digest_[0-9a-f]{64}$/
  @currency ~r/^[A-Z][A-Z0-9]{2,7}$/
  @forbidden_text ~r/(?:[a-z][a-z0-9+.-]{1,15}:\/\/|www\.|raw[\s_-]*(?:sentinel|evidence)|(?:authorization|api[\s_-]*key|credential|password|secret)\s*[:=]\s*\S+)/i

  @data_keys ~w(document_id canonical_report_sha256 decision_sha256 report decision)
  @decision_keys ~w(schema_version status warnings portfolio trading)

  @portfolio_keys ~w(rating executive_summary investment_thesis time_horizon price_target_status price_target price_target_currency price_target_rationale price_target_unavailable_reason)
  @trading_keys ~w(action reasoning entry_price stop_loss position_sizing)
  @ratings ~w(Buy Overweight Hold Underweight Sell)
  @actions ~w(Buy Hold Sell)

  @warning_codes ~w(
    portfolio_rating_missing
    portfolio_executive_summary_missing
    portfolio_investment_thesis_missing
    portfolio_price_target_contract_invalid
    trading_action_missing
    trading_reasoning_missing
    trading_entry_price_invalid
    trading_stop_loss_invalid
  )

  def validate(%{"data" => data} = response, expected)
      when is_map(data) and is_map(expected) do
    report = data["report"]
    decision = data["decision"]

    with :ok <- exact_keys(response, ["data"]),
         :ok <- exact_keys(data, @data_keys),
         :ok <- encoded_size(report, @report_bytes, :full_report_too_large),
         :ok <- encoded_size(decision, @decision_bytes, :decision_too_large),
         {:ok, safe_report, _source_updated_at} <-
           FullReportEnvelope.sanitize(report, expected),
         :ok <- expected_full_report_hash(safe_report, expected),
         :ok <- validate_document_id(data["document_id"], safe_report),
         :ok <- validate_canonical_hash(data["canonical_report_sha256"], safe_report),
         :ok <- validate_decision(decision),
         :ok <- validate_decision_hash(data["decision_sha256"], decision) do
      {:ok,
       %{
         "document_id" => data["document_id"],
         "canonical_report_sha256" => data["canonical_report_sha256"],
         "decision_sha256" => data["decision_sha256"],
         "report" => safe_report,
         "decision" => decision
       }}
    end
  end

  def validate(_, _), do: {:error, :invalid_full_report_response}

  defp validate_document_id(document_id, report) do
    expected =
      "digest_" <>
        FullReportEnvelope.canonical_sha256([
          report["source"],
          report["ticker"],
          report["analysis_date"],
          report["cutoff"]
        ])

    if is_binary(document_id) and Regex.match?(@document_id, document_id) and
         document_id == expected,
       do: :ok,
       else: {:error, :full_report_document_identity_mismatch}
  end

  defp validate_canonical_hash(hash, report) do
    if valid_hash?(hash) and hash == FullReportEnvelope.canonical_sha256(report),
      do: :ok,
      else: {:error, :canonical_report_hash_mismatch}
  end

  defp validate_decision_hash(hash, decision) do
    if valid_hash?(hash) and hash == FullReportEnvelope.canonical_sha256(decision),
      do: :ok,
      else: {:error, :decision_hash_mismatch}
  end

  defp expected_full_report_hash(report, expected) do
    if is_binary(expected.full_report_hash) and
         report["full_report_hash"] == expected.full_report_hash,
       do: :ok,
       else: {:error, :full_report_hash_mismatch}
  end

  defp validate_decision(decision) when is_map(decision) do
    portfolio = decision["portfolio"]
    trading = decision["trading"]
    status = decision["status"]
    warnings = decision["warnings"]

    with :ok <- exact_keys(decision, @decision_keys),
         true <- decision["schema_version"] == 1 or {:error, :invalid_decision_schema},
         true <- status in ~w(complete partial) or {:error, :invalid_decision_status},
         :ok <- validate_warnings(status, warnings),
         :ok <- validate_portfolio(portfolio, status),
         :ok <- validate_trading(trading, status) do
      :ok
    else
      false -> {:error, :invalid_decision}
      {:error, _} = error -> error
    end
  end

  defp validate_decision(_), do: {:error, :invalid_decision}

  defp validate_warnings(status, warnings) when is_list(warnings) do
    valid =
      length(warnings) <= length(@warning_codes) and
        Enum.uniq(warnings) == warnings and
        Enum.all?(warnings, &(&1 in @warning_codes)) and
        ((status == "complete" and warnings == []) or
           (status == "partial" and warnings != []))

    if valid, do: :ok, else: {:error, :invalid_decision_warnings}
  end

  defp validate_warnings(_, _), do: {:error, :invalid_decision_warnings}

  defp validate_portfolio(portfolio, status) when is_map(portfolio) do
    with :ok <- exact_keys(portfolio, @portfolio_keys),
         true <- nullable_enum?(portfolio["rating"], @ratings) or {:error, :invalid_rating},
         true <-
           nullable_text?(portfolio["executive_summary"], 32_768) or
             {:error, :invalid_executive_summary},
         true <-
           nullable_text?(portfolio["investment_thesis"], 32_768) or
             {:error, :invalid_investment_thesis},
         true <-
           nullable_text?(portfolio["time_horizon"], 512) or
             {:error, :invalid_time_horizon},
         :ok <- validate_target_contract(portfolio, status),
         :ok <- validate_complete_portfolio(portfolio, status) do
      :ok
    else
      false -> {:error, :invalid_portfolio_decision}
      {:error, _} = error -> error
    end
  end

  defp validate_portfolio(_, _), do: {:error, :invalid_portfolio_decision}

  defp validate_complete_portfolio(_portfolio, "partial"), do: :ok

  defp validate_complete_portfolio(portfolio, "complete") do
    if portfolio["rating"] in @ratings and
         required_text?(portfolio["executive_summary"], 32_768) and
         required_text?(portfolio["investment_thesis"], 32_768) and
         portfolio["price_target_status"] in ~w(available unavailable),
       do: :ok,
       else: {:error, :incomplete_portfolio_decision}
  end

  defp validate_target_contract(portfolio, decision_status) do
    target = portfolio["price_target"]
    currency = portfolio["price_target_currency"]
    rationale = portfolio["price_target_rationale"]
    unavailable_reason = portfolio["price_target_unavailable_reason"]

    valid =
      case portfolio["price_target_status"] do
        "available" ->
          positive_number?(target) and required_text?(currency, 8) and
            Regex.match?(@currency, currency) and required_text?(rationale, 32_768) and
            is_nil(unavailable_reason) and (currency != "VND" or is_integer(target))

        "unavailable" ->
          is_nil(target) and is_nil(currency) and is_nil(rationale) and
            required_text?(unavailable_reason, 32_768)

        "unknown" ->
          decision_status == "partial" and is_nil(target) and is_nil(currency) and
            is_nil(rationale) and is_nil(unavailable_reason)

        _ ->
          false
      end

    if valid, do: :ok, else: {:error, :invalid_price_target_contract}
  end

  defp validate_trading(trading, status) when is_map(trading) do
    with :ok <- exact_keys(trading, @trading_keys),
         true <- nullable_enum?(trading["action"], @actions) or {:error, :invalid_action},
         true <-
           nullable_text?(trading["reasoning"], 32_768) or
             {:error, :invalid_trading_reasoning},
         true <-
           nullable_positive_number?(trading["entry_price"]) or
             {:error, :invalid_entry_price},
         true <-
           nullable_positive_number?(trading["stop_loss"]) or
             {:error, :invalid_stop_loss},
         true <-
           nullable_text?(trading["position_sizing"], 2_048) or
             {:error, :invalid_position_sizing},
         :ok <- validate_complete_trading(trading, status) do
      :ok
    else
      false -> {:error, :invalid_trading_decision}
      {:error, _} = error -> error
    end
  end

  defp validate_trading(_, _), do: {:error, :invalid_trading_decision}

  defp validate_complete_trading(_trading, "partial"), do: :ok

  defp validate_complete_trading(trading, "complete") do
    if trading["action"] in @actions and required_text?(trading["reasoning"], 32_768),
      do: :ok,
      else: {:error, :incomplete_trading_decision}
  end

  defp encoded_size(value, max_bytes, error) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      {:ok, _encoded} -> {:error, error}
      _ -> {:error, :invalid_json_payload}
    end
  end

  defp exact_keys(value, keys) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_response_fields}
  end

  defp exact_keys(_, _), do: {:error, :invalid_response_fields}

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(@sha256, value)
  defp nullable_enum?(nil, _allowed), do: true
  defp nullable_enum?(value, allowed), do: value in allowed
  defp nullable_text?(nil, _max_bytes), do: true
  defp nullable_text?(value, max_bytes), do: required_text?(value, max_bytes)

  defp required_text?(value, max_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.trim(value) != "" and
      not Regex.match?(@forbidden_text, value)
  end

  defp nullable_positive_number?(nil), do: true
  defp nullable_positive_number?(value), do: positive_number?(value)
  defp positive_number?(value) when is_integer(value), do: value > 0
  defp positive_number?(value) when is_float(value), do: value > 0
  defp positive_number?(_), do: false
end
