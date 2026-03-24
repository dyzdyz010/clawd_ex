defmodule ClawdEx.Security.GatewayAuth do
  @moduledoc """
  Unified Gateway authentication logic.

  Supports:
  1. Bearer token (API key or configured token)
  2. Basic Auth (username/password)

  Configuration:

      config :clawd_ex, :gateway_auth,
        enabled: true,
        token: "my-secret-token",
        username: "admin",
        password: "secret123"

  When `enabled` is false (default), all requests pass through (dev mode).
  """

  @doc """
  Authenticate a request given the Authorization header value.

  Returns:
  - `{:ok, %{method: atom, scope: atom}}` on success
  - `:skip` when auth is disabled
  - `{:error, reason}` on failure
  """
  def authenticate(nil), do: check_disabled_or_fail()
  def authenticate(""), do: check_disabled_or_fail()

  def authenticate("Bearer " <> token) do
    if enabled?() do
      verify_bearer(token)
    else
      {:ok, %{method: :none, scope: :admin}}
    end
  end

  def authenticate("Basic " <> encoded) do
    if enabled?() do
      verify_basic(encoded)
    else
      {:ok, %{method: :none, scope: :admin}}
    end
  end

  def authenticate(_), do: check_disabled_or_fail()

  @doc "Check if gateway auth is enabled."
  def enabled? do
    config = Application.get_env(:clawd_ex, :gateway_auth, [])
    Keyword.get(config, :enabled, false)
  end

  # --- Private ---

  defp check_disabled_or_fail do
    if enabled?() do
      {:error, :unauthorized}
    else
      {:ok, %{method: :none, scope: :admin}}
    end
  end

  defp verify_bearer(token) do
    configured_token = get_configured_token()

    cond do
      # Check configured static token
      configured_token != nil and configured_token != "" and token == configured_token ->
        {:ok, %{method: :bearer_token, scope: :admin}}

      # Check API key
      String.starts_with?(token, "ck_live_") ->
        case ClawdEx.Security.ApiKey.verify_key(token) do
          {:ok, key_info} ->
            {:ok, %{method: :api_key, scope: key_info.scope, key_id: key_info.id}}
          {:error, :invalid_key} ->
            {:error, :invalid_key}
        end

      # Legacy gateway token
      true ->
        legacy_token = Application.get_env(:clawd_ex, :gateway_token)
        if legacy_token && legacy_token != "" && token == legacy_token do
          {:ok, %{method: :bearer_token, scope: :admin}}
        else
          {:error, :invalid_token}
        end
    end
  end

  defp verify_basic(encoded) do
    config = Application.get_env(:clawd_ex, :gateway_auth, [])
    expected_user = Keyword.get(config, :username)
    expected_pass = Keyword.get(config, :password)

    if is_nil(expected_user) or is_nil(expected_pass) do
      {:error, :basic_auth_not_configured}
    else
      case Base.decode64(encoded) do
        {:ok, decoded} ->
          case String.split(decoded, ":", parts: 2) do
            [user, pass] when user == expected_user and pass == expected_pass ->
              {:ok, %{method: :basic_auth, scope: :admin}}
            _ ->
              {:error, :invalid_credentials}
          end
        :error ->
          {:error, :invalid_encoding}
      end
    end
  end

  defp get_configured_token do
    config = Application.get_env(:clawd_ex, :gateway_auth, [])
    Keyword.get(config, :token) ||
      Application.get_env(:clawd_ex, :api_token) ||
      System.get_env("CLAWD_API_TOKEN")
  end
end
