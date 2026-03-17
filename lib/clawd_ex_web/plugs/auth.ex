defmodule ClawdExWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug for API routes.

  Supports Bearer token authentication. Reads allowed tokens from config:

      config :clawd_ex, :auth,
        tokens: ["my-secret-token"],
        enabled: true

  When `enabled` is false or tokens list is empty, all requests pass through.
  When enabled, API routes require a valid Bearer token in the Authorization header.

  Usage in router:

      pipeline :api_auth do
        plug ClawdExWeb.Plugs.Auth
      end
  """

  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    auth_config = Application.get_env(:clawd_ex, :auth, [])
    enabled = Keyword.get(auth_config, :enabled, false)
    tokens = Keyword.get(auth_config, :tokens, []) |> Enum.filter(&is_binary/1)

    if enabled and tokens != [] do
      authenticate(conn, tokens)
    else
      # Auth disabled or no tokens configured — pass through
      conn
    end
  end

  defp authenticate(conn, allowed_tokens) do
    case get_bearer_token(conn) do
      {:ok, token} ->
        if token in allowed_tokens do
          conn
          |> assign(:authenticated, true)
        else
          unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        token = String.trim(token)

        if token == "" do
          :error
        else
          {:ok, token}
        end

      _ ->
        :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized", message: "Valid Bearer token required"}))
    |> halt()
  end
end
