defmodule GxPortfolioIntelligence.UniverseWorkerTest do
  use GxPortfolioIntelligence.DataCase, async: false

  alias GxPortfolioIntelligence.{Repo, Research}
  alias GxPortfolioIntelligence.Schemas.ResearchBatch
  alias GxPortfolioIntelligence.Workers.UniverseWorker

  setup do
    runner = Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)
    port_config = Application.get_env(:gx_portfolio_intelligence, :port_runner)
    root = Path.join(System.tmp_dir!(), "gx-pi-universe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      GxPortfolioIntelligence.SlotCapturingRunner
    )

    Application.put_env(:gx_portfolio_intelligence, :test_pid, self())

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(port_config, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :trading_agents_runner, runner)
      Application.put_env(:gx_portfolio_intelligence, :port_runner, port_config)
      Application.delete_env(:gx_portfolio_intelligence, :test_pid)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "non-trading day is a no-op and a delayed retry uses the original slot" do
    job = %Oban.Job{
      args: %{
        "analysis_date" => "2026-08-21",
        "slot" => "09:15",
        "limit" => 600,
        "frozen" => false
      }
    }

    assert :ok = UniverseWorker.perform(job)
    assert_receive {:universe_opts, opts}
    assert DateTime.to_iso8601(opts[:cutoff]) == "2026-08-21T02:15:00Z"
    assert Research.snapshot_for(~D[2026-08-21], "09:15").status == "skipped"
    assert Repo.aggregate(ResearchBatch, :count) == 0
  end

  test "rejects a runner response whose identity differs from the request" do
    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      GxPortfolioIntelligence.WrongIdentityRunner
    )

    job = %Oban.Job{
      args: %{
        "analysis_date" => "2026-08-21",
        "slot" => "09:15",
        "limit" => 600,
        "frozen" => false
      }
    }

    assert {:error, :universe_identity_mismatch} = UniverseWorker.perform(job)
  end
end
