defmodule ClawdEx.Tools.A2A do
  @moduledoc """
  A2A 工具 — 让 Agent 能发现和与其他 Agent 通信。

  Actions:
  - discover: 列出可用 Agent 及其能力
  - send: 发送通知给另一个 Agent（fire-and-forget）
  - request: 请求另一个 Agent 做某事（同步等待响应）
  - delegate: 委托任务给另一个 Agent（通过 TaskManager + 通知）
  - broadcast: 向所有注册 Agent 广播消息
  - check_delegation: 查看委托任务状态
  """

  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.A2A.Router

  @impl true
  def name, do: "a2a"

  @impl true
  def description do
    "Agent-to-Agent communication: discover available agents, send notifications, " <>
      "make sync requests, delegate tasks, broadcast messages, or check delegation status."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["discover", "send", "request", "respond", "delegate", "broadcast", "check_delegation"],
          description: "A2A action to perform"
        },
        targetAgentId: %{
          type: "integer",
          description: "Target agent ID (for send/request/delegate actions)"
        },
        content: %{
          type: "string",
          description: "Message content to send"
        },
        metadata: %{
          type: "object",
          description: "Optional metadata to include with the message"
        },
        priority: %{
          type: "integer",
          description: "Message priority 1-10. 1=urgent, 5=normal (default), 10=low"
        },
        replyToMessageId: %{
          type: "string",
          description: "Message ID to reply to (for respond action)"
        },
        capability: %{
          type: "string",
          description: "Filter agents by capability (for discover action)"
        },
        timeout: %{
          type: "integer",
          description: "Timeout in milliseconds for request action. Default: 30000"
        },
        taskTitle: %{
          type: "string",
          description: "Task title (for delegate action)"
        },
        taskDescription: %{
          type: "string",
          description: "Task description (for delegate action)"
        },
        taskPriority: %{
          type: "integer",
          description: "Task priority 1-10 (for delegate action). Default: 5"
        },
        taskContext: %{
          type: "object",
          description: "Task context data (for delegate action)"
        },
        taskId: %{
          type: "integer",
          description: "Task ID (for check_delegation action)"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(params, context) do
    action = Map.get(params, "action")

    case action do
      "discover" -> discover_agents(params)
      "send" -> send_notification(params, context)
      "request" -> send_request(params, context)
      "respond" -> respond_to_request(params, context)
      "delegate" -> delegate_to_agent(params, context)
      "broadcast" -> broadcast_message(params, context)
      "check_delegation" -> check_delegation(params, _context = context)
      _ -> {:error, "Unknown action: #{action}. Use: discover, send, request, respond, delegate, broadcast, check_delegation"}
    end
  end

  # ============================================================================
  # Actions
  # ============================================================================

  defp discover_agents(params) do
    opts =
      if cap = Map.get(params, "capability") do
        [capability: cap]
      else
        []
      end

    case Router.discover(opts) do
      {:ok, agents} ->
        {:ok,
         %{
           count: length(agents),
           agents:
             Enum.map(agents, fn a ->
               base = %{
                 agent_id: a.agent_id,
                 name: Map.get(a, :name),
                 capabilities: Map.get(a, :capabilities, []),
                 registered: Map.has_key?(a, :registered_at)
               }

               if Map.has_key?(a, :registered_at) do
                 Map.put(base, :registered_at, a.registered_at)
               else
                 base
               end
             end)
         }}
    end
  end

  defp send_notification(params, context) do
    from_agent_id = context[:agent_id]
    to_agent_id = Map.get(params, "targetAgentId")
    content = Map.get(params, "content")
    metadata = Map.get(params, "metadata", %{})
    priority = Map.get(params, "priority", 5)

    cond do
      is_nil(to_agent_id) ->
        {:error, "targetAgentId is required for send action"}

      is_nil(content) || content == "" ->
        {:error, "content is required for send action"}

      true ->
        case Router.send_message(from_agent_id, to_agent_id, content,
               type: "notification",
               metadata: metadata,
               priority: priority
             ) do
          {:ok, message_id} ->
            {:ok,
             %{
               message_id: message_id,
               type: "notification",
               to_agent_id: to_agent_id,
               priority: priority,
               message: "Notification sent"
             }}

          {:error, reason} ->
            {:error, "Failed to send notification: #{inspect(reason)}"}
        end
    end
  end

  defp send_request(params, context) do
    from_agent_id = context[:agent_id]
    to_agent_id = Map.get(params, "targetAgentId")
    content = Map.get(params, "content")
    metadata = Map.get(params, "metadata", %{})
    timeout = Map.get(params, "timeout", 30_000)
    priority = Map.get(params, "priority", 5)

    cond do
      is_nil(to_agent_id) ->
        {:error, "targetAgentId is required for request action"}

      is_nil(content) || content == "" ->
        {:error, "content is required for request action"}

      true ->
        case Router.request(from_agent_id, to_agent_id, content,
               metadata: metadata,
               timeout: timeout,
               priority: priority
             ) do
          {:ok, response} ->
            {:ok,
             %{
               type: "response",
               from_agent_id: to_agent_id,
               content: response,
               message: "Request completed"
             }}

          {:error, :timeout} ->
            {:error, "Request to agent #{to_agent_id} timed out after #{timeout}ms"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
    end
  end

  defp respond_to_request(params, context) do
    from_agent_id = context[:agent_id]
    reply_to_message_id = Map.get(params, "replyToMessageId")
    content = Map.get(params, "content")
    metadata = Map.get(params, "metadata", %{})

    cond do
      is_nil(reply_to_message_id) || reply_to_message_id == "" ->
        {:error, "replyToMessageId is required for respond action"}

      is_nil(content) || content == "" ->
        {:error, "content is required for respond action"}

      true ->
        case Router.respond(reply_to_message_id, from_agent_id, content, metadata: metadata) do
          {:ok, message_id} ->
            {:ok,
             %{
               message_id: message_id,
               type: "response",
               reply_to: reply_to_message_id,
               message: "Response sent"
             }}

          {:error, reason} ->
            {:error, "Failed to send response: #{inspect(reason)}"}
        end
    end
  end

  defp delegate_to_agent(params, context) do
    from_agent_id = context[:agent_id]
    to_agent_id = Map.get(params, "targetAgentId")
    task_title = Map.get(params, "taskTitle")
    task_desc = Map.get(params, "taskDescription", "")
    task_priority = Map.get(params, "taskPriority", 5)
    task_context = Map.get(params, "taskContext", %{})
    content = Map.get(params, "content", task_title || "Delegated task")
    priority = Map.get(params, "priority", 5)

    cond do
      is_nil(to_agent_id) ->
        {:error, "targetAgentId is required for delegate action"}

      is_nil(task_title) || task_title == "" ->
        {:error, "taskTitle is required for delegate action"}

      true ->
        # 1. Create task via TaskManager
        task_attrs = %{
          title: task_title,
          description: task_desc,
          priority: task_priority,
          agent_id: to_agent_id,
          context:
            Map.merge(task_context, %{
              "delegated_by" => from_agent_id,
              "original_content" => content
            })
        }

        case ClawdEx.Tasks.Manager.create_task(task_attrs) do
          {:ok, task} ->
            # 2. Send delegation notification to target agent
            Router.send_message(from_agent_id, to_agent_id, content,
              type: "delegation",
              priority: priority,
              metadata: %{
                "task_id" => task.id,
                "task_title" => task_title,
                "priority" => task_priority
              }
            )

            {:ok,
             %{
               task_id: task.id,
               message_type: "delegation",
               to_agent_id: to_agent_id,
               title: task_title,
               message: "Task delegated to agent #{to_agent_id}"
             }}

          {:error, reason} ->
            {:error, "Failed to create delegated task: #{inspect(reason)}"}
        end
    end
  end

  defp broadcast_message(params, context) do
    from_agent_id = context[:agent_id]
    content = Map.get(params, "content")
    metadata = Map.get(params, "metadata", %{})
    priority = Map.get(params, "priority", 5)

    cond do
      is_nil(content) || content == "" ->
        {:error, "content is required for broadcast action"}

      true ->
        case Router.discover() do
          {:ok, agents} ->
            # Filter out self to avoid sending to ourselves
            targets = Enum.reject(agents, fn a -> a.agent_id == from_agent_id end)

            sent_count =
              Enum.count(targets, fn agent ->
                case Router.send_message(from_agent_id, agent.agent_id, content,
                       type: "notification",
                       metadata: Map.merge(metadata, %{"broadcast" => true}),
                       priority: priority
                     ) do
                  {:ok, _} -> true
                  {:error, _} -> false
                end
              end)

            {:ok,
             %{
               sent_count: sent_count,
               total_agents: length(targets),
               message: "Broadcast sent to #{sent_count} agents"
             }}
        end
    end
  end

  defp check_delegation(params, _context) do
    task_id = Map.get(params, "taskId")

    cond do
      is_nil(task_id) ->
        {:error, "taskId is required for check_delegation action"}

      true ->
        case ClawdEx.Tasks.Manager.get_task(task_id) do
          nil ->
            {:error, "Task #{task_id} not found"}

          task ->
            {:ok,
             %{
               task_id: task.id,
               title: task.title,
               status: task.status,
               priority: task.priority,
               agent_id: task.agent_id,
               result: task.result,
               started_at: task.started_at,
               completed_at: task.completed_at,
               retry_count: task.retry_count,
               message: "Task #{task_id} is #{task.status}"
             }}
        end
    end
  end
end
