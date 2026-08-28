defmodule GxPortfolioIntelligence.Release do
  @moduledoc false

  @app :gx_portfolio_intelligence

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _pid, _migrated} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _pid, _migrated} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, :down, to: version)
      end)
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
