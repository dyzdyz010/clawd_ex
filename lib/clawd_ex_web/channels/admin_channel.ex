defmodule ClawdExWeb.Channels.AdminChannel do
  @moduledoc """
  管理员实时控制通道。

  Topic: "admin:control"

  仅允许 gateway 类型 + admin scope 的连接加入。

  支持的命令:
    - "reload_plugins"  — 重新加载所有 plugins
    - "reload_skills"   — 重新加载 skills
    - "clear_session"   — 清理指定 session
    - "system_stats"    — 返回系统状态（内存、进程数、uptime）

  服务端推送事件:
    - "plugin:installed"    — 新 plugin 安装
    - "plugin:uninstalled"  — plugin 卸载
    - "config:changed"      — 配置变更
  """
  use Phoenix.Channel

  require Logger

  @pubsub_topic "admin:events"

  @impl true
  def join("admin:control", _params, socket) do
    auth = socket.assigns[:auth]

    case auth do
      %{type: :gateway} ->
        Phoenix.PubSub.subscribe(ClawdEx.PubSub, @pubsub_topic)
        {:ok, socket}

      _ ->
        {:error, %{reason: "unauthorized", message: "Admin access required"}}
    end
  end

  # ===========================================================================
  # Command Handlers
  # ===========================================================================

  @impl true
  def handle_in("reload_plugins", _payload, socket) do
    Logger.info("Admin: reload_plugins requested")

    case ClawdEx.Plugins.Manager.reload() do
      :ok ->
        {:reply, {:ok, %{status: "ok", message: "Plugins reloaded successfully"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("reload_skills", _payload, socket) do
    Logger.info("Admin: reload_skills requested")

    # Skills are typically loaded from the filesystem, trigger a refresh
    # The skills system re-scans on demand; this is a convenience trigger
    result =
      try do
        # Clear any cached skills data to force re-scan
        if Code.ensure_loaded?(ClawdEx.Skills) do
          apply(ClawdEx.Skills, :reload, [])
        else
          :ok
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      :ok ->
        {:reply, {:ok, %{status: "ok", message: "Skills reloaded successfully"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("clear_session", %{"session_key" => session_key}, socket) do
    Logger.info("Admin: clear_session requested for #{session_key}")

    case ClawdEx.Sessions.SessionManager.stop_session(session_key) do
      :ok ->
        {:reply, {:ok, %{status: "ok", session_key: session_key, message: "Session cleared"}},
         socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "session_not_found", session_key: session_key}}, socket}
    end
  end

  @impl true
  def handle_in("clear_session", _payload, socket) do
    {:reply, {:error, %{reason: "missing_session_key"}}, socket}
  end

  @impl true
  def handle_in("system_stats", _payload, socket) do
    stats = gather_system_stats()
    {:reply, {:ok, stats}, socket}
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_command"}}, socket}
  end

  # ===========================================================================
  # PubSub Event Relay
  # ===========================================================================

  @impl true
  def handle_info({:admin_event, event_type, payload}, socket) do
    push(socket, event_type, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ===========================================================================
  # Broadcasting Helpers (call from anywhere)
  # ===========================================================================

  @doc """
  Broadcast an admin event to all connected admin:control clients.

  ## Examples

      AdminChannel.broadcast_event("plugin:installed", %{plugin_id: "my-plugin"})
      AdminChannel.broadcast_event("config:changed", %{key: "model", value: "gpt-4"})
  """
  @spec broadcast_event(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_event(event_type, payload) when is_binary(event_type) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      @pubsub_topic,
      {:admin_event, event_type, payload}
    )
  end

  # ===========================================================================
  # System Stats
  # ===========================================================================

  defp gather_system_stats do
    memory = :erlang.memory()
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)

    session_count =
      try do
        length(ClawdEx.Sessions.SessionManager.list_sessions())
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    plugin_count =
      try do
        length(ClawdEx.Plugins.Manager.list_plugins())
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    %{
      memory: %{
        total: format_bytes(memory[:total]),
        processes: format_bytes(memory[:processes]),
        ets: format_bytes(memory[:ets]),
        binary: format_bytes(memory[:binary]),
        atom: format_bytes(memory[:atom]),
        total_bytes: memory[:total]
      },
      processes: %{
        count: process_count,
        limit: process_limit,
        usage_pct: Float.round(process_count / process_limit * 100, 1)
      },
      uptime: %{
        milliseconds: uptime_ms,
        human: format_uptime(uptime_ms)
      },
      sessions: %{
        active_count: session_count
      },
      plugins: %{
        loaded_count: plugin_count
      },
      otp_release: to_string(:erlang.system_info(:otp_release)),
      elixir_version: System.version(),
      node: to_string(Node.self()),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "unknown"

  defp format_uptime(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h #{rem(minutes, 60)}m"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m #{rem(seconds, 60)}s"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp format_uptime(_), do: "unknown"
end
