defmodule ClawdEx.Agent.Loop do
  @moduledoc """
  Agent Loop - 使用 GenStateMachine 实现的代理执行循环

  状态流转:
    :idle -> :preparing -> :inferring -> :executing_tools -> :streaming -> :idle

  Events:
    - {:run, params} - 启动新的代理运行
    - {:ai_chunk, chunk} - AI 流式响应块
    - {:ai_done, response} - AI 响应完成
    - {:ai_error, error} - AI 错误
    - {:tool_result, tool_call_id, result} - 工具执行结果
    - :stop - 停止当前运行
  """
  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  alias ClawdEx.Agent.{OutputManager, Prompt}
  alias ClawdEx.Agent.Loop.{Broadcaster, Persistence, ToolExecutor}
  alias ClawdEx.AI.Models
  alias ClawdEx.AI.Stream, as: AIStream
  alias ClawdEx.A2A.Mailbox, as: A2AMailbox

  @doc "Get the maximum tool iterations limit (configurable via :clawd_ex, :max_tool_iterations)"
  def max_tool_iterations do
    Application.get_env(:clawd_ex, :max_tool_iterations, 25)
  end

  # State data structure
  defstruct [
    :run_id,
    :session_id,
    :agent_id,
    :model,
    :messages,
    :system_prompt,
    :tools,
    :pending_tool_calls,
    :stream_buffer,
    :reply_to,
    :started_at,
    :timeout_ref,
    :config,
    :output_manager_pid,
    :a2a_message_id,
    :task_ref,
    :inbound_metadata,
    :retry_timer_ref,
    tool_iterations: 0,
    retry_count: 0,
    max_retries: 3
  ]

  @type state :: :idle | :preparing | :inferring | :executing_tools | :streaming
  @type data :: %__MODULE__{}

  # 10 minutes
  @default_timeout_ms 600_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  启动 Agent Loop 进程
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenStateMachine.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc """
  运行代理 - 发送消息并获取响应
  """
  @spec run(pid() | term(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(server, content, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    GenStateMachine.call(server, {:run, content, opts}, timeout)
  end

  @doc """
  停止当前运行
  """
  def stop_run(server) do
    GenStateMachine.cast(server, :stop)
  end

  @doc """
  获取当前状态
  """
  def get_state(server) do
    GenStateMachine.call(server, :get_state)
  end

  # ============================================================================
  # GenStateMachine Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_id = Keyword.get(opts, :agent_id)
    config = Keyword.get(opts, :config, %{})

    data = %__MODULE__{
      session_id: session_id,
      agent_id: agent_id,
      messages: [],
      tools: [],
      pending_tool_calls: [],
      stream_buffer: "",
      config: config
    }

    Logger.info("Agent loop started for session #{session_id}")
    {:ok, :idle, data}
  end

  # ============================================================================
  # State: IDLE
  # ============================================================================

  def idle(:enter, _old_state, data) do
    # 取消超时定时器（如果存在）
    if data.timeout_ref, do: Process.cancel_timer(data.timeout_ref)

    # Cancel retry timer if pending
    if data.retry_timer_ref, do: Process.cancel_timer(data.retry_timer_ref)

    # 清理状态，重置 tool_iterations（每次 run 重新计数）
    new_data = %{
      data
      | run_id: nil,
        pending_tool_calls: [],
        stream_buffer: "",
        reply_to: nil,
        started_at: nil,
        timeout_ref: nil,
        tool_iterations: 0,
        output_manager_pid: nil,
        a2a_message_id: nil,
        task_ref: nil,
        retry_count: 0,
        retry_timer_ref: nil
    }

    # Check A2A mailbox for pending messages
    if data.agent_id do
      check_a2a_mailbox(data.agent_id)
    end

    {:keep_state, new_data}
  end

  def idle({:call, from}, {:run, content, opts}, data) do
    run_id = generate_run_id()
    timeout_ms = Keyword.get(opts, :timeout, @default_timeout_ms)

    Logger.info("Starting agent run #{run_id} with #{timeout_ms}ms timeout")

    # 设置超时定时器
    timeout_ref = Process.send_after(self(), {:run_timeout, run_id}, timeout_ms)

    new_data = %{
      data
      | run_id: run_id,
        reply_to: from,
        started_at: DateTime.utc_now(),
        timeout_ref: timeout_ref,
        model: Keyword.get(opts, :model, data.config[:default_model]) |> Models.resolve(),
        inbound_metadata: Keyword.get(opts, :inbound_metadata)
    }

    {:next_state, :preparing, new_data, [{:next_event, :internal, {:prepare, content}}]}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :idle, data}}]}
  end

  def idle(:cast, :stop, _data) do
    :keep_state_and_data
  end

  # Ignore stale AI messages that arrive after timeout
  def idle(:info, {:ai_done, _response}, _data) do
    Logger.debug("Ignoring stale :ai_done message in idle state")
    :keep_state_and_data
  end

  def idle(:info, {:ai_chunk, _chunk}, _data) do
    :keep_state_and_data
  end

  def idle(:info, {:ai_error, _reason}, _data) do
    Logger.debug("Ignoring stale :ai_error message in idle state")
    :keep_state_and_data
  end

  # Ignore stale tool results
  def idle(:info, {:tools_done, _results}, _data) do
    Logger.debug("Ignoring stale :tools_done message in idle state")
    :keep_state_and_data
  end

  # Ignore stale timeout messages
  def idle(:info, {:run_timeout, _run_id}, _data) do
    :keep_state_and_data
  end

  # Ignore stale retry timers
  def idle(:info, {:retry_ai, _run_id}, _data) do
    Logger.debug("Ignoring stale :retry_ai message in idle state")
    :keep_state_and_data
  end

  # Handle A2A mailbox notification in idle state
  def idle(:info, {:mailbox_message, agent_id, msg}, data) when data.agent_id == agent_id do
    Logger.info("Agent #{agent_id} received A2A #{msg.type} message from agent #{msg.from_agent_id}")
    # Schedule async processing — the agent will process this as a run
    send(self(), {:a2a_run, msg})
    :keep_state_and_data
  end

  def idle(:info, {:mailbox_message, _agent_id, _msg}, _data) do
    :keep_state_and_data
  end

  # Process A2A message as a new run (self-initiated)
  # Note: message was already pop'd from mailbox; ack happens after successful completion
  def idle(:info, {:a2a_run, msg}, data) do
    run_id = generate_run_id()
    timeout_ms = @default_timeout_ms

    # Format A2A message as user content for the agent
    content = format_a2a_as_prompt(msg)

    Logger.info("Starting A2A-initiated run #{run_id} for agent #{data.agent_id}")

    timeout_ref = Process.send_after(self(), {:run_timeout, run_id}, timeout_ms)

    # Prefer model_override from config (set by session_status tool) over default
    effective_model = data.config[:model_override] || data.config[:default_model]

    new_data = %{
      data
      | run_id: run_id,
        reply_to: nil,
        started_at: DateTime.utc_now(),
        timeout_ref: timeout_ref,
        model: effective_model |> Models.resolve(),
        a2a_message_id: msg.message_id
    }

    {:next_state, :preparing, new_data, [{:next_event, :internal, {:prepare, content}}]}
  end

  # ============================================================================
  # State: PREPARING
  # ============================================================================

  def preparing(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def preparing(:internal, {:prepare, content}, data) do
    Logger.debug("Preparing context for run #{data.run_id}")

    # 1. 加载会话历史
    messages = Persistence.load_session_messages(data.session_id)

    # 2. 添加用户消息
    user_message = %{role: "user", content: content}
    messages = messages ++ [user_message]

    # 3. 保存用户消息到数据库
    Persistence.save_message(data.session_id, :user, content)

    # 4. 构建系统提示
    prompt_config =
      data.config
      |> Map.put(:model, data.model)
      |> Map.put(:inbound_metadata, data.inbound_metadata)
      |> Map.put(:channel, data.config[:channel] || get_in(data.inbound_metadata || %{}, [:channel]))

    system_prompt = Prompt.build(data.agent_id, prompt_config)

    # 5. 加载可用工具
    tools = ToolExecutor.load_tools(data.config)
    Logger.info("Loaded #{length(tools)} tools for run #{data.run_id}")

    new_data = %{data | messages: messages, system_prompt: system_prompt, tools: tools}

    # Register with OutputManager for progressive output
    OutputManager.start_run(data.run_id, data.session_id)

    # 广播运行开始
    Broadcaster.broadcast_run_started(new_data)

    {:next_state, :inferring, new_data, [{:next_event, :internal, :call_ai}]}
  end

  def preparing(:cast, :stop, data) do
    reply_error(data.reply_to, :cancelled, data)
    {:next_state, :idle, data}
  end

  def preparing(:info, {:run_timeout, run_id}, %{run_id: run_id} = data) do
    Logger.warning("Run #{run_id} timed out during preparing")
    reply_error(data.reply_to, :timeout, data)
    {:next_state, :idle, data}
  end

  def preparing(:info, {:run_timeout, _other_run_id}, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: INFERRING
  # ============================================================================

  def inferring(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def inferring(:internal, :call_ai, data) do
    Logger.debug("Calling AI for run #{data.run_id}")

    # 广播正在调用 AI
    Broadcaster.broadcast_inferring(data)

    # 启动流式 AI 调用 (supervised for cancellation on stop/timeout)
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
        result =
          AIStream.complete(
            data.model,
            data.messages,
            system: data.system_prompt,
            tools: ToolExecutor.format_tools(data.tools),
            stream_to: parent
          )

        case result do
          {:ok, response} ->
            send(parent, {:ai_done, response})

          {:error, reason} ->
            send(parent, {:ai_error, reason})
        end
      end)

    {:keep_state, %{data | task_ref: pid}}
  end

  def inferring(:info, {:ai_chunk, chunk}, data) do
    # 处理流式响应块
    new_buffer = data.stream_buffer <> (chunk[:content] || "")
    new_data = %{data | stream_buffer: new_buffer}

    # 可以在这里发送流式更新到客户端
    Broadcaster.broadcast_chunk(data, chunk)

    {:keep_state, new_data}
  end

  def inferring(:info, {:ai_done, response}, data) do
    Logger.debug("AI response complete for run #{data.run_id}")

    cond do
      # 有工具调用
      response[:tool_calls] && length(response[:tool_calls]) > 0 ->
        content = response[:content] || ""

        # 如果有文本内容，通过 OutputManager 立即推送中间段
        if content != "" do
          OutputManager.deliver_segment(data.run_id, content, %{
            type: :intermediate,
            tool_calls_pending: length(response[:tool_calls])
          })

          Broadcaster.broadcast_segment(data, content, continuing: true)
        end

        new_data = %{
          data
          | pending_tool_calls: response[:tool_calls],
            stream_buffer: content
        }

        {:next_state, :executing_tools, new_data, [{:next_event, :internal, :execute_tools}]}

      # 纯文本响应
      true ->
        # 优先使用 response content，但如果为空则使用 stream_buffer
        content =
          case response[:content] do
            nil -> data.stream_buffer
            "" -> data.stream_buffer
            c -> c
          end

        finish_run(data, content, response)
    end
  end

  def inferring(:info, {:ai_error, reason}, data) do
    Logger.error("AI error in run #{data.run_id}: #{inspect(reason)}")

    if retryable?(reason) and data.retry_count < data.max_retries do
      new_retry = data.retry_count + 1
      delay_ms = retry_delay_ms(new_retry)

      Logger.warning(
        "AI error is retryable, scheduling retry #{new_retry}/#{data.max_retries} " <>
          "in #{delay_ms}ms for run #{data.run_id}"
      )

      # Broadcast retry status
      Broadcaster.broadcast_status(data, :retrying, %{
        retry: new_retry,
        max_retries: data.max_retries,
        delay_ms: delay_ms,
        reason: inspect(reason)
      })

      # Schedule retry after exponential backoff
      timer_ref = Process.send_after(self(), {:retry_ai, data.run_id}, delay_ms)

      {:keep_state, %{data | retry_count: new_retry, retry_timer_ref: timer_ref, stream_buffer: ""}}
    else
      if data.retry_count >= data.max_retries do
        Logger.error(
          "AI error in run #{data.run_id}: exhausted #{data.max_retries} retries, giving up"
        )
      end

      reply_error(data.reply_to, {:ai_error, reason, data.retry_count}, data)
      {:next_state, :idle, data}
    end
  end

  # Handle retry timer firing — re-invoke AI call
  def inferring(:info, {:retry_ai, run_id}, %{run_id: run_id} = data) do
    Logger.info("Retrying AI call (attempt #{data.retry_count}/#{data.max_retries}) for run #{run_id}")
    {:keep_state, %{data | retry_timer_ref: nil}, [{:next_event, :internal, :call_ai}]}
  end

  # Ignore stale retry timers from old runs
  def inferring(:info, {:retry_ai, _old_run_id}, _data) do
    :keep_state_and_data
  end

  def inferring(:cast, :stop, data) do
    Logger.info("Stopping run #{data.run_id}")
    cancel_running_task(data)
    if data.retry_timer_ref, do: Process.cancel_timer(data.retry_timer_ref)
    reply_error(data.reply_to, :cancelled, data)
    {:next_state, :idle, data}
  end

  def inferring({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :inferring, data}}]}
  end

  def inferring(:info, {:run_timeout, run_id}, %{run_id: run_id} = data) do
    Logger.warning("Run #{run_id} timed out during inferring")
    cancel_running_task(data)
    if data.retry_timer_ref, do: Process.cancel_timer(data.retry_timer_ref)
    reply_error(data.reply_to, :timeout, data)
    {:next_state, :idle, data}
  end

  def inferring(:info, {:run_timeout, _other_run_id}, _data) do
    # 忽略其他 run 的超时消息
    :keep_state_and_data
  end

  # ============================================================================
  # State: EXECUTING_TOOLS
  # ============================================================================

  def executing_tools(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def executing_tools(:internal, :execute_tools, data) do
    Logger.debug("Executing #{length(data.pending_tool_calls)} tools for run #{data.run_id}")

    parent = self()

    # 广播即将执行的工具
    tool_names =
      Enum.map(data.pending_tool_calls, fn tc ->
        tc["name"] || get_in(tc, ["function", "name"])
      end)

    Broadcaster.broadcast_status(data, :tools_start, %{tools: tool_names, count: length(tool_names)})

    # 在单独的 Task 中并行执行所有工具 (supervised for cancellation)
    {:ok, pid} = Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
      results =
        data.pending_tool_calls
        |> Task.async_stream(
          fn tool_call ->
            tool_name = tool_call["name"] || get_in(tool_call, ["function", "name"])
            params = ToolExecutor.extract_tool_params(tool_call)

            # 广播工具开始
            Phoenix.PubSub.broadcast(
              ClawdEx.PubSub,
              "agent:#{data.session_id}",
              {:agent_status, data.run_id, :tool_start,
               %{tool: tool_name, params: ToolExecutor.sanitize_params(params)}}
            )

            result = ToolExecutor.execute_tool(tool_call, data)

            # 广播工具完成
            Phoenix.PubSub.broadcast(
              ClawdEx.PubSub,
              "agent:#{data.session_id}",
              {:agent_status, data.run_id, :tool_done,
               %{tool: tool_name, success: match?({:ok, _}, result)}}
            )

            {tool_call, result}
          end,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, :timeout} -> {%{}, {:error, :timeout}}
        end)

      send(parent, {:tools_done, results})
    end)

    {:keep_state, %{data | task_ref: pid}}
  end

  def executing_tools(:info, {:tools_done, results}, data) do
    Logger.debug("Tools completed for run #{data.run_id}")

    new_iterations = data.tool_iterations + 1

    # Send progress summary via OutputManager
    progress_summary = ToolExecutor.format_tools_progress(results, new_iterations)
    OutputManager.deliver_progress(data.run_id, progress_summary, %{
      type: :tools_done,
      iteration: new_iterations
    })

    # 广播工具完成事件（让渠道可以发送中间结果）
    Broadcaster.broadcast_tools_done(data, results)

    # 构建工具结果消息
    tool_messages =
      Enum.map(results, fn {tool_call, result} ->
        %{
          role: "tool",
          tool_call_id: tool_call["id"],
          content: ToolExecutor.format_tool_result(result)
        }
      end)

    # 添加助手消息（如果有内容）
    assistant_message =
      if data.stream_buffer != "" do
        [%{role: "assistant", content: data.stream_buffer, tool_calls: data.pending_tool_calls}]
      else
        [%{role: "assistant", tool_calls: data.pending_tool_calls}]
      end

    # 更新消息历史
    new_messages = data.messages ++ assistant_message ++ tool_messages

    new_data = %{
      data
      | messages: new_messages,
        pending_tool_calls: [],
        stream_buffer: "",
        tool_iterations: new_iterations
    }

    # Check max iterations to prevent infinite loops
    max_iters = max_tool_iterations()

    if new_iterations >= max_iters do
      Logger.warning(
        "Run #{data.run_id} hit max tool iterations (#{max_iters}), forcing completion"
      )

      finish_run(new_data, "[Stopped: too many tool calls]", %{})
    else
      # 继续推理
      {:next_state, :inferring, new_data, [{:next_event, :internal, :call_ai}]}
    end
  end

  def executing_tools(:cast, :stop, data) do
    Logger.info("Stopping run #{data.run_id} during tool execution")
    cancel_running_task(data)
    reply_error(data.reply_to, :cancelled, data)
    {:next_state, :idle, data}
  end

  def executing_tools({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :executing_tools, data}}]}
  end

  def executing_tools(:info, {:run_timeout, run_id}, %{run_id: run_id} = data) do
    Logger.warning("Run #{run_id} timed out during tool execution")
    cancel_running_task(data)
    reply_error(data.reply_to, :timeout, data)
    {:next_state, :idle, data}
  end

  def executing_tools(:info, {:run_timeout, _other_run_id}, _data) do
    :keep_state_and_data
  end

  # Ignore stale retry timers during tool execution
  def executing_tools(:info, {:retry_ai, _run_id}, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # ============================================================================
  # Retry Logic
  # ============================================================================

  @doc false
  # Determines if an AI error is retryable based on the error type.
  # Retryable: overloaded, rate limits, server errors, timeouts, connection errors
  # Not retryable: bad request, auth errors, content policy violations
  def retryable?(:overloaded), do: true
  def retryable?(:timeout), do: true
  def retryable?(:closed), do: true
  def retryable?(:econnrefused), do: true
  def retryable?(:econnreset), do: true

  # HTTP status-based errors
  def retryable?({:api_error, status, _body}) when status in [429, 500, 502, 503, 529], do: true
  def retryable?({:api_error, 400, _body}), do: false
  def retryable?({:api_error, 401, _body}), do: false
  def retryable?({:api_error, 403, _body}), do: false

  # String-based error matching
  def retryable?(reason) when is_binary(reason) do
    reason_lower = String.downcase(reason)

    cond do
      String.contains?(reason_lower, "overloaded") -> true
      String.contains?(reason_lower, "rate limit") -> true
      String.contains?(reason_lower, "529") -> true
      String.contains?(reason_lower, "timeout") -> true
      String.contains?(reason_lower, "econnrefused") -> true
      String.contains?(reason_lower, "content policy") -> false
      String.contains?(reason_lower, "authentication") -> false
      String.contains?(reason_lower, "unauthorized") -> false
      String.contains?(reason_lower, "invalid api key") -> false
      # Default for other string errors: not retryable
      true -> false
    end
  end

  # Tuple errors with string descriptions
  def retryable?({:api_error, _status, body}) when is_binary(body) do
    retryable?(body)
  end

  # Catch-all: not retryable
  def retryable?(_), do: false

  # Exponential backoff: 2s, 4s, 8s for attempts 1, 2, 3
  defp retry_delay_ms(attempt) when attempt > 0 do
    trunc(:math.pow(2, attempt) * 1000)
  end

  @doc """
  Returns a user-friendly error message based on the AI error type.
  Used by channels (Telegram, etc.) to display appropriate messages.
  """
  def friendly_error_message({:ai_error, reason, retry_count}) when retry_count > 0 do
    base = friendly_error_reason(reason)
    "#{base}（已自动重试 #{retry_count} 次）"
  end

  def friendly_error_message({:ai_error, reason, _retry_count}) do
    friendly_error_reason(reason)
  end

  def friendly_error_message(reason), do: friendly_error_reason(reason)

  defp friendly_error_reason(:timeout), do: "AI 响应超时，请稍后重试或简化问题"
  defp friendly_error_reason(:overloaded), do: "AI 服务繁忙，请稍后重试"

  defp friendly_error_reason({:api_error, 429, _}),
    do: "AI 请求频率过高，请稍后重试"

  defp friendly_error_reason({:api_error, status, _}) when status in [500, 502, 503, 529],
    do: "AI 服务暂时不可用，请稍后重试"

  defp friendly_error_reason({:api_error, 401, _}),
    do: "AI 认证错误，请联系管理员"

  defp friendly_error_reason({:api_error, 403, _}),
    do: "AI 访问被拒绝，请联系管理员"

  defp friendly_error_reason({:api_error, 400, body}) when is_binary(body) do
    if String.contains?(String.downcase(body), "content policy") do
      "消息内容可能违反了 AI 使用政策，请调整后重试"
    else
      "AI 请求格式错误，请重试"
    end
  end

  defp friendly_error_reason(reason) when is_binary(reason) do
    reason_lower = String.downcase(reason)

    cond do
      String.contains?(reason_lower, "overloaded") -> "AI 服务繁忙，请稍后重试"
      String.contains?(reason_lower, "timeout") -> "AI 响应超时，请稍后重试或简化问题"
      String.contains?(reason_lower, "rate limit") -> "AI 请求频率过高，请稍后重试"
      String.contains?(reason_lower, "authentication") -> "AI 认证错误，请联系管理员"
      String.contains?(reason_lower, "unauthorized") -> "AI 认证错误，请联系管理员"
      true -> "AI 处理出错，请稍后重试"
    end
  end

  defp friendly_error_reason(_reason), do: "AI 处理出错，请稍后重试"

  defp cancel_running_task(%{task_ref: pid}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
  end

  defp cancel_running_task(_data), do: :ok

  defp via_tuple(session_id) do
    {:via, Registry, {ClawdEx.AgentLoopRegistry, session_id}}
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp finish_run(data, content, response) do
    # 取消超时定时器
    if data.timeout_ref, do: Process.cancel_timer(data.timeout_ref)

    # 处理空响应情况
    final_content =
      case content do
        nil -> "[No response from AI]"
        "" -> "[Empty response from AI]"
        c -> c
      end

    # 保存助手消息
    Persistence.save_message(data.session_id, :assistant, final_content,
      model: data.model,
      tokens_in: response[:tokens_in],
      tokens_out: response[:tokens_out]
    )

    # 广播运行完成
    Broadcaster.broadcast_run_done(data, final_content)

    # Signal OutputManager that run is complete
    OutputManager.deliver_complete(data.run_id, final_content, %{
      model: data.model,
      iterations: data.tool_iterations
    })

    # Trigger webhook for run completion
    ClawdEx.Webhooks.Manager.trigger("agent.run.completed", %{
      run_id: data.run_id,
      session_id: data.session_id,
      agent_id: data.agent_id,
      model: data.model,
      iterations: data.tool_iterations,
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    # Ack A2A message after successful completion (not before the run)
    if data.a2a_message_id && data.agent_id do
      A2AMailbox.ack(data.agent_id, data.a2a_message_id)
    end

    # 回复调用者 (nil reply_to for A2A-initiated runs)
    if data.reply_to do
      GenStateMachine.reply(data.reply_to, {:ok, final_content})
    end

    Logger.info("Run #{data.run_id} completed")
    {:next_state, :idle, %{data | timeout_ref: nil}}
  end

  defp reply_error(from, reason, data) do
    if data, do: Broadcaster.broadcast_run_error(data, reason)
    if from, do: GenStateMachine.reply(from, {:error, reason})
  end

  # ============================================================================
  # A2A Integration
  # ============================================================================

  # Check A2A mailbox for pending messages (non-blocking)
  defp check_a2a_mailbox(agent_id) do
    case A2AMailbox.pop(agent_id) do
      {:ok, msg} ->
        Logger.debug("Agent #{agent_id} has pending A2A message, scheduling processing")
        send(self(), {:a2a_run, msg})

      :empty ->
        :ok
    end
  end

  # Format an A2A message as a prompt for the agent
  defp format_a2a_as_prompt(msg) do
    header =
      case msg.type do
        "request" ->
          "[A2A Request from Agent #{msg.from_agent_id}]"

        "notification" ->
          "[A2A Notification from Agent #{msg.from_agent_id}]"

        "delegation" ->
          task_title = get_in(msg, [:metadata, "task_title"]) || "Unknown"
          "[A2A Task Delegation from Agent #{msg.from_agent_id}: #{task_title}]"

        _ ->
          "[A2A Message from Agent #{msg.from_agent_id}]"
      end

    reply_hint =
      if msg.type == "request" do
        "\n\nPlease respond using the a2a tool with action 'respond' and " <>
          "replyToMessageId: \"#{msg.message_id}\""
      else
        ""
      end

    "#{header}\n\n#{msg.content}#{reply_hint}"
  end

end
