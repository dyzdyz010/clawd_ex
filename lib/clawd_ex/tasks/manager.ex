defmodule ClawdEx.Tasks.Manager do
  @moduledoc """
  任务管理器 — 定期检查任务状态，处理超时/恢复。

  职责：
  1. 定期扫描 running 状态的任务，检测 session 是否存活
  2. 对于 session 已死的 running 任务，重新排队（increment retry_count）
  3. 分配 pending 任务给空闲的 agent
  4. 处理任务超时（heartbeat 过期）
  5. 管理任务生命周期
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias ClawdEx.Tasks.Task
  alias ClawdEx.Sessions.SessionManager
  alias ClawdEx.Repo

  @check_interval_ms 30_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a new task"
  @spec create_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get a task by ID"
  @spec get_task(integer()) :: Task.t() | nil
  def get_task(id) do
    Repo.get(Task, id)
  end

  @doc "List tasks with optional filters"
  @spec list_tasks(keyword()) :: [Task.t()]
  def list_tasks(opts \\ []) do
    query = from(t in Task, order_by: [asc: t.priority, asc: t.inserted_at])

    query = filter_by_status(query, Keyword.get(opts, :status))
    query = filter_by_agent(query, Keyword.get(opts, :agent_id))
    query = filter_by_parent(query, Keyword.get(opts, :parent_task_id))

    limit = Keyword.get(opts, :limit, 50)
    query = from(t in query, limit: ^limit)

    Repo.all(query)
  end

  @doc "Update a task's status and/or result"
  @spec update_task(integer(), map()) :: {:ok, Task.t()} | {:error, term()}
  def update_task(task_id, attrs) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        task
        |> Task.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Send heartbeat for a running task"
  @spec heartbeat(integer()) :: {:ok, Task.t()} | {:error, term()}
  def heartbeat(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        task
        |> Task.changeset(%{last_heartbeat_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc "Assign a task to an agent session"
  @spec assign_task(integer(), integer(), String.t()) :: {:ok, Task.t()} | {:error, term()}
  def assign_task(task_id, agent_id, session_key) do
    update_task(task_id, %{
      status: "assigned",
      agent_id: agent_id,
      session_key: session_key
    })
  end

  @doc "Start a task (move from assigned to running)"
  @spec start_task(integer()) :: {:ok, Task.t()} | {:error, term()}
  def start_task(task_id) do
    update_task(task_id, %{
      status: "running",
      started_at: DateTime.utc_now(),
      last_heartbeat_at: DateTime.utc_now()
    })
  end

  @doc "Complete a task with result"
  @spec complete_task(integer(), map()) :: {:ok, Task.t()} | {:error, term()}
  def complete_task(task_id, result \\ %{}) do
    update_task(task_id, %{
      status: "completed",
      result: result,
      completed_at: DateTime.utc_now()
    })
  end

  @doc "Fail a task with error info"
  @spec fail_task(integer(), map()) :: {:ok, Task.t()} | {:error, term()}
  def fail_task(task_id, error_info \\ %{}) do
    update_task(task_id, %{
      status: "failed",
      result: error_info,
      completed_at: DateTime.utc_now()
    })
  end

  @doc "Cancel a task"
  @spec cancel_task(integer()) :: {:ok, Task.t()} | {:error, term()}
  def cancel_task(task_id) do
    update_task(task_id, %{
      status: "cancelled",
      completed_at: DateTime.utc_now()
    })
  end

  @doc "Delegate a task to another agent"
  @spec delegate_task(integer(), integer()) :: {:ok, Task.t()} | {:error, term()}
  def delegate_task(task_id, target_agent_id) do
    update_task(task_id, %{
      agent_id: target_agent_id,
      status: "pending",
      session_key: nil
    })
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check_tasks, state) do
    check_running_tasks()
    check_stale_heartbeats()
    auto_assign_pending_tasks()
    schedule_check()
    {:noreply, state}
  end

  # ============================================================================
  # Periodic Checks
  # ============================================================================

  defp schedule_check do
    Process.send_after(self(), :check_tasks, @check_interval_ms)
  end

  # Check running tasks whose sessions have died
  defp check_running_tasks do
    running_tasks =
      from(t in Task, where: t.status == "running" and not is_nil(t.session_key))
      |> Repo.all()

    for task <- running_tasks do
      case SessionManager.find_session(task.session_key) do
        {:ok, _pid} ->
          # Session alive, skip
          :ok

        :not_found ->
          # Session dead — requeue if retries remain
          Logger.info("Task #{task.id} session #{task.session_key} dead, re-queuing")
          requeue_task(task)
      end
    end
  end

  # Check tasks with expired heartbeats (>2x timeout)
  defp check_stale_heartbeats do
    running_tasks =
      from(t in Task, where: t.status == "running" and not is_nil(t.last_heartbeat_at))
      |> Repo.all()

    now = DateTime.utc_now()

    for task <- running_tasks do
      heartbeat_deadline = task.timeout_seconds * 2

      seconds_since_heartbeat =
        DateTime.diff(now, task.last_heartbeat_at, :second)

      if seconds_since_heartbeat > heartbeat_deadline do
        Logger.warning(
          "Task #{task.id} heartbeat expired (#{seconds_since_heartbeat}s > #{heartbeat_deadline}s), marking stale"
        )

        requeue_task(task)
      end
    end
  end

  # Try to assign pending tasks to available agents
  defp auto_assign_pending_tasks do
    pending_tasks =
      from(t in Task,
        where: t.status == "pending" and not is_nil(t.agent_id),
        where: is_nil(t.scheduled_at) or t.scheduled_at <= ^DateTime.utc_now(),
        order_by: [asc: t.priority, asc: t.inserted_at],
        limit: 10
      )
      |> Repo.all()

    for task <- pending_tasks do
      # Check if the assigned agent has an active session
      active_sessions = SessionManager.list_sessions()

      agent_session =
        Enum.find(active_sessions, fn key ->
          String.starts_with?(key, "agent:#{task.agent_id}:")
        end)

      if agent_session do
        Logger.info("Auto-assigning task #{task.id} to session #{agent_session}")

        task
        |> Task.changeset(%{status: "assigned", session_key: agent_session})
        |> Repo.update()

        # Notify agent via PubSub
        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "tasks:agent:#{task.agent_id}",
          {:task_assigned, task.id, task.title}
        )
      end
    end
  end

  # Requeue a task (increment retry, set back to pending)
  defp requeue_task(task) do
    new_retry = task.retry_count + 1

    if new_retry > task.max_retries do
      Logger.warning("Task #{task.id} exceeded max retries (#{task.max_retries}), marking failed")

      task
      |> Task.changeset(%{
        status: "failed",
        result: Map.merge(task.result || %{}, %{"error" => "max_retries_exceeded"}),
        completed_at: DateTime.utc_now()
      })
      |> Repo.update()
    else
      task
      |> Task.changeset(%{
        status: "pending",
        retry_count: new_retry,
        session_key: nil,
        last_heartbeat_at: nil
      })
      |> Repo.update()
    end
  end

  # ============================================================================
  # Query Helpers
  # ============================================================================

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status) when is_binary(status) do
    from(t in query, where: t.status == ^status)
  end

  defp filter_by_status(query, statuses) when is_list(statuses) do
    from(t in query, where: t.status in ^statuses)
  end

  defp filter_by_agent(query, nil), do: query

  defp filter_by_agent(query, agent_id) do
    from(t in query, where: t.agent_id == ^agent_id)
  end

  defp filter_by_parent(query, nil), do: query

  defp filter_by_parent(query, parent_id) do
    from(t in query, where: t.parent_task_id == ^parent_id)
  end
end
