defmodule ClawdExWeb.Plugs.WebAuthPlug do
  @moduledoc """
  Phoenix Plug for web UI authentication.

  Checks session for authentication state. If not authenticated,
  attempts token auth from URL params or headers. If all fail,
  redirects to login page.

  Unauthenticated requests to API-like paths get a 401 JSON response instead.
  """

  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if ClawdExWeb.Auth.auth_disabled?() do
      conn
      |> put_session(:web_authenticated, true)
    else
      cond do
        # Already authenticated via session
        get_session(conn, :web_authenticated) ->
          conn

        # Try token from URL param
        is_binary(conn.params["token"]) and conn.params["token"] != "" ->
          attempt_token_auth(conn, conn.params["token"])

        # Try token from Authorization header
        match?({:ok, _}, extract_bearer_token(conn)) ->
          {:ok, token} = extract_bearer_token(conn)
          attempt_token_auth(conn, token)

        # Not authenticated - redirect to login
        true ->
          redirect_to_login(conn)
      end
    end
  end

  defp attempt_token_auth(conn, token) do
    case ClawdExWeb.Auth.validate_token(token) do
      :ok ->
        conn
        |> put_session(:web_authenticated, true)
        |> configure_session(renew: true)

      :error ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(401, "Unauthorized: Invalid token")
        |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        token = String.trim(token)
        if token == "", do: :error, else: {:ok, token}

      _ ->
        :error
    end
  end

  defp redirect_to_login(conn) do
    # Store the original path for redirect after login
    return_to = conn.request_path <> if(conn.query_string != "", do: "?" <> conn.query_string, else: "")

    conn
    |> put_session(:return_to, return_to)
    |> Phoenix.Controller.redirect(to: "/login")
    |> halt()
  end
end
