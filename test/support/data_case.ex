defmodule GxPortfolioIntelligence.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias GxPortfolioIntelligence.Repo
      import Ecto.Query
    end
  end

  setup tags do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(GxPortfolioIntelligence.Repo,
        shared: not tags[:async]
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end
end
