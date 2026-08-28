defmodule GxPortfolioIntelligence.DependencyCheck do
  @moduledoc false

  alias GxPortfolioIntelligence.{RAG, Repo}
  alias GxPortfolioIntelligence.TradingAgents.PortRunner

  def ready? do
    checks = %{
      database: database_ready?(),
      trading_agents: runner_ready?(),
      rag: rag_ready?(),
      full_analysis_config: GxPortfolioIntelligence.FullAnalysis.readiness_issues() == []
    }

    {Enum.all?(checks, fn {_name, ready} -> ready end), checks}
  end

  defp database_ready? do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp runner_ready? do
    if Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner) == PortRunner do
      config = Application.get_env(:gx_portfolio_intelligence, :port_runner, [])
      executable = config[:executable]
      root = config[:project_root]
      artifacts = config[:artifact_root]

      is_binary(executable) and File.regular?(executable) and is_binary(root) and File.dir?(root) and
        is_binary(artifacts) and Path.type(artifacts) == :absolute
    else
      true
    end
  end

  defp rag_ready? do
    if Application.get_env(:gx_portfolio_intelligence, :rag_client) ==
         GxPortfolioIntelligence.RAG.Client do
      case RAG.health() do
        {:ok, %{"status" => "ok"}} -> true
        _ -> false
      end
    else
      true
    end
  end
end
