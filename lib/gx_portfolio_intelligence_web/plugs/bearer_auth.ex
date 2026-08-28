defmodule GxPortfolioIntelligenceWeb.Plugs.BearerAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:gx_portfolio_intelligence, :auth_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] when is_binary(expected) and expected != "" ->
        if secure_equal?(provided, expected), do: conn, else: reject(conn, 401, "unauthorized")

      _ when not is_binary(expected) or expected == "" ->
        reject(conn, 503, "api_auth_not_configured")

      _ ->
        reject(conn, 401, "unauthorized")
    end
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  defp reject(conn, status, code) do
    conn |> put_status(status) |> json(%{error: %{code: code}}) |> halt()
  end
end
