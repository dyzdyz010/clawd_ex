defmodule ClawdEx.Tools.SessionsSpawn do
  @moduledoc """
  子代理生成工具 - 启动隔离的子代理会话执行任务

  功能:
  - 创建新的隔离会话
  - 在新会话中启动 Agent Loop
  - 非阻塞执行，立即返回 childSessionKey
  - 任务完成后通过 PubSub 通知父会话并回报渠道
  - 支持 cleanup: "delete" | "keep" 控制会话清理
  - 支持 thinking 参数控制思考级别

  session_key 格式: agent:{agent_id}:subagent:{uuid}
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.Sessions.SessionManager
  alias ClawdEx.Sessions.SessionWorker

  # 默认超时 10 分钟
  @default_timeout_seconds 600

  @impl true
  def name, do: "sessions_spawn"

  @impl true
  def description do
    """
    Spawn a background sub-agent run in an isolated session and announce the result back to the requester chat.
    Non-blocking - returns immediately with childSessionKey.
    Use sessions_history to check progress or wait for the announcement.
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        task: %{
          type: "string",
          description: "Task description for the child agent to execute (required)"
        },
        label: %{
          type: "string",
          description: "Human-readable label for this subagent (optional)"
        },
        agentId: %{
          type: "string",
          description: "Agent ID to use (defaults to parent's agent)"
        },
        model: %{
          type: "string",
          description: "Model override for this subagent (defaults to agent's default)"
        },
        thinking: %{
          type: "string",
          description: "Thinking level override (e.g., 'low', 'medium', 'high')"
        },
        runTimeoutSeconds: %{
          type: "integer",
          description: "Timeout in seconds (default: 600, max: 3600)"
        },
        timeoutSeconds: %{
          type: "integer",
          description: "Legacy alias for runTimeoutSeconds"
        },
        cleanup: %{
          type: "string",
          enum: ["delete", "keep"],
          description: "Session cleanup after completion: 'delete' removes session, 'keep' preserves it (default: keep)"
        }
      },
      required: ["task"]
    }
  end

  @impl true
  def execute(params, context) do
    # 检查是否从子代理会话调用（禁止）
    session_key = context[:session_key] || ""

    if is_subagent_session?(session_key) do
      {:error, "sessions_spawn is not allowed from sub-agent sessions"}
    else
      task = params["task"] || params[:task]

      if is_nil(task) || task == "" do
        {:error, "task is required"}
      else
        spawn_subagent(params, context)
      end
    end
  end

  # 检查是否是子代理会话
  defp is_subagent_session?(session_key) when is_binary(session_key) do
    String.contains?(session_key, ":subagent:")
  end

  defp is_subagent_session?(_), do: false

  defp spawn_subagent(params, context) do
    task = params["task"] || params[:task]
    label = get_string_param(params, "label")
    agent_id = get_string_param(params, "agentId") || context[:agent_id]
    model = get_string_param(params, "model")
    thinking = get_string_param(params, "thinking")
    timeout_seconds = get_timeout(params)
    cleanup = normalize_cleanup(params["cleanup"] || params[:cleanup])

    # 获取渠道信息用于结果回报
    channel = context[:channel]
    channel_to = context[:channel_to] || context[:to]

    # 生成子会话 key
    subagent_id = generate_subagent_id()
    child_session_key = build_session_key(agent_id, subagent_id)

    # 父会话信息
    parent_session_key = context[:session_key]
    parent_session_id = context[:session_id]

    Logger.info("Spawning subagent #{label || subagent_id} for task: #{truncate(task, 100)}")

    # 构建子代理的配置
    child_config = build_child_config(context, model, thinking, parent_session_key)

    # 启动子会话
    case start_child_session(child_session_key, agent_id, child_config) do
      {:ok, _pid} ->
        # 异步执行任务
        spawn_task_runner(%{
          child_session_key: child_session_key,
          task: task,
          model: model,
          thinking: thinking,
          timeout_seconds: timeout_seconds,
          cleanup: cleanup,
          parent_session_key: parent_session_key,
          parent_session_id: parent_session_id,
          label: label,
          channel: channel,
          channel_to: channel_to
        })

        {:ok, format_spawn_response(child_session_key, subagent_id, label)}

      {:error, reason} ->
        Logger.error("Failed to spawn subagent: #{inspect(reason)}")
        {:error, "Failed to spawn subagent: #{inspect(reason)}"}
    end
  end

  # 规范化 cleanup 参数
  defp normalize_cleanup("delete"), do: :delete
  defp normalize_cleanup("keep"), do: :keep
  defp normalize_cleanup(true), do: :delete  # 兼容旧的 boolean 参数
  defp normalize_cleanup(_), do: :keep

  # 获取字符串参数，处理 atom 和 string key
  defp get_string_param(params, key) do
    value = params[key] || params[String.to_atom(key)]
    if is_binary(value) && String.trim(value) != "", do: String.trim(value), else: nil
  end

  defp start_child_session(session_key, agent_id, config) do
    SessionManager.start_session(
      session_key: session_key,
      agent_id: agent_id,
      channel: "subagent",
      config: config
    )
  end

  defp spawn_task_runner(opts) do
    %{
      child_session_key: child_session_key,
      task: task,
      model: model,
      thinking: thinking,
      timeout_seconds: timeout_seconds,
      cleanup: cleanup,
      parent_session_key: parent_session_key,
      parent_session_id: parent_session_id,
      label: label,
      channel: channel,
      channel_to: channel_to
    } = opts

    spawn(fn ->
      started_at = DateTime.utc_now()

      result =
        try do
          run_opts = build_run_opts(model, thinking, timeout_seconds)
          SessionWorker.send_message(child_session_key, task, run_opts)
        rescue
          e ->
            Logger.error("Subagent execution error: #{Exception.message(e)}")
            {:error, {:exception, Exception.message(e)}}
        catch
          :exit, reason ->
            Logger.error("Subagent exit: #{inspect(reason)}")
            {:error, {:exit, reason}}
        end

      duration_ms = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)

      # 通知父会话 (PubSub)
      announce_completion(
        parent_session_key,
        parent_session_id,
        child_session_key,
        result,
        duration_ms,
        label
      )

      # 向原渠道发送结果通知
      announce_to_channel(channel, channel_to, label, result, duration_ms)

      # 根据 cleanup 参数决定是否清理
      if cleanup == :delete do
        Logger.info("Cleaning up subagent session: #{child_session_key}")
        # 先停止进程
        SessionManager.stop_session(child_session_key)
        # 再删除数据库记录
        delete_session_from_db(child_session_key)
      end
    end)
  end

  # 从数据库中删除会话记录
  defp delete_session_from_db(session_key) do
    import Ecto.Query

    case ClawdEx.Repo.get_by(ClawdEx.Sessions.Session, session_key: session_key) do
      nil ->
        Logger.debug("Session #{session_key} not found in DB for cleanup")
        :ok

      session ->
        # 先删除关联的消息
        ClawdEx.Repo.delete_all(
          from(m in ClawdEx.Sessions.Message, where: m.session_id == ^session.id)
        )

        # 再删除会话
        case ClawdEx.Repo.delete(session) do
          {:ok, _} ->
            Logger.info("Session #{session_key} deleted from DB")
            :ok

          {:error, reason} ->
            Logger.error("Failed to delete session #{session_key}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # 向原渠道发送结果通知
  defp announce_to_channel(nil, _to, _label, _result, _duration_ms), do: :ok
  defp announce_to_channel(_channel, nil, _label, _result, _duration_ms), do: :ok

  defp announce_to_channel(channel, to, label, result, duration_ms) do
    status_emoji = if match?({:ok, _}, result), do: "✅", else: "❌"
    task_name = label || "子代理任务"
    duration_str = format_duration(duration_ms)

    message =
      case result do
        {:ok, content} when is_binary(content) ->
          summary = truncate(content, 500)
          "#{status_emoji} **#{task_name}** 完成 (#{duration_str})\n\n#{summary}"

        {:ok, _} ->
          "#{status_emoji} **#{task_name}** 完成 (#{duration_str})"

        {:error, reason} ->
          "#{status_emoji} **#{task_name}** 失败 (#{duration_str})\n\n错误: #{inspect(reason)}"
      end

    # 通过渠道发送消息
    case channel do
      "telegram" ->
        ClawdEx.Channels.Telegram.send_message(to, message)

      "discord" ->
        ClawdEx.Channels.Discord.send_message(to, message)

      _ ->
        Logger.debug("Unknown channel for announcement: #{channel}")
        :ok
    end
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp announce_completion(
         parent_session_key,
         parent_session_id,
         child_session_key,
         result,
         duration_ms,
         label
       ) do
    status =
      case result do
        {:ok, _} -> :completed
        {:error, _} -> :failed
      end

    completion_data = %{
      childSessionKey: child_session_key,
      label: label,
      status: status,
      durationMs: duration_ms,
      result: format_result(result)
    }

    Logger.info("Subagent #{label || child_session_key} #{status} in #{duration_ms}ms")

    # 通过 PubSub 广播到父会话
    if parent_session_key do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "session:#{parent_session_key}",
        {:subagent_completed, completion_data}
      )
    end

    # 也广播到 agent 级别的 topic
    if parent_session_id do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "agent:#{parent_session_id}",
        {:subagent_completed, completion_data}
      )
    end
  end

  defp build_child_config(parent_context, model_override, thinking_override, parent_session_key) do
    parent_config = parent_context[:config] || %{}

    config = %{
      # 继承父配置
      workspace: parent_config[:workspace],
      tools_allow: parent_config[:tools_allow] || ["*"],
      tools_deny: parent_config[:tools_deny] || [],
      # 子代理特有
      parent_session_key: parent_session_key,
      is_subagent: true
    }

    config =
      if model_override do
        Map.put(config, :default_model, model_override)
      else
        Map.put(config, :default_model, parent_config[:default_model])
      end

    if thinking_override do
      Map.put(config, :thinking, thinking_override)
    else
      config
    end
  end

  defp build_run_opts(model, thinking, timeout_seconds) do
    opts = [timeout: timeout_seconds * 1000]

    opts =
      if model do
        Keyword.put(opts, :model, model)
      else
        opts
      end

    if thinking do
      Keyword.put(opts, :thinking, thinking)
    else
      opts
    end
  end

  defp format_spawn_response(child_session_key, subagent_id, label) do
    response = %{
      status: "spawned",
      childSessionKey: child_session_key,
      subagentId: subagent_id,
      message: "Subagent started. Use sessions_history to check progress."
    }

    if label do
      Map.put(response, :label, label)
    else
      response
    end
  end

  defp format_result({:ok, content}) when is_binary(content) do
    # 截断过长的结果
    truncate(content, 2000)
  end

  defp format_result({:ok, content}) do
    inspect(content, limit: 50)
  end

  defp format_result({:error, reason}) do
    "Error: #{inspect(reason)}"
  end

  defp get_timeout(params) do
    timeout =
      params["runTimeoutSeconds"] || params[:runTimeoutSeconds] || @default_timeout_seconds

    min(timeout, 3600)
  end

  defp generate_subagent_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 22)
  end

  defp build_session_key(nil, subagent_id) do
    "agent:default:subagent:#{subagent_id}"
  end

  defp build_session_key(agent_id, subagent_id) do
    "agent:#{agent_id}:subagent:#{subagent_id}"
  end

  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length - 3) <> "..."
    else
      str
    end
  end

  defp truncate(other, _), do: inspect(other)
end
