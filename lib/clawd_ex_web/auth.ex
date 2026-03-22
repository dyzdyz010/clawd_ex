defmodule ClawdExWeb.Auth do
  @moduledoc """
  Web UI authentication for ClawdEx.

  Supports two modes (configurable via `:web_auth` config):

  - **:token** (default) — URL param `?token=xxx` or `Authorization: Bearer xxx`
    - Token from config or `CLAWD_WEB_TOKEN` env var
    - No token configured = auth disabled (dev-friendly)
  - **:password** — Username/password form login with session cookie

  ## Configuration

      # Token mode (default)
      config :clawd_ex, :web_auth,
        mode: :token,
        token: "my-secret-token"

      # Password mode
      config :clawd_ex, :web_auth,
        mode: :password,
        username: "admin",
        password: "secret"

      # Explicitly disabled
      config :clawd_ex, :web_auth,
        mode: :disabled
  """

  @doc """
  LiveView `on_mount` hook for authenticated routes.

  Used in the router via:

      live_session :authenticated, on_mount: [{ClawdExWeb.Auth, :ensure_authenticated}]
  """
  def on_mount(:ensure_authenticated, _params, session, socket) do
    if auth_disabled?() do
      {:cont, socket}
    else
      if session["web_authenticated"] do
        {:cont, socket}
      else
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
      end
    end
  end

  @doc """
  Returns true when authentication is effectively disabled.

  Auth is disabled when:
  - mode is `:disabled`
  - mode is `:token` but no token is configured (nil or empty)
  - mode is `:password` but no username/password is configured
  """
  def auth_disabled?() do
    config = get_config()
    mode = Keyword.get(config, :mode, :token)

    case mode do
      :disabled ->
        true

      :token ->
        token = get_configured_token(config)
        is_nil(token) or token == ""

      :password ->
        username = Keyword.get(config, :username)
        password = Keyword.get(config, :password)
        is_nil(username) or is_nil(password) or username == "" or password == ""

      _ ->
        true
    end
  end

  @doc """
  Validates a token against the configured token.
  """
  def validate_token(token) when is_binary(token) do
    config = get_config()
    configured_token = get_configured_token(config)

    if configured_token && configured_token != "" && Plug.Crypto.secure_compare(token, configured_token) do
      :ok
    else
      :error
    end
  end

  def validate_token(_), do: :error

  @doc """
  Validates username/password against configured credentials.
  """
  def validate_credentials(username, password)
      when is_binary(username) and is_binary(password) do
    config = get_config()
    configured_username = Keyword.get(config, :username, "")
    configured_password = Keyword.get(config, :password, "")

    username_match = Plug.Crypto.secure_compare(username, configured_username)
    password_match = Plug.Crypto.secure_compare(password, configured_password)

    if username_match and password_match do
      :ok
    else
      :error
    end
  end

  def validate_credentials(_, _), do: :error

  @doc """
  Returns the current auth mode (:token, :password, or :disabled).
  """
  def get_mode do
    config = get_config()
    Keyword.get(config, :mode, :token)
  end

  defp get_config do
    Application.get_env(:clawd_ex, :web_auth, [])
  end

  defp get_configured_token(config) do
    Keyword.get(config, :token) || System.get_env("CLAWD_WEB_TOKEN")
  end
end
