defmodule ClawdExWeb.SettingsLive do
  use ClawdExWeb, :live_view

  # @config_file "config/runtime.exs"
  @env_file ".env"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings",
       active_tab: "general",
       config: load_config(),
       env_vars: load_env_vars(),
       system_info: get_system_info(),
       editing: false,
       save_status: nil
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("save_env", %{"env" => env_params}, socket) do
    case save_env_file(env_params) do
      :ok ->
        {:noreply,
         socket
         |> assign(env_vars: load_env_vars(), save_status: :success)
         |> put_flash(:info, "Environment variables saved")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(save_status: :error)
         |> put_flash(:error, "Failed to save: #{reason}")}
    end
  end

  @impl true
  def handle_event("restart_app", _params, socket) do
    # Queue restart in a separate process
    Task.start(fn ->
      Process.sleep(1000)
      System.stop(0)
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Application restarting...")}
  end

  defp load_config do
    %{
      app_name: Application.get_env(:clawd_ex, :app_name, "ClawdEx"),
      environment: Application.get_env(:clawd_ex, :env, Mix.env()),
      port: Application.get_env(:clawd_ex, ClawdExWeb.Endpoint)[:http][:port] || 4000,
      host: Application.get_env(:clawd_ex, ClawdExWeb.Endpoint)[:url][:host] || "localhost",
      database_url: System.get_env("DATABASE_URL") || "postgresql://localhost/clawd_ex",
      secret_key_configured:
        !!Application.get_env(:clawd_ex, ClawdExWeb.Endpoint)[:secret_key_base],
      ai_providers: get_ai_providers()
    }
  end

  defp get_ai_providers do
    providers = []

    providers =
      if System.get_env("ANTHROPIC_API_KEY") do
        [{:anthropic, "Anthropic Claude", true} | providers]
      else
        [{:anthropic, "Anthropic Claude", false} | providers]
      end

    providers =
      if System.get_env("OPENAI_API_KEY") do
        [{:openai, "OpenAI", true} | providers]
      else
        [{:openai, "OpenAI", false} | providers]
      end

    providers =
      if System.get_env("GOOGLE_API_KEY") do
        [{:google, "Google Gemini", true} | providers]
      else
        [{:google, "Google Gemini", false} | providers]
      end

    Enum.reverse(providers)
  end

  defp load_env_vars do
    case File.read(@env_file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.filter(&(String.trim(&1) != "" && !String.starts_with?(&1, "#")))
        |> Enum.map(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> {String.trim(key), String.trim(value)}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.into(%{})

      {:error, _} ->
        %{}
    end
  end

  defp save_env_file(env_params) do
    content =
      env_params
      |> Enum.map(fn {key, value} ->
        "#{key}=#{value}"
      end)
      |> Enum.join("\n")

    case File.write(@env_file, content <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_system_info do
    %{
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> List.to_string(),
      memory_total: :erlang.memory(:total) |> format_bytes(),
      memory_processes: :erlang.memory(:processes) |> format_bytes(),
      process_count: :erlang.system_info(:process_count),
      uptime: get_uptime(),
      node: Node.self()
    }
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GB"

  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    seconds = div(uptime_ms, 1000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      seconds < 86400 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 86400)}d #{div(rem(seconds, 86400), 3600)}h"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div>
        <h1 class="text-2xl font-bold text-white">Settings</h1>
        <p class="text-gray-400 text-sm mt-1">Application configuration and system info</p>
      </div>
      
    <!-- Tabs -->
      <div class="border-b border-gray-700">
        <nav class="flex gap-4">
          <.tab_button active={@active_tab} tab="general" label="General" />
          <.tab_button active={@active_tab} tab="ai" label="AI Providers" />
          <.tab_button active={@active_tab} tab="env" label="Environment" />
          <.tab_button active={@active_tab} tab="system" label="System Info" />
        </nav>
      </div>
      
    <!-- Tab Content -->
      <div class="bg-gray-800 rounded-lg p-6">
        <%= case @active_tab do %>
          <% "general" -> %>
            <.general_tab config={@config} />
          <% "ai" -> %>
            <.ai_tab config={@config} />
          <% "env" -> %>
            <.env_tab env_vars={@env_vars} />
          <% "system" -> %>
            <.system_tab system_info={@system_info} />
        <% end %>
      </div>
      
    <!-- Actions -->
      <div class="flex justify-end gap-3">
        <button
          phx-click="restart_app"
          data-confirm="Are you sure you want to restart the application?"
          class="btn-secondary text-yellow-400"
        >
          <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
            />
          </svg>
          Restart Application
        </button>
      </div>
    </div>
    """
  end

  defp tab_button(assigns) do
    active = assigns.active == assigns.tab

    classes =
      if active do
        "border-b-2 border-blue-500 text-blue-400"
      else
        "text-gray-400 hover:text-white"
      end

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <button
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={"pb-3 px-1 text-sm font-medium #{@classes}"}
    >
      {@label}
    </button>
    """
  end

  defp general_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <h3 class="text-lg font-medium text-white">General Configuration</h3>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <.config_item label="Application Name" value={@config.app_name} />
        <.config_item label="Environment" value={@config.environment} />
        <.config_item label="HTTP Port" value={@config.port} />
        <.config_item label="Host" value={@config.host} />
        <.config_item
          label="Secret Key"
          value={if @config.secret_key_configured, do: "✓ Configured", else: "✗ Not configured"}
        />
        <.config_item label="Database" value={mask_url(@config.database_url)} />
      </div>
    </div>
    """
  end

  defp ai_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <h3 class="text-lg font-medium text-white">AI Providers</h3>
      <p class="text-sm text-gray-400">Configure API keys in the Environment tab or .env file</p>

      <div class="space-y-4">
        <%= for {_id, name, configured} <- @config.ai_providers do %>
          <div class="flex items-center justify-between p-4 bg-gray-700/50 rounded-lg">
            <div class="flex items-center gap-3">
              <div class={"w-3 h-3 rounded-full #{if configured, do: "bg-green-500", else: "bg-gray-500"}"}>
              </div>
              <span class="text-white">{name}</span>
            </div>
            <span class={"text-sm #{if configured, do: "text-green-400", else: "text-gray-500"}"}>
              {if configured, do: "Configured", else: "Not configured"}
            </span>
          </div>
        <% end %>
      </div>

      <div class="mt-6 p-4 bg-gray-700/30 rounded-lg">
        <h4 class="text-sm font-medium text-gray-300 mb-2">Required Environment Variables</h4>
        <ul class="text-sm text-gray-400 space-y-1">
          <li><code class="text-blue-400">ANTHROPIC_API_KEY</code> - For Claude models</li>
          <li><code class="text-blue-400">OPENAI_API_KEY</code> - For GPT models</li>
          <li><code class="text-blue-400">GOOGLE_API_KEY</code> - For Gemini models</li>
        </ul>
      </div>
    </div>
    """
  end

  defp env_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <h3 class="text-lg font-medium text-white">Environment Variables</h3>
      <p class="text-sm text-gray-400">Edit .env file (requires restart to take effect)</p>

      <form phx-submit="save_env" class="space-y-4">
        <%= for {key, value} <- @env_vars do %>
          <div class="flex items-center gap-4">
            <input
              type="text"
              name={"env[#{key}]"}
              value={mask_sensitive(key, value)}
              disabled={String.contains?(key, "KEY") || String.contains?(key, "SECRET")}
              class="flex-1 bg-gray-700 border-gray-600 text-white rounded px-3 py-2 font-mono text-sm disabled:opacity-50"
            />
            <span class="text-gray-400 text-sm w-40 truncate" title={key}>{key}</span>
          </div>
        <% end %>

        <%= if map_size(@env_vars) == 0 do %>
          <p class="text-gray-500 text-center py-4">No .env file found or it's empty</p>
        <% end %>

        <div class="pt-4">
          <button type="submit" class="btn-primary" disabled={map_size(@env_vars) == 0}>
            Save Changes
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp system_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <h3 class="text-lg font-medium text-white">System Information</h3>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <.config_item label="Elixir Version" value={@system_info.elixir_version} />
        <.config_item label="OTP Version" value={@system_info.otp_version} />
        <.config_item label="Total Memory" value={@system_info.memory_total} />
        <.config_item label="Process Memory" value={@system_info.memory_processes} />
        <.config_item label="Process Count" value={@system_info.process_count} />
        <.config_item label="Uptime" value={@system_info.uptime} />
        <.config_item label="Node" value={@system_info.node} />
      </div>
    </div>
    """
  end

  defp config_item(assigns) do
    ~H"""
    <div>
      <dt class="text-sm text-gray-400">{@label}</dt>
      <dd class="mt-1 text-white">{@value}</dd>
    </div>
    """
  end

  defp mask_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.userinfo do
      masked = String.replace(uri.userinfo, ~r/:.*/, ":****")
      %{uri | userinfo: masked} |> URI.to_string()
    else
      url
    end
  end

  defp mask_url(url), do: url

  defp mask_sensitive(key, value) do
    if String.contains?(key, "KEY") || String.contains?(key, "SECRET") ||
         String.contains?(key, "PASSWORD") do
      String.slice(value, 0, 4) <> "****" <> String.slice(value, -4, 4)
    else
      value
    end
  end
end
