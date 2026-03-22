defmodule ClawdExWeb.LoginLive do
  @moduledoc """
  Login page for web UI authentication.

  Adapts its form based on the auth mode:
  - Token mode: single token input field
  - Password mode: username + password fields
  """
  use ClawdExWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    mode = ClawdExWeb.Auth.get_mode()

    # If auth is disabled or already authenticated, redirect to home
    if ClawdExWeb.Auth.auth_disabled?() or session["web_authenticated"] do
      {:ok, push_navigate(socket, to: "/")}
    else
      socket =
        socket
        |> assign(:mode, mode)
        |> assign(:error, nil)
        |> assign(:token, "")
        |> assign(:username, "")
        |> assign(:password, "")

      {:ok, socket, layout: false}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 flex items-center justify-center px-4">
      <div class="max-w-md w-full">
        <div class="text-center mb-8">
          <span class="text-5xl">🤖</span>
          <h1 class="text-2xl font-bold text-white mt-4">ClawdEx</h1>
          <p class="text-gray-400 mt-2">Authentication required</p>
        </div>

        <div class="bg-gray-800 rounded-xl p-6 shadow-xl border border-gray-700">
          <%= if @error do %>
            <div class="bg-red-600/20 border border-red-500/50 text-red-300 px-4 py-3 rounded-lg mb-4">
              {@error}
            </div>
          <% end %>

          <%= if @mode == :token do %>
            <form phx-submit="login_token" class="space-y-4">
              <div>
                <label for="token" class="block text-sm font-medium text-gray-300 mb-2">
                  Access Token
                </label>
                <input
                  type="password"
                  name="token"
                  id="token"
                  value={@token}
                  placeholder="Enter your access token"
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  autocomplete="current-password"
                  autofocus
                />
              </div>
              <button
                type="submit"
                class="w-full py-3 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors"
              >
                Login
              </button>
            </form>
          <% else %>
            <form phx-submit="login_password" class="space-y-4">
              <div>
                <label for="username" class="block text-sm font-medium text-gray-300 mb-2">
                  Username
                </label>
                <input
                  type="text"
                  name="username"
                  id="username"
                  value={@username}
                  placeholder="Username"
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  autocomplete="username"
                  autofocus
                />
              </div>
              <div>
                <label for="password" class="block text-sm font-medium text-gray-300 mb-2">
                  Password
                </label>
                <input
                  type="password"
                  name="password"
                  id="password"
                  value={@password}
                  placeholder="Password"
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  autocomplete="current-password"
                />
              </div>
              <button
                type="submit"
                class="w-full py-3 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors"
              >
                Login
              </button>
            </form>
          <% end %>
        </div>

        <p class="text-center text-gray-500 text-sm mt-6">
          ClawdEx v0.1.0
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("login_token", %{"token" => token}, socket) do
    case ClawdExWeb.Auth.validate_token(token) do
      :ok ->
        {:noreply, redirect(socket, to: "/auth/callback?token=" <> URI.encode_www_form(token))}

      :error ->
        {:noreply, assign(socket, :error, "Invalid token")}
    end
  end

  @impl true
  def handle_event("login_password", %{"username" => username, "password" => password}, socket) do
    case ClawdExWeb.Auth.validate_credentials(username, password) do
      :ok ->
        {:noreply, redirect(socket, to: "/auth/callback?_auth=password")}

      :error ->
        {:noreply, assign(socket, :error, "Invalid username or password")}
    end
  end
end
