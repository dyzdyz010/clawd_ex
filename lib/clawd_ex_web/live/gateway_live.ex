defmodule ClawdExWeb.GatewayLive do
  @moduledoc """
  Gateway 状态面板 - 显示 Phoenix endpoint 状态、连接数、内存等系统信息
  """
  use ClawdExWeb, :live_view

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :tick)
    end

    socket =
      socket
      |> assign(:page_title, "Gateway")
      |> load_gateway_status()

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, load_gateway_status(socket)}
  end

  @impl true
  def handle_event("restart", _params, socket) do
    case ClawdEx.Tools.Gateway.execute(%{"action" => "restart"}, %{}) do
      {:ok, %{message: message}} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(:restarting, true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restart failed: #{inspect(reason)}")}
    end
  end

  defp load_gateway_status(socket) do
    endpoint_status = get_endpoint_status()
    memory = get_memory_info()
    connections = get_connection_info()
    config = get_endpoint_config()
    uptime = get_uptime()

    assign(socket,
      endpoint_status: endpoint_status,
      memory: memory,
      connections: connections,
      config: config,
      uptime: uptime,
      restarting: false
    )
  end

  defp get_endpoint_status do
    case Process.whereis(ClawdExWeb.Endpoint) do
      nil -> :stopped
      pid when is_pid(pid) -> :running
    end
  end

  defp get_endpoint_config do
    config = Application.get_env(:clawd_ex, ClawdExWeb.Endpoint, [])
    http_config = Keyword.get(config, :http, [])

    %{
      port: Keyword.get(http_config, :port, 4000),
      host: Keyword.get(config, :url, []) |> Keyword.get(:host, "localhost")
    }
  end

  defp get_memory_info do
    mem = :erlang.memory()

    %{
      total: format_bytes(mem[:total]),
      processes: format_bytes(mem[:processes]),
      ets: format_bytes(mem[:ets]),
      atom: format_bytes(mem[:atom]),
      binary: format_bytes(mem[:binary]),
      total_raw: mem[:total]
    }
  end

  defp get_connection_info do
    # Count LiveView (WebSocket) connections from the PubSub
    ws_count =
      try do
        # Count connected LiveView sockets
        Registry.count(Phoenix.LiveView.Registry)
      rescue
        _ -> 0
      catch
        _, _ -> 0
      end

    %{
      websocket: ws_count,
      http: get_http_connections()
    }
  end

  defp get_http_connections do
    # Try to get active connections from ranch listeners
    try do
      :ranch.info()
      |> Enum.reduce(0, fn {_ref, info}, acc ->
        acc + Keyword.get(info, :active_connections, 0)
      end)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    seconds = div(uptime_ms, 1000)
    days = div(seconds, 86400)
    hours = div(rem(seconds, 86400), 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      days > 0 -> "#{days}d #{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "N/A"

  defp status_color(:running), do: "text-green-400"
  defp status_color(:stopped), do: "text-red-400"
  defp status_color(_), do: "text-gray-400"

  defp status_bg(:running), do: "bg-green-500/10 border-green-500/20"
  defp status_bg(:stopped), do: "bg-red-500/10 border-red-500/20"
  defp status_bg(_), do: "bg-gray-500/10 border-gray-500/20"

  defp status_dot(:running), do: "bg-green-400"
  defp status_dot(:stopped), do: "bg-red-400"
  defp status_dot(_), do: "bg-gray-400"
end
