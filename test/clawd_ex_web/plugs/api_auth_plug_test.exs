defmodule ClawdExWeb.Plugs.ApiAuthPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ClawdExWeb.Plugs.ApiAuthPlug
  alias ClawdEx.Security.ApiKey

  setup do
    # Clear existing keys
    if GenServer.whereis(ApiKey), do: ApiKey.clear()

    # Set a configured token for tests
    original = Application.get_env(:clawd_ex, :api_token)
    Application.put_env(:clawd_ex, :api_token, "test-bearer-token")

    on_exit(fn ->
      if original, do: Application.put_env(:clawd_ex, :api_token, original),
      else: Application.delete_env(:clawd_ex, :api_token)
    end)

    :ok
  end

  defp build_test_conn do
    conn(:get, "/")
  end

  describe "Bearer token auth" do
    test "accepts valid bearer token" do
      conn =
        build_test_conn()
        |> put_req_header("authorization", "Bearer test-bearer-token")
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      refute conn.halted
      assert conn.assigns[:auth_scope] == :admin
      assert conn.assigns[:auth_method] == :bearer_token
    end

    test "rejects invalid bearer token" do
      conn =
        build_test_conn()
        |> put_req_header("authorization", "Bearer wrong-token")
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "API key auth" do
    test "accepts valid API key" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "plug-test", scope: "write"})

      conn =
        build_test_conn()
        |> put_req_header("authorization", "Bearer #{key_info.key}")
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      refute conn.halted
      assert conn.assigns[:auth_scope] == :write
      assert conn.assigns[:auth_method] == :api_key
      assert conn.assigns[:api_key_id] == key_info.id
    end

    test "rejects invalid API key" do
      conn =
        build_test_conn()
        |> put_req_header("authorization", "Bearer ck_live_invalid123")
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects revoked API key" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "revoke-test"})
      :ok = ApiKey.revoke_key(key_info.id)

      conn =
        build_test_conn()
        |> put_req_header("authorization", "Bearer #{key_info.key}")
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "no auth configured (dev mode)" do
    test "skips auth when no token configured" do
      Application.delete_env(:clawd_ex, :api_token)
      Application.delete_env(:clawd_ex, :gateway_token)
      System.delete_env("CLAWD_API_TOKEN")

      conn =
        build_test_conn()
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      refute conn.halted
      assert conn.assigns[:auth_scope] == :admin
      assert conn.assigns[:auth_method] == :none
    end
  end

  describe "missing authorization header" do
    test "returns 401 when token is configured but no auth header" do
      conn =
        build_test_conn()
        |> ApiAuthPlug.call(ApiAuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end
end
