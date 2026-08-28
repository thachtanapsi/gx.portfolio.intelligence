defmodule GxPortfolioIntelligence.SafeErrorTest do
  use ExUnit.Case, async: true

  alias GxPortfolioIntelligence.SafeError

  test "redacts bearer tokens, password URLs and key-value secrets" do
    text =
      "Authorization: Bearer secret-sentinel https://alice:password-sentinel@example.test API_KEY=key-sentinel"

    redacted = SafeError.redact(text)

    refute redacted =~ "secret-sentinel"
    refute redacted =~ "password-sentinel"
    refute redacted =~ "key-sentinel"
    assert redacted =~ "[REDACTED]"
  end

  test "maps dependency errors to stable public codes" do
    {:error, decode_error} = Jason.decode("not-json")

    assert SafeError.code({:command_failed, 75}) == "trading_agents_exit_75"
    assert SafeError.code({:command_failed, 75, "secret"}) == "trading_agents_exit_75"
    assert SafeError.code({:rag_http_error, 409}) == "rag_http_409"
    assert SafeError.code(decode_error) == "invalid_trading_agents_contract"
  end
end
