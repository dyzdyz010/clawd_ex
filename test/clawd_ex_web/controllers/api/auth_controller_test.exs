defmodule ClawdExWeb.Api.AuthControllerTest do
  use ClawdExWeb.ConnCase, async: false

  alias ClawdEx.Security.ApiKey

  setup do
    # Clear existing keys (GenServer started by app supervisor)
    if GenServer.whereis(ApiKey), do: ApiKey.clear()

    # Set a configured bearer token for admin auth
    original = Application.get_env(:clawd_ex, :api_token)
    Application.put_env(:clawd_ex, :api_token, "admin-test-token")

    # Reset rate limits
    ClawdExWeb.Plugs.RateLimitPlug.reset()

    on_exit(fn ->
      if original, do: Application.put_env(:clawd_ex, :api_token, original),
      else: Application.delete_env(:clawd_ex, :api_token)
      ClawdExWeb.Plugs.RateLimitPlug.reset()
    end)

    :ok
  end

  defp admin_conn(conn) do
    put_req_header(conn, "authorization", "Bearer admin-test-token")
  end

  describe "GET /api/v1/auth/keys" do
    test "lists keys with admin auth", %{conn: conn} do
      {:ok, _} = ApiKey.generate_key(%{name: "test-key-1", scope: "read"})
      {:ok, _} = ApiKey.generate_key(%{name: "test-key-2", scope: "write"})

      conn =
        conn
        |> admin_conn()
        |> get("/api/v1/auth/keys")

      assert json_response(conn, 200)["data"] |> length() == 2
    end

    test "rejects non-admin API key", %{conn: conn} do
      {:ok, read_key} = ApiKey.generate_key(%{name: "read-only", scope: "read"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{read_key.key}")
        |> get("/api/v1/auth/keys")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "rejects unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/v1/auth/keys")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/v1/auth/keys" do
    test "creates a new key with admin auth", %{conn: conn} do
      conn =
        conn
        |> admin_conn()
        |> post("/api/v1/auth/keys", %{name: "new-key", scope: "write"})

      response = json_response(conn, 201)
      assert response["data"]["name"] == "new-key"
      assert response["data"]["scope"] == "write"
      assert response["data"]["key"] |> String.starts_with?("ck_live_")
    end

    test "creates key with default read scope", %{conn: conn} do
      conn =
        conn
        |> admin_conn()
        |> post("/api/v1/auth/keys", %{name: "default-scope"})

      response = json_response(conn, 201)
      assert response["data"]["scope"] == "read"
    end
  end

  describe "DELETE /api/v1/auth/keys/:id" do
    test "revokes a key with admin auth", %{conn: conn} do
      {:ok, key_info} = ApiKey.generate_key(%{name: "delete-me"})

      conn =
        conn
        |> admin_conn()
        |> delete("/api/v1/auth/keys/#{key_info.id}")

      response = json_response(conn, 200)
      assert response["data"]["revoked"] == true

      # Verify the key is actually revoked
      assert {:error, :invalid_key} = ApiKey.verify_key(key_info.key)
    end

    test "returns 404 for non-existent key", %{conn: conn} do
      conn =
        conn
        |> admin_conn()
        |> delete("/api/v1/auth/keys/non-existent-id")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end
end
