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
  - 支持 Telegram Forum/Topic announce
  - 超时通知父会话和渠道
  - 支持 streamTo: "parent" 实时流式推送输出

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
        },
        streamTo: %{
          type: "string",
          enum: ["parent"],
          description: "Stream child output to parent session in real-time (optional)"
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
    stream_to = get_string_param(params, "streamTo")

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
        # 将 label 和 cleanup 存入 session metadata
        store_session_metadata(child_session_key, %{
          label: label,
          cleanup: to_string(cleanup),
          parent_session_key: parent_session_key
        })

        # 如果 streamTo == "parent"，设置流式转发
        if stream_to == "parent" && parent_session_key do
          setup_stream_to_parent(child_session_key, parent_session_key, parent_session_id, label)
        end

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

    Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
      started_at = DateTime.utc_now()

      result =
        try do
          # Use Task.async + Task.yield to enforce timeout even if
          # SessionWorker.send_message itself hangs (e.g. AI provider unresponsive)
          inner_task =
            Task.async(fn ->
              run_opts = build_run_opts(model, thinking, timeout_seconds)
              SessionWorker.send_message(child_session_key, task, run_opts)
            end)

          case Task.yield(inner_task, timeout_seconds * 1000) do
            {:ok, result} ->
              result

            nil ->
              Logger.error("Subagent #{label || child_session_key} timed out after #{timeout_seconds}s")
              Task.shutdown(inner_task, :brutal_kill)
              {:error, :timeout}
          end
        rescue
          e ->
            Logger.error("Subagent task failed: #{inspect(e)}")
            {:error, {:exception, Exception.message(e)}}
        catch
          :exit, reason ->
            Logger.error("Subagent exit: #{inspect(reason)}")
            {:error, {:exit, reason}}
        end

      duration_ms = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)

      # 超时专门处理：通知父会话 + announce 到渠道
      if result == {:error, :timeout} do
        handle_timeout_notification(
          parent_session_key,
          parent_session_id,
          child_session_key,
          label,
          timeout_seconds,
          channel,
          channel_to,
          cleanup
        )
      else
        # 通知父会话 (PubSub)
        announce_completion(
          parent_session_key,
          parent_session_id,
          child_session_key,
          result,
          duration_ms,
          label
        )

        # 向原渠道发送结果通知（带 topic 支持）
        announce_to_channel(channel, channel_to, parent_session_key, label, result, duration_ms)

        # 根据 cleanup 参数决定是否清理
        if cleanup == :delete do
          cleanup_session(child_session_key)
        end
      end
    end)
  end

  # 将 label/cleanup 等元信息存入 session 的 metadata 字段
  defp store_session_metadata(session_key, meta) do
    import Ecto.Query

    # 过滤掉 nil 值
    meta = meta |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case ClawdEx.Repo.get_by(ClawdEx.Sessions.Session, session_key: session_key) do
      nil ->
        Logger.debug("Session #{session_key} not found for metadata update")
        :ok

      session ->
        merged = Map.merge(session.metadata || %{}, meta)

        session
        |> ClawdEx.Sessions.Session.changeset(%{metadata: merged})
        |> ClawdEx.Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to store metadata for #{session_key}: #{inspect(reason)}")
            :ok
        end
    end
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

  # 向原渠道发送结果通知（带 Telegram topic 支持）
  defp announce_to_channel(nil, _to, _parent_key, _label, _result, _duration_ms), do: :ok
  defp announce_to_channel(_channel, nil, _parent_key, _label, _result, _duration_ms), do: :ok

  defp announce_to_channel(channel, to, parent_session_key, label, result, duration_ms) do
    status_emoji = if match?({:ok, _}, result), do: "✅", else: "❌"
    task_name = label || "子代理任务"
    duration_str = format_duration(duration_ms)

    message =
      case result do
        {:ok, content} when is_binary(content) ->
          summary = truncate(content, 2000)
          "#{status_emoji} 子代理 [#{task_name}] 完成 (#{duration_str})\n---\n#{summary}"

        {:ok, _} ->
          "#{status_emoji} 子代理 [#{task_name}] 完成 (#{duration_str})"

        {:error, reason} ->
          "#{status_emoji} 子代理 [#{task_name}] 失败 (#{duration_str})\n---\n错误: #{inspect(reason)}"
      end

    # 通过渠道发送消息
    send_result =
      case channel do
        "telegram" ->
          # 解析 topic_id 从父会话 session_key
          topic_id = extract_topic_id(parent_session_key)
          opts = if topic_id, do: [message_thread_id: topic_id], else: []
          ClawdEx.Channels.Telegram.send_message(to, message, opts)

        "discord" ->
          ClawdEx.Channels.Discord.send_message(to, message)

        _ ->
          Logger.debug("Unknown channel for announcement: #{channel}")
          :ok
      end

    # announce 失败时通过 PubSub fallback 通知父会话
    case send_result do
      {:error, reason} ->
        Logger.warning("Channel announce failed (#{channel}): #{inspect(reason)}, falling back to PubSub")
        if parent_session_key do
          Phoenix.PubSub.broadcast(
            ClawdEx.PubSub,
            "session:#{parent_session_key}",
            {:subagent_announce_fallback, %{
              label: label,
              message: message,
              channel_error: inspect(reason)
            }}
          )
        end

      _ ->
        :ok
    end
  end

  # 从 session_key 中提取 Telegram topic ID
  # 格式: agent:ceo:telegram:group:-xxx:topic:21
  defp extract_topic_id(nil), do: nil

  defp extract_topic_id(session_key) when is_binary(session_key) do
    case Regex.run(~r/:topic:(\d+)/, session_key) do
      [_, topic_id] -> topic_id
      _ -> nil
    end
  end

  defp extract_topic_id(_), do: nil

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

  # 超时处理：通知父会话 + announce 到渠道 + cleanup
  defp handle_timeout_notification(
         parent_session_key,
         parent_session_id,
         child_session_key,
         label,
         timeout_seconds,
         channel,
         channel_to,
         cleanup
       ) do
    task_name = label || "子代理任务"
    timeout_message = "⚠️ 子代理 [#{task_name}] 超时 (#{timeout_seconds}s)"

    # 1. 通过 PubSub 通知父会话
    if parent_session_key do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "session:#{parent_session_key}",
        {:subagent_timeout, %{
          childSessionKey: child_session_key,
          label: label,
          timeoutSeconds: timeout_seconds,
          message: timeout_message
        }}
      )
    end

    if parent_session_id do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "agent:#{parent_session_id}",
        {:subagent_timeout, %{
          childSessionKey: child_session_key,
          label: label,
          timeoutSeconds: timeout_seconds,
          message: timeout_message
        }}
      )
    end

    # 2. announce 超时到渠道
    if channel && channel_to do
      announce_to_channel(
        channel,
        channel_to,
        parent_session_key,
        label,
        {:error, :timeout},
        timeout_seconds * 1000
      )
    end

    # 3. cleanup 超时的子代理 session
    if cleanup == :delete do
      cleanup_session(child_session_key)
    end
  end

  # 统一的会话清理函数
  defp cleanup_session(child_session_key) do
    Logger.info("Cleaning up subagent session: #{child_session_key}")
    # 先停止进程
    SessionManager.stop_session(child_session_key)
    # 再删除数据库记录
    delete_session_from_db(child_session_key)
  end

  # 设置 streamTo: "parent" 的流式转发
  # 监听子会话的 output 事件并转发给父会话
  defp setup_stream_to_parent(child_session_key, parent_session_key, parent_session_id, label) do
    # 获取子会话的 session_id 用于订阅 PubSub
    child_session_id = get_session_id_by_key(child_session_key)

    if child_session_id do
      Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
        # 订阅子代理的输出事件
        Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{child_session_id}")
        Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{child_session_id}")

        # 转发循环
        stream_forward_loop(parent_session_key, parent_session_id, label)
      end)
    else
      Logger.warning("Cannot setup streamTo: child session_id not found for #{child_session_key}")
    end
  end

  # 流式转发循环：监听子代理输出并推送给父会话
  defp stream_forward_loop(parent_session_key, parent_session_id, label) do
    receive do
      # OutputManager 输出段
      {:output_segment, _run_id, content, metadata} when content != "" ->
        forward_to_parent(parent_session_key, parent_session_id, label, content, metadata)
        stream_forward_loop(parent_session_key, parent_session_id, label)

      # Agent 段输出（兼容）
      {:agent_segment, _run_id, content, _opts} when is_binary(content) and content != "" ->
        forward_to_parent(parent_session_key, parent_session_id, label, content, %{type: :segment})
        stream_forward_loop(parent_session_key, parent_session_id, label)

      # 运行完成 — 停止转发
      {:output_complete, _run_id, _content, _metadata} ->
        Logger.debug("Stream forward completed for subagent #{label || "unknown"}")
        :ok

      # 忽略其他事件但继续监听
      _ ->
        stream_forward_loop(parent_session_key, parent_session_id, label)
    after
      # 安全超时 15 分钟，防止僵尸进程
      900_000 ->
        Logger.warning("Stream forward loop timed out for subagent #{label || "unknown"}")
        :ok
    end
  end

  # 将子代理输出转发给父会话
  defp forward_to_parent(parent_session_key, parent_session_id, label, content, metadata) do
    prefix = if label, do: "[#{label}] ", else: ""

    stream_data = %{
      label: label,
      content: content,
      metadata: metadata
    }

    if parent_session_key do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "session:#{parent_session_key}",
        {:subagent_stream, stream_data}
      )
    end

    if parent_session_id do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "agent:#{parent_session_id}",
        {:subagent_stream, stream_data}
      )
    end

    Logger.debug("Forwarded stream from subagent #{prefix}: #{String.slice(content, 0, 50)}...")
  end

  # 通过 session_key 获取数据库中的 session_id
  defp get_session_id_by_key(session_key) do
    case ClawdEx.Repo.get_by(ClawdEx.Sessions.Session, session_key: session_key) do
      nil -> nil
      session -> session.id
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
