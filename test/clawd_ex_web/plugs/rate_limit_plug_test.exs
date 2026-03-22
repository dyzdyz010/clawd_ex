defmodule ClawdExWeb.Plugs.RateLimitPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ClawdExWeb.Plugs.RateLimitPlug

  setup do
    # Configure a tight limit for testing
    Application.put_env(:clawd_ex, :rate_limit,
      max_requests: 5,
      window_ms: 60_000
    )

    RateLimitPlug.reset()

    on_exit(fn ->
      Application.delete_env(:clawd_ex, :rate_limit)
      RateLimitPlug.reset()
    end)

    :ok
  end

  defp build_conn_with_ip(ip) do
    conn(:get, "/")
    |> Map.put(:remote_ip, ip)
  end

  describe "rate limiting" do
    test "allows requests under the limit" do
      conn =
        build_conn_with_ip({192, 168, 1, 100})
        |> RateLimitPlug.call(RateLimitPlug.init([]))

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["5"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["4"]
    end

    test "returns 429 when limit exceeded" do
      ip = {10, 0, 0, 1}

      # Exhaust the limit
      for _ <- 1..5 do
        build_conn_with_ip(ip)
        |> RateLimitPlug.call(RateLimitPlug.init([]))
      end

      # This should be rejected
      conn =
        build_conn_with_ip(ip)
        |> RateLimitPlug.call(RateLimitPlug.init([]))

      assert conn.halted
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "rate_limited"
    end

    test "rate limits are per-IP" do
      ip1 = {10, 0, 0, 2}
      ip2 = {10, 0, 0, 3}

      # Exhaust limit for IP 1
      for _ <- 1..5 do
        build_conn_with_ip(ip1)
        |> RateLimitPlug.call(RateLimitPlug.init([]))
      end

      # Different IP should still work
      conn =
        build_conn_with_ip(ip2)
        |> RateLimitPlug.call(RateLimitPlug.init([]))

      refute conn.halted
    end

    test "uses API key ID when available" do
      ip = {10, 0, 0, 4}

      # Exhaust limit for key "key-1"
      for _ <- 1..5 do
        build_conn_with_ip(ip)
        |> assign(:api_key_id, "key-1")
        |> RateLimitPlug.call(RateLimitPlug.init([]))
      end

      # Same IP but different key should work
      conn =
        build_conn_with_ip(ip)
        |> assign(:api_key_id, "key-2")
        |> RateLimitPlug.call(RateLimitPlug.init([]))

      refute conn.halted
    end

    test "sets rate limit headers" do
      conn =
        build_conn_with_ip({10, 0, 0, 5})
        |> RateLimitPlug.call(RateLimitPlug.init([]))

      assert get_resp_header(conn, "x-ratelimit-limit") == ["5"]
      remaining = get_resp_header(conn, "x-ratelimit-remaining") |> List.first() |> String.to_integer()
      assert remaining >= 0
    end
  end
end
