defmodule ClawdExWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  API authentication plug for the Gateway REST API.

  Supports two authentication methods:
  1. Bearer token — legacy token-based auth (full access, scope: :admin)
  2. API Key — `ck_live_xxx` keys with scope-based access control

  Authentication priority:
  - Bearer token is checked first (backward compatible)
  - API Key is checked second
  - When no token is configured AND no API keys exist, auth is skipped (dev mode)

  Scope-based access control:
  - :read  — GET requests only
  - :write — GET + POST/PUT/PATCH/DELETE
  - :admin — full access including management endpoints
  """

  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    configured_token = get_configured_token()

    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] ->
        authenticate_bearer(conn, provided, configured_token)

      _ ->
        if is_nil(configured_token) || configured_token == "" do
          # No token configured — dev mode, skip auth (grant admin)
          conn
          |> assign(:auth_scope, :admin)
          |> assign(:auth_method, :none)
        else
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{
            error: %{
              code: "unauthorized",
              message: "Invalid or missing API token"
            }
          }))
          |> halt()
        end
    end
  end

  defp authenticate_bearer(conn, provided, configured_token) do
    cond do
      # Check legacy bearer token first
      configured_token != nil && configured_token != "" && provided == configured_token ->
        conn
        |> assign(:auth_scope, :admin)
        |> assign(:auth_method, :bearer_token)

      # Check API key (keys look like ck_live_xxx)
      String.starts_with?(provided, "ck_live_") ->
        authenticate_api_key(conn, provided)

      # Invalid token
      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{
          error: %{
            code: "unauthorized",
            message: "Invalid or missing API token"
          }
        }))
        |> halt()
    end
  end

  defp authenticate_api_key(conn, key) do
    case ClawdEx.Security.ApiKey.verify_key(key) do
      {:ok, key_info} ->
        conn
        |> assign(:auth_scope, key_info.scope)
        |> assign(:auth_method, :api_key)
        |> assign(:api_key_id, key_info.id)
        |> assign(:api_key_name, key_info.name)

      {:error, :invalid_key} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{
          error: %{
            code: "unauthorized",
            message: "Invalid or revoked API key"
          }
        }))
        |> halt()
    end
  end

  defp get_configured_token do
    Application.get_env(:clawd_ex, :api_token) ||
      System.get_env("CLAWD_API_TOKEN") ||
      Application.get_env(:clawd_ex, :gateway_token)
  end
end
