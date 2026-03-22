defmodule ClawdExWeb.PluginsLive do
  @moduledoc """
  Plugins 管理页面 — 展示插件和 MCP servers
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.Plugins.Manager, as: PluginManager
  alias ClawdEx.MCP.ServerManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(10_000, self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Plugins")
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("toggle_plugin", %{"id" => id}, socket) do
    plugin = Enum.find(socket.assigns.plugins, &(&1.id == id))

    if plugin do
      if plugin.enabled do
        PluginManager.disable_plugin(id)
      else
        PluginManager.enable_plugin(id)
      end
    end

    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    plugins = PluginManager.list_plugins()

    mcp_servers =
      try do
        ServerManager.list_servers()
      catch
        :exit, _ -> []
      end

    assign(socket,
      plugins: plugins,
      mcp_servers: mcp_servers,
      plugin_stats: compute_plugin_stats(plugins),
      mcp_stats: compute_mcp_stats(mcp_servers)
    )
  end

  defp compute_plugin_stats(plugins) do
    %{
      total: length(plugins),
      loaded: Enum.count(plugins, &(&1.status == :loaded)),
      disabled: Enum.count(plugins, &(&1.status == :disabled)),
      error: Enum.count(plugins, &(&1.status == :error)),
      beam: Enum.count(plugins, &(&1.plugin_type == :beam)),
      node: Enum.count(plugins, &(&1.plugin_type == :node))
    }
  end

  defp compute_mcp_stats(servers) do
    %{
      total: length(servers),
      ready: Enum.count(servers, fn {_name, info} -> info.status == :ready end)
    }
  end
end
