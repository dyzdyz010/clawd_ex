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

  alias ClawdEx.Agent.Prompt
  alias ClawdEx.AI.Models
  alias ClawdEx.AI.Stream, as: AIStream
  alias ClawdEx.Sessions.Message
  alias ClawdEx.Repo

  # Maximum tool iterations before forcing completion (prevent infinite loops)
  @max_tool_iterations 50

  @doc "Get the maximum tool iterations limit"
  def max_tool_iterations, do: @max_tool_iterations

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
    tool_iterations: 0
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

    # 清理状态
    new_data = %{
      data
      | run_id: nil,
        pending_tool_calls: [],
        stream_buffer: "",
        reply_to: nil,
        started_at: nil,
        timeout_ref: nil
    }

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
        model:
          Keyword.get(opts, :model, data.config[:default_model]) |> Models.resolve()
    }

    {:next_state, :preparing, new_data, [{:next_event, :internal, {:prepare, content}}]}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :idle, data}}]}
  end

  def idle(:cast, :stop, _data) do
    :keep_state_and_data
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
    messages = load_session_messages(data.session_id)

    # 2. 添加用户消息
    user_message = %{role: "user", content: content}
    messages = messages ++ [user_message]

    # 3. 保存用户消息到数据库
    save_message(data.session_id, :user, content)

    # 4. 构建系统提示
    system_prompt = Prompt.build(data.agent_id, data.config)

    # 5. 加载可用工具
    tools = load_tools(data.config)

    new_data = %{data | messages: messages, system_prompt: system_prompt, tools: tools}

    # 广播运行开始
    broadcast_run_started(new_data)
    
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
    broadcast_inferring(data)

    # 启动流式 AI 调用
    parent = self()

    Task.start(fn ->
      result =
        AIStream.complete(
          data.model,
          data.messages,
          system: data.system_prompt,
          tools: format_tools(data.tools),
          stream_to: parent
        )

      case result do
        {:ok, response} ->
          send(parent, {:ai_done, response})

        {:error, reason} ->
          send(parent, {:ai_error, reason})
      end
    end)

    :keep_state_and_data
  end

  def inferring(:info, {:ai_chunk, chunk}, data) do
    # 处理流式响应块
    new_buffer = data.stream_buffer <> (chunk[:content] || "")
    new_data = %{data | stream_buffer: new_buffer}

    # 可以在这里发送流式更新到客户端
    broadcast_chunk(data, chunk)

    {:keep_state, new_data}
  end

  def inferring(:info, {:ai_done, response}, data) do
    Logger.debug("AI response complete for run #{data.run_id}")

    cond do
      # 有工具调用
      response[:tool_calls] && length(response[:tool_calls]) > 0 ->
        new_data = %{
          data
          | pending_tool_calls: response[:tool_calls],
            stream_buffer: response[:content] || ""
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
    reply_error(data.reply_to, reason, data)
    {:next_state, :idle, data}
  end

  def inferring(:cast, :stop, data) do
    Logger.info("Stopping run #{data.run_id}")
    reply_error(data.reply_to, :cancelled, data)
    {:next_state, :idle, data}
  end

  def inferring({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :inferring, data}}]}
  end

  def inferring(:info, {:run_timeout, run_id}, %{run_id: run_id} = data) do
    Logger.warning("Run #{run_id} timed out during inferring")
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
    tool_names = Enum.map(data.pending_tool_calls, fn tc ->
      tc["name"] || get_in(tc, ["function", "name"])
    end)
    broadcast_status(data, :tools_start, %{tools: tool_names, count: length(tool_names)})

    # 在单独的 Task 中并行执行所有工具，避免 Task.async 消息干扰
    Task.start(fn ->
      results = 
        data.pending_tool_calls
        |> Task.async_stream(
          fn tool_call ->
            tool_name = tool_call["name"] || get_in(tool_call, ["function", "name"])
            params = extract_tool_params(tool_call)
            
            # 广播工具开始
            Phoenix.PubSub.broadcast(
              ClawdEx.PubSub,
              "agent:#{data.session_id}",
              {:agent_status, data.run_id, :tool_start, %{tool: tool_name, params: sanitize_params(params)}}
            )
            
            result = execute_tool(tool_call, data)
            
            # 广播工具完成
            Phoenix.PubSub.broadcast(
              ClawdEx.PubSub,
              "agent:#{data.session_id}",
              {:agent_status, data.run_id, :tool_done, %{tool: tool_name, success: match?({:ok, _}, result)}}
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

    :keep_state_and_data
  end

  def executing_tools(:info, {:tools_done, results}, data) do
    Logger.debug("Tools completed for run #{data.run_id}")
    
    new_iterations = data.tool_iterations + 1

    # 构建工具结果消息
    tool_messages =
      Enum.map(results, fn {tool_call, result} ->
        %{
          role: "tool",
          tool_call_id: tool_call["id"],
          content: format_tool_result(result)
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

    new_data = %{data | 
      messages: new_messages, 
      pending_tool_calls: [], 
      stream_buffer: "",
      tool_iterations: new_iterations
    }

    # Check max iterations to prevent infinite loops
    if new_iterations >= @max_tool_iterations do
      Logger.warning("Run #{data.run_id} hit max tool iterations (#{@max_tool_iterations}), forcing completion")
      finish_run(new_data, "[Stopped: too many tool calls]", %{})
    else
      # 继续推理
      {:next_state, :inferring, new_data, [{:next_event, :internal, :call_ai}]}
    end
  end

  def executing_tools(:cast, :stop, data) do
    Logger.info("Stopping run #{data.run_id} during tool execution")
    reply_error(data.reply_to, :cancelled, data)
    {:next_state, :idle, data}
  end

  def executing_tools({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, :executing_tools, data}}]}
  end

  def executing_tools(:info, {:run_timeout, run_id}, %{run_id: run_id} = data) do
    Logger.warning("Run #{run_id} timed out during tool execution")
    reply_error(data.reply_to, :timeout, data)
    {:next_state, :idle, data}
  end

  def executing_tools(:info, {:run_timeout, _other_run_id}, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(session_id) do
    {:via, Registry, {ClawdEx.AgentLoopRegistry, session_id}}
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp load_session_messages(session_id) do
    import Ecto.Query

    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.map(fn m ->
      base = %{role: to_string(m.role), content: m.content}

      # 添加工具调用相关字段
      base =
        if m.tool_calls && m.tool_calls != [] do
          Map.put(base, :tool_calls, m.tool_calls)
        else
          base
        end

      if m.tool_call_id do
        Map.put(base, :tool_call_id, m.tool_call_id)
      else
        base
      end
    end)
  end

  defp save_message(session_id, role, content, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      session_id: session_id,
      role: role,
      content: content,
      tool_calls: Keyword.get(opts, :tool_calls, []),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      model: Keyword.get(opts, :model),
      tokens_in: Keyword.get(opts, :tokens_in),
      tokens_out: Keyword.get(opts, :tokens_out)
    })
    |> Repo.insert!()
  end

  defp load_tools(config) do
    # TODO: 从配置加载工具列表
    allowed = Map.get(config, :tools_allow, ["*"])
    denied = Map.get(config, :tools_deny, [])

    ClawdEx.Tools.Registry.list_tools(allow: allowed, deny: denied)
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end

  defp execute_tool(tool_call, data) do
    # 兼容两种格式：
    # OpenAI: %{"id" => ..., "function" => %{"name" => ..., "arguments" => ...}}
    # Anthropic: %{"name" => ..., "input" => ...}
    tool_name = tool_call["name"] || get_in(tool_call, ["function", "name"])
    params = extract_tool_params(tool_call)

    context = %{
      session_id: data.session_id,
      agent_id: data.agent_id,
      run_id: data.run_id
    }

    Logger.debug("Executing tool #{tool_name} with params: #{inspect(params)}")

    case ClawdEx.Tools.Registry.execute(tool_name, params, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # 提取工具参数，兼容 Anthropic (input) 和 OpenAI (function.arguments) 格式
  defp extract_tool_params(tool_call) do
    # 先尝试获取参数
    raw_args = tool_call["input"] || 
               tool_call["arguments"] || 
               get_in(tool_call, ["function", "arguments"])
    
    cond do
      # 已经是 map
      is_map(raw_args) ->
        raw_args

      # JSON 字符串需要解析
      is_binary(raw_args) ->
        case Jason.decode(raw_args) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      true ->
        %{}
    end
  end

  defp format_tool_result({:ok, result}) when is_binary(result), do: result
  defp format_tool_result({:ok, result}), do: Jason.encode!(result)
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"

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
    save_message(data.session_id, :assistant, final_content,
      model: data.model,
      tokens_in: response[:tokens_in],
      tokens_out: response[:tokens_out]
    )

    # 广播运行完成
    broadcast_run_done(data, final_content)

    # 回复调用者
    GenStateMachine.reply(data.reply_to, {:ok, final_content})

    Logger.info("Run #{data.run_id} completed")
    {:next_state, :idle, %{data | timeout_ref: nil}}
  end

  defp reply_error(from, reason, data \\ nil) do
    if data, do: broadcast_run_error(data, reason)
    GenStateMachine.reply(from, {:error, reason})
  end

  defp broadcast_chunk(data, chunk) do
    # 通过 PubSub 广播流式更新
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent:#{data.session_id}",
      {:agent_chunk, data.run_id, chunk}
    )
  end
  
  # 广播运行状态更新
  defp broadcast_status(data, status, details \\ %{}) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent:#{data.session_id}",
      {:agent_status, data.run_id, status, details}
    )
  end
  
  defp broadcast_run_started(data) do
    broadcast_status(data, :started, %{
      model: data.model,
      started_at: data.started_at
    })
  end
  
  defp broadcast_inferring(data) do
    broadcast_status(data, :inferring, %{
      iteration: data.tool_iterations
    })
  end
  
  defp broadcast_tool_start(data, tool_name, params) do
    broadcast_status(data, :tool_start, %{
      tool: tool_name,
      params: sanitize_params(params),
      iteration: data.tool_iterations
    })
  end
  
  defp broadcast_tool_done(data, tool_name, result) do
    broadcast_status(data, :tool_done, %{
      tool: tool_name,
      success: match?({:ok, _}, result),
      iteration: data.tool_iterations
    })
  end
  
  defp broadcast_run_done(data, content) do
    broadcast_status(data, :done, %{
      content_preview: String.slice(content || "", 0..100)
    })
  end
  
  defp broadcast_run_error(data, reason) do
    broadcast_status(data, :error, %{
      reason: inspect(reason)
    })
  end
  
  # 清理敏感参数（不广播密码等）
  defp sanitize_params(params) when is_map(params) do
    params
    |> Map.take(["action", "command", "path", "url", "query", "sessionId"])
    |> Map.new(fn {k, v} -> 
      {k, if(is_binary(v) && String.length(v) > 100, do: String.slice(v, 0..97) <> "...", else: v)}
    end)
  end
  defp sanitize_params(_), do: %{}
end
