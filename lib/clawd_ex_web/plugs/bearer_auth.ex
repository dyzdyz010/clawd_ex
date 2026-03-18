defmodule ClawdExWeb.Plugs.BearerAuth do
  @moduledoc """
  Gateway Bearer token authentication plug.

  Validates requests against a single gateway token configured via:

      config :clawd_ex, :gateway_token, "my-secret-token"

  When no token is configured (nil or empty string), authentication is
  skipped and all requests pass through. This allows development without
  requiring a token.
  """

  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    token = Application.get_env(:clawd_ex, :gateway_token)

    if is_nil(token) || token == "" do
      # No token configured — skip authentication
      conn
    else
      case get_req_header(conn, "authorization") do
        ["Bearer " <> provided_token] when provided_token == token ->
          conn

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
          |> halt()
      end
    end
  end
end
