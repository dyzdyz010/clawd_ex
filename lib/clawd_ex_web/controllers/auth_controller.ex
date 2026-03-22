defmodule ClawdExWeb.AuthController do
  @moduledoc """
  Handles auth callback (setting session cookie) and logout.

  The login LiveView redirects here after validating credentials,
  so that we can write to the Plug session (which LiveView cannot do directly).
  """
  use ClawdExWeb, :controller

  def callback(conn, params) do
    cond do
      # Token login — validate again server-side
      token = params["token"] ->
        case ClawdExWeb.Auth.validate_token(token) do
          :ok ->
            return_to = get_session(conn, :return_to) || "/"

            conn
            |> put_session(:web_authenticated, true)
            |> configure_session(renew: true)
            |> delete_session(:return_to)
            |> redirect(to: return_to)

          :error ->
            conn
            |> put_flash(:error, "Invalid token")
            |> redirect(to: "/login")
        end

      # Password login — the LiveView already validated, just set session
      params["_auth"] == "password" ->
        return_to = get_session(conn, :return_to) || "/"

        conn
        |> put_session(:web_authenticated, true)
        |> configure_session(renew: true)
        |> delete_session(:return_to)
        |> redirect(to: return_to)

      true ->
        conn
        |> redirect(to: "/login")
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end
end
