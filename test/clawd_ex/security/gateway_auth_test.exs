defmodule ClawdEx.Security.GatewayAuthTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Security.GatewayAuth
  alias ClawdEx.Security.ApiKey

  setup do
    # Clear API keys
    if GenServer.whereis(ApiKey), do: ApiKey.clear()

    # Save and restore config
    original_gateway_auth = Application.get_env(:clawd_ex, :gateway_auth)
    original_api_token = Application.get_env(:clawd_ex, :api_token)
    original_gateway_token = Application.get_env(:clawd_ex, :gateway_token)

    on_exit(fn ->
      if original_gateway_auth,
        do: Application.put_env(:clawd_ex, :gateway_auth, original_gateway_auth),
        else: Application.delete_env(:clawd_ex, :gateway_auth)

      if original_api_token,
        do: Application.put_env(:clawd_ex, :api_token, original_api_token),
        else: Application.delete_env(:clawd_ex, :api_token)

      if original_gateway_token,
        do: Application.put_env(:clawd_ex, :gateway_token, original_gateway_token),
        else: Application.delete_env(:clawd_ex, :gateway_token)
    end)

    :ok
  end

  describe "disabled mode (default)" do
    test "allows all requests when disabled" do
      Application.put_env(:clawd_ex, :gateway_auth, enabled: false)

      assert {:ok, %{method: :none, scope: :admin}} = GatewayAuth.authenticate(nil)
      assert {:ok, %{method: :none, scope: :admin}} = GatewayAuth.authenticate("")
      assert {:ok, %{method: :none, scope: :admin}} = GatewayAuth.authenticate("Bearer anything")
      assert {:ok, %{method: :none, scope: :admin}} = GatewayAuth.authenticate("Basic dGVzdDp0ZXN0")
    end

    test "returns skip when not configured at all" do
      Application.delete_env(:clawd_ex, :gateway_auth)

      assert {:ok, %{method: :none}} = GatewayAuth.authenticate(nil)
    end
  end

  describe "bearer token auth" do
    setup do
      Application.put_env(:clawd_ex, :gateway_auth,
        enabled: true,
        token: "my-secret-token",
        username: nil,
        password: nil
      )

      :ok
    end

    test "accepts valid configured token" do
      assert {:ok, %{method: :bearer_token, scope: :admin}} =
               GatewayAuth.authenticate("Bearer my-secret-token")
    end

    test "rejects invalid token" do
      assert {:error, _} = GatewayAuth.authenticate("Bearer wrong-token")
    end

    test "rejects missing auth" do
      assert {:error, :unauthorized} = GatewayAuth.authenticate(nil)
    end
  end

  describe "API key auth" do
    setup do
      Application.put_env(:clawd_ex, :gateway_auth, enabled: true, token: nil)
      Application.delete_env(:clawd_ex, :api_token)
      Application.delete_env(:clawd_ex, :gateway_token)
      :ok
    end

    test "accepts valid API key" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "gw-test", scope: "write"})

      assert {:ok, %{method: :api_key, scope: :write}} =
               GatewayAuth.authenticate("Bearer #{key_info.key}")
    end

    test "rejects invalid API key" do
      assert {:error, :invalid_key} =
               GatewayAuth.authenticate("Bearer ck_live_bad_key_here")
    end

    test "rejects revoked API key" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "revoke-gw"})
      :ok = ApiKey.revoke_key(key_info.id)

      assert {:error, :invalid_key} =
               GatewayAuth.authenticate("Bearer #{key_info.key}")
    end
  end

  describe "basic auth" do
    setup do
      Application.put_env(:clawd_ex, :gateway_auth,
        enabled: true,
        token: nil,
        username: "admin",
        password: "secret123"
      )

      :ok
    end

    test "accepts valid credentials" do
      encoded = Base.encode64("admin:secret123")

      assert {:ok, %{method: :basic_auth, scope: :admin}} =
               GatewayAuth.authenticate("Basic #{encoded}")
    end

    test "rejects wrong password" do
      encoded = Base.encode64("admin:wrong")

      assert {:error, :invalid_credentials} =
               GatewayAuth.authenticate("Basic #{encoded}")
    end

    test "rejects wrong username" do
      encoded = Base.encode64("nobody:secret123")

      assert {:error, :invalid_credentials} =
               GatewayAuth.authenticate("Basic #{encoded}")
    end

    test "rejects malformed base64" do
      assert {:error, :invalid_encoding} =
               GatewayAuth.authenticate("Basic not-valid-base64!!!")
    end
  end

  describe "mixed auth" do
    setup do
      Application.put_env(:clawd_ex, :gateway_auth,
        enabled: true,
        token: "static-token",
        username: "admin",
        password: "pass123"
      )

      :ok
    end

    test "bearer token works" do
      assert {:ok, %{method: :bearer_token}} =
               GatewayAuth.authenticate("Bearer static-token")
    end

    test "basic auth works alongside bearer" do
      encoded = Base.encode64("admin:pass123")

      assert {:ok, %{method: :basic_auth}} =
               GatewayAuth.authenticate("Basic #{encoded}")
    end

    test "API key also works" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "mixed-test"})

      assert {:ok, %{method: :api_key}} =
               GatewayAuth.authenticate("Bearer #{key_info.key}")
    end
  end
end
