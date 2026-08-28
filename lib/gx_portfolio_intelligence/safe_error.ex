defmodule GxPortfolioIntelligence.SafeError do
  @moduledoc false

  @secret_patterns [
    ~r/(?i)(authorization:\s*bearer\s+)[^\s,;]+/,
    ~r/(?i)(bearer\s+)[A-Za-z0-9._~+\/-]+/,
    ~r/(?i)((?:api[_-]?key|token|password|secret)\s*[=:]\s*)[^\s,;]+/,
    ~r|(?i)(https?://[^:/\s]+:)[^@/\s]+@|
  ]

  def redact(value) do
    value
    |> to_string()
    |> then(fn text ->
      Enum.reduce(@secret_patterns, text, &Regex.replace(&1, &2, "\\1[REDACTED]"))
    end)
    |> String.slice(0, 1_000)
  end

  def code(:timeout), do: "trading_agents_timeout"
  def code(:output_too_large), do: "trading_agents_output_too_large"
  def code(:invalid_json_contract), do: "invalid_trading_agents_contract"
  def code(:missing_schema_version), do: "invalid_trading_agents_contract"
  def code(:artifact_too_large), do: "artifact_too_large"
  def code(:path_outside_artifact_root), do: "unsafe_artifact_path"
  def code(:symlink_not_allowed), do: "unsafe_artifact_path"
  def code(:rag_api_key_not_configured), do: "rag_not_configured"
  def code(:invalid_rag_url), do: "rag_not_configured"
  def code({:command_failed, status}), do: "trading_agents_exit_#{status}"
  def code({:command_failed, status, _body}), do: "trading_agents_exit_#{status}"
  def code({:rag_http_error, status}), do: "rag_http_#{status}"
  def code({:rag_unavailable, _}), do: "rag_unavailable"
  def code({:claimed_without_recoverable_artifact, _}), do: "research_artifact_unavailable"
  def code(%Jason.DecodeError{}), do: "invalid_trading_agents_contract"
  def code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def code(_), do: "internal_dependency_error"
end
