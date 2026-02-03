defmodule ClawdEx.Tools.SessionsSpawn do
  @moduledoc """
  子代理生成工具 - 启动隔离的子代理会话执行任务

  功能:
  - 创建新的隔离会话
  - 在新会话中启动 Agent Loop
  - 非阻塞执行，立即返回 childSessionKey
  - 任务完成后通过 PubSub 通知父会话

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
    Spawn a child agent to execute a task in an isolated session.
    Non-blocking - returns immediately with childSessionKey.
    Use sessions_history or sessions_poll to check status and get results.
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
          type: "integer",
          description: "Agent ID to use (defaults to parent's agent)"
        },
        model: %{
          type: "string",
          description: "Model override for this subagent (defaults to agent's default)"
        },
        runTimeoutSeconds: %{
          type: "integer",
          description: "Timeout in seconds (default: 600, max: 3600)"
        },
        cleanup: %{
          type: "boolean",
          description: "Clean up session after completion (default: false)"
        },
        contextInject: %{
          type: "string",
          description: "Additional context to inject into the subagent's system prompt"
        }
      },
      required: ["task"]
    }
  end

  @impl true
  def execute(params, context) do
    task = params["task"] || params[:task]

    if is_nil(task) || task == "" do
      {:error, "task is required"}
    else
      spawn_subagent(params, context)
    end
  end

  defp spawn_subagent(params, context) do
    task = params["task"] || params[:task]
    label = params["label"] || params[:label]
    agent_id = params["agentId"] || params[:agentId] || context[:agent_id]
    model = params["model"] || params[:model]
    timeout_seconds = get_timeout(params)
    cleanup = params["cleanup"] || params[:cleanup] || false
    context_inject = params["contextInject"] || params[:contextInject]

    # 生成子会话 key
    subagent_id = generate_subagent_id()
    child_session_key = build_session_key(agent_id, subagent_id)

    # 父会话信息
    parent_session_key = context[:session_key]
    parent_session_id = context[:session_id]

    Logger.info("Spawning subagent #{label || subagent_id} for task: #{truncate(task, 100)}")

    # 构建子代理的配置
    child_config = build_child_config(context, model, context_inject, parent_session_key)

    # 启动子会话
    case start_child_session(child_session_key, agent_id, child_config) do
      {:ok, _pid} ->
        # 异步执行任务
        spawn_task_runner(
          child_session_key,
          task,
          model,
          timeout_seconds,
          cleanup,
          parent_session_key,
          parent_session_id,
          label
        )

        {:ok, format_spawn_response(child_session_key, subagent_id, label)}

      {:error, reason} ->
        Logger.error("Failed to spawn subagent: #{inspect(reason)}")
        {:error, "Failed to spawn subagent: #{inspect(reason)}"}
    end
  end

  defp start_child_session(session_key, agent_id, config) do
    SessionManager.start_session(
      session_key: session_key,
      agent_id: agent_id,
      channel: "subagent",
      config: config
    )
  end

  defp spawn_task_runner(
         child_session_key,
         task,
         model,
         timeout_seconds,
         cleanup,
         parent_session_key,
         parent_session_id,
         label
       ) do
    spawn(fn ->
      started_at = DateTime.utc_now()

      result =
        try do
          opts = build_run_opts(model, timeout_seconds)
          SessionWorker.send_message(child_session_key, task, opts)
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

      # 通知父会话
      announce_completion(
        parent_session_key,
        parent_session_id,
        child_session_key,
        result,
        duration_ms,
        label
      )

      # 可选清理
      if cleanup do
        Logger.info("Cleaning up subagent session: #{child_session_key}")
        SessionManager.stop_session(child_session_key)
      end
    end)
  end

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

  defp build_child_config(parent_context, model_override, context_inject, parent_session_key) do
    parent_config = parent_context[:config] || %{}

    config = %{
      # 继承父配置
      workspace: parent_config[:workspace],
      tools_allow: parent_config[:tools_allow] || ["*"],
      tools_deny: parent_config[:tools_deny] || [],
      # 子代理特有
      parent_session_key: parent_session_key,
      is_subagent: true,
      subagent_context: context_inject
    }

    if model_override do
      Map.put(config, :default_model, model_override)
    else
      Map.put(config, :default_model, parent_config[:default_model])
    end
  end

  defp build_run_opts(model, timeout_seconds) do
    opts = [timeout: timeout_seconds * 1000]

    if model do
      Keyword.put(opts, :model, model)
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
