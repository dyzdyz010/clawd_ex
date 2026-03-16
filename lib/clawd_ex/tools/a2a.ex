defmodule ClawdEx.Tools.A2A do
  @moduledoc """
  A2A 工具 — 让 Agent 能发现和与其他 Agent 通信。

  Actions:
  - discover: 列出可用 Agent 及其能力
  - send: 发送通知给另一个 Agent（fire-and-forget）
  - request: 请求另一个 Agent 做某事（同步等待响应）
  - delegate: 委托任务给另一个 Agent（通过 TaskManager + 通知）
  """

  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.A2A.Router

  @impl true
  def name, do: "a2a"

  @impl true
  def description do
    "Agent-to-Agent communication: discover available agents, send notifications, " <>
      "make sync requests, or delegate tasks to other agents."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["discover", "send", "request", "delegate"],
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
      "delegate" -> delegate_to_agent(params, context)
      _ -> {:error, "Unknown action: #{action}. Use: discover, send, request, delegate"}
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
               %{
                 agent_id: a.agent_id,
                 capabilities: a.capabilities,
                 registered_at: a.registered_at
               }
             end)
         }}
    end
  end

  defp send_notification(params, context) do
    from_agent_id = context[:agent_id]
    to_agent_id = Map.get(params, "targetAgentId")
    content = Map.get(params, "content")
    metadata = Map.get(params, "metadata", %{})

    cond do
      is_nil(to_agent_id) ->
        {:error, "targetAgentId is required for send action"}

      is_nil(content) || content == "" ->
        {:error, "content is required for send action"}

      true ->
        case Router.send_message(from_agent_id, to_agent_id, content,
               type: "notification",
               metadata: metadata
             ) do
          {:ok, message_id} ->
            {:ok,
             %{
               message_id: message_id,
               type: "notification",
               to_agent_id: to_agent_id,
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

    cond do
      is_nil(to_agent_id) ->
        {:error, "targetAgentId is required for request action"}

      is_nil(content) || content == "" ->
        {:error, "content is required for request action"}

      true ->
        case Router.request(from_agent_id, to_agent_id, content,
               metadata: metadata,
               timeout: timeout
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

  defp delegate_to_agent(params, context) do
    from_agent_id = context[:agent_id]
    to_agent_id = Map.get(params, "targetAgentId")
    task_title = Map.get(params, "taskTitle")
    task_desc = Map.get(params, "taskDescription", "")
    task_priority = Map.get(params, "taskPriority", 5)
    task_context = Map.get(params, "taskContext", %{})
    content = Map.get(params, "content", task_title || "Delegated task")

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
end
