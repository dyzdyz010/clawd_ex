defmodule ClawdEx.Tools.TaskTool do
  @moduledoc """
  Task 工具 — 让 Agent 可以创建和管理任务。

  Actions:
  - create: 创建新任务（包括子任务）
  - list: 查看任务列表（按状态/agent 过滤）
  - update: 更新任务状态/结果
  - heartbeat: 发送心跳
  - delegate: 委派任务给其他 agent
  """

  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.Tasks.Manager, as: TaskManager

  @impl true
  def name, do: "task"

  @impl true
  def description do
    "Manage tasks: create, list, update status, send heartbeat, or delegate to another agent. " <>
      "Tasks persist across sessions and support retry, priority, and parent-child relationships."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["create", "list", "update", "heartbeat", "delegate"],
          description: "Task action to perform"
        },
        title: %{
          type: "string",
          description: "Task title (for create action)"
        },
        description: %{
          type: "string",
          description: "Task description (for create action)"
        },
        priority: %{
          type: "integer",
          description: "Task priority 1-10 (1=highest, 10=lowest). Default: 5"
        },
        parentTaskId: %{
          type: "integer",
          description: "Parent task ID for creating subtasks"
        },
        taskId: %{
          type: "integer",
          description: "Task ID for update/heartbeat/delegate actions"
        },
        status: %{
          type: "string",
          enum: ["pending", "assigned", "running", "paused", "completed", "failed", "cancelled"],
          description: "New status (for update action)"
        },
        result: %{
          type: "object",
          description: "Task result data (for update action when completing)"
        },
        context: %{
          type: "object",
          description: "Task context data (for create action)"
        },
        targetAgentId: %{
          type: "integer",
          description: "Target agent ID (for delegate action)"
        },
        filterStatus: %{
          type: "string",
          description: "Filter tasks by status (for list action)"
        },
        filterAgentId: %{
          type: "integer",
          description: "Filter tasks by agent (for list action)"
        },
        limit: %{
          type: "integer",
          description: "Max number of tasks to return (for list action). Default: 20"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(params, context) do
    action = Map.get(params, "action")

    case action do
      "create" -> create_task(params, context)
      "list" -> list_tasks(params, context)
      "update" -> update_task(params, context)
      "heartbeat" -> heartbeat_task(params)
      "delegate" -> delegate_task(params)
      _ -> {:error, "Unknown action: #{action}. Use: create, list, update, heartbeat, delegate"}
    end
  end

  # ============================================================================
  # Actions
  # ============================================================================

  defp create_task(params, context) do
    agent_id = context[:agent_id]
    session_key = context[:session_key]

    attrs = %{
      title: Map.get(params, "title", "Untitled Task"),
      description: Map.get(params, "description"),
      priority: Map.get(params, "priority", 5),
      agent_id: agent_id,
      session_key: session_key,
      parent_task_id: Map.get(params, "parentTaskId"),
      context: Map.get(params, "context", %{}),
      timeout_seconds: Map.get(params, "timeoutSeconds", 600)
    }

    case TaskManager.create_task(attrs) do
      {:ok, task} ->
        {:ok,
         %{
           task_id: task.id,
           title: task.title,
           status: task.status,
           priority: task.priority,
           message: "Task created successfully"
         }}

      {:error, changeset} ->
        {:error, "Failed to create task: #{inspect(changeset.errors)}"}
    end
  end

  defp list_tasks(params, context) do
    opts = [
      status: Map.get(params, "filterStatus"),
      agent_id: Map.get(params, "filterAgentId", context[:agent_id]),
      limit: Map.get(params, "limit", 20)
    ]

    tasks = TaskManager.list_tasks(opts)

    {:ok,
     %{
       count: length(tasks),
       tasks:
         Enum.map(tasks, fn t ->
           %{
             id: t.id,
             title: t.title,
             status: t.status,
             priority: t.priority,
             agent_id: t.agent_id,
             parent_task_id: t.parent_task_id,
             retry_count: t.retry_count,
             started_at: t.started_at,
             completed_at: t.completed_at,
             inserted_at: t.inserted_at
           }
         end)
     }}
  end

  defp update_task(params, _context) do
    task_id = Map.get(params, "taskId")

    unless task_id do
      {:error, "taskId is required for update action"}
    else
      attrs =
        %{}
        |> maybe_put(:status, Map.get(params, "status"))
        |> maybe_put(:result, Map.get(params, "result"))

      case TaskManager.update_task(task_id, attrs) do
        {:ok, task} ->
          {:ok,
           %{
             task_id: task.id,
             status: task.status,
             message: "Task updated"
           }}

        {:error, :not_found} ->
          {:error, "Task #{task_id} not found"}

        {:error, reason} ->
          {:error, "Failed to update task: #{inspect(reason)}"}
      end
    end
  end

  defp heartbeat_task(params) do
    task_id = Map.get(params, "taskId")

    unless task_id do
      {:error, "taskId is required for heartbeat action"}
    else
      case TaskManager.heartbeat(task_id) do
        {:ok, task} ->
          {:ok,
           %{
             task_id: task.id,
             last_heartbeat_at: task.last_heartbeat_at,
             message: "Heartbeat recorded"
           }}

        {:error, :not_found} ->
          {:error, "Task #{task_id} not found"}

        {:error, reason} ->
          {:error, "Heartbeat failed: #{inspect(reason)}"}
      end
    end
  end

  defp delegate_task(params) do
    task_id = Map.get(params, "taskId")
    target_agent_id = Map.get(params, "targetAgentId")

    cond do
      is_nil(task_id) ->
        {:error, "taskId is required for delegate action"}

      is_nil(target_agent_id) ->
        {:error, "targetAgentId is required for delegate action"}

      true ->
        case TaskManager.delegate_task(task_id, target_agent_id) do
          {:ok, task} ->
            {:ok,
             %{
               task_id: task.id,
               agent_id: task.agent_id,
               status: task.status,
               message: "Task delegated to agent #{target_agent_id}"
             }}

          {:error, :not_found} ->
            {:error, "Task #{task_id} not found"}

          {:error, reason} ->
            {:error, "Delegation failed: #{inspect(reason)}"}
        end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
