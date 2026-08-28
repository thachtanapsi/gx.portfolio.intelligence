defmodule GxPortfolioIntelligenceWeb.ErrorJSON do
  def render(template, _assigns) do
    %{error: %{code: Phoenix.Controller.status_message_from_template(template)}}
  end
end
