defmodule GxPortfolioIntelligenceWeb.BearerAuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias GxPortfolioIntelligenceWeb.Plugs.BearerAuth

  test "rejects missing and malformed tokens without reflecting them" do
    conn = conn(:get, "/api/v1/research-batches/1") |> BearerAuth.call([])
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "unauthorized"}}

    conn =
      conn(:get, "/api/v1/research-batches/1")
      |> put_req_header("authorization", "Bearer wrong-secret-sentinel")
      |> BearerAuth.call([])

    assert conn.status == 401
    refute conn.resp_body =~ "wrong-secret-sentinel"
  end

  test "accepts the configured bearer token" do
    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Bearer test-api-token")
      |> BearerAuth.call([])

    refute conn.halted
  end
end
