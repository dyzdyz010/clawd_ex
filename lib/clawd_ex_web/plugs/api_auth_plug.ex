defmodule ClawdExWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  API authentication plug for the Gateway REST API.

  Validates Bearer token from the Authorization header against:
  1. Application config: `config :clawd_ex, :api_token`
  2. Environment variable: `CLAWD_API_TOKEN`
  3. Falls back to existing `gateway_token` config

  When no token is configured, authentication is skipped (dev mode).
  """

  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    configured_token = get_configured_token()

    if is_nil(configured_token) || configured_token == "" do
      # No token configured — dev mode, skip auth
      conn
    else
      case get_req_header(conn, "authorization") do
        ["Bearer " <> provided] when provided == configured_token ->
          conn

        _ ->
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

  defp get_configured_token do
    Application.get_env(:clawd_ex, :api_token) ||
      System.get_env("CLAWD_API_TOKEN") ||
      Application.get_env(:clawd_ex, :gateway_token)
  end
end
