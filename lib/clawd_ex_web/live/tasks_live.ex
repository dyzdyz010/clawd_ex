defmodule ClawdExWeb.TasksLive do
  @moduledoc "Tasks list page with filtering, creation, and real-time updates"
  use ClawdExWeb, :live_view

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Tasks.Task
  alias ClawdEx.Tasks.Manager, as: TaskManager
  alias ClawdEx.Agents.Agent

  import ClawdExWeb.Helpers.SafeParse

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "tasks:updates")
    end

    socket =
      socket
      |> assign(:page_title, "Tasks")
      |> assign(:filter_status, "all")
      |> assign(:search, "")
      |> assign(:show_create_modal, false)
      |> assign(:form, to_form(%{"title" => "", "description" => "", "priority" => "5", "agent_id" => ""}))
      |> assign(:agents, list_agents())
      |> load_tasks()
      |> load_stats()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    socket =
      socket
      |> assign(:filter_status, status)
      |> load_tasks()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> load_tasks()

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  @impl true
  def handle_event("close_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, false)}
  end

  @impl true
  def handle_event("create_task", %{"title" => title, "description" => desc, "priority" => priority, "agent_id" => agent_id}, socket) do
    attrs = %{
      title: title,
      description: desc,
      priority: safe_to_integer(priority) || 5
    }

    attrs = case safe_to_integer(agent_id) do
      nil -> attrs
      id -> Map.put(attrs, :agent_id, id)
    end

    case TaskManager.create_task(attrs) do
      {:ok, _task} ->
        socket =
          socket
          |> put_flash(:info, "Task created")
          |> assign(:show_create_modal, false)
          |> assign(:form, to_form(%{"title" => "", "description" => "", "priority" => "5", "agent_id" => ""}))
          |> load_tasks()
          |> load_stats()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create task")}
    end
  end

  @impl true
  def handle_event("start_task", %{"id" => id}, socket) do
    case TaskManager.start_task(safe_to_integer(id)) do
      {:ok, _} ->
        {:noreply, socket |> load_tasks() |> load_stats()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start task")}
    end
  end

  @impl true
  def handle_event("pause_task", %{"id" => id}, socket) do
    case TaskManager.update_task(safe_to_integer(id), %{status: "paused"}) do
      {:ok, _} ->
        {:noreply, socket |> load_tasks() |> load_stats()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to pause task")}
    end
  end

  @impl true
  def handle_event("cancel_task", %{"id" => id}, socket) do
    case TaskManager.cancel_task(safe_to_integer(id)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Task cancelled") |> load_tasks() |> load_stats()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel task")}
    end
  end

  @impl true
  def handle_event("retry_task", %{"id" => id}, socket) do
    task_id = safe_to_integer(id)

    case TaskManager.update_task(task_id, %{status: "pending", retry_count: 0, completed_at: nil, started_at: nil}) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Task queued for retry") |> load_tasks() |> load_stats()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to retry task")}
    end
  end

  @impl true
  def handle_event("delete_task", %{"id" => id}, socket) do
    case Repo.get(Task, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Repo.delete(task) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Task deleted") |> load_tasks() |> load_stats()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete task")}
        end
    end
  end

  @impl true
  def handle_info({:task_assigned, _task_id, _title}, socket) do
    {:noreply, socket |> load_tasks() |> load_stats()}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket |> load_tasks() |> load_stats()}
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp load_tasks(socket) do
    query =
      from(t in Task,
        left_join: a in assoc(t, :agent),
        left_join: p in assoc(t, :parent_task),
        preload: [agent: a, parent_task: p],
        order_by: [asc: t.priority, desc: t.inserted_at]
      )

    query =
      case socket.assigns.filter_status do
        "all" -> query
        status -> from(t in query, where: t.status == ^status)
      end

    query =
      case socket.assigns.search do
        "" -> query
        search -> from(t in query, where: ilike(t.title, ^"%#{search}%"))
      end

    tasks = Repo.all(query)

    # Load subtask counts
    subtask_counts =
      from(t in Task,
        where: not is_nil(t.parent_task_id),
        group_by: t.parent_task_id,
        select: {t.parent_task_id, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    assign(socket, tasks: tasks, subtask_counts: subtask_counts)
  end

  defp load_stats(socket) do
    stats = %{
      total: Repo.aggregate(Task, :count),
      pending: Repo.aggregate(from(t in Task, where: t.status == "pending"), :count),
      running: Repo.aggregate(from(t in Task, where: t.status == "running"), :count),
      completed: Repo.aggregate(from(t in Task, where: t.status == "completed"), :count),
      failed: Repo.aggregate(from(t in Task, where: t.status == "failed"), :count)
    }

    assign(socket, :stats, stats)
  end

  defp list_agents do
    Repo.all(from(a in Agent, where: a.active == true, order_by: a.name))
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp priority_bg(priority) when priority <= 3, do: "bg-red-500/20 text-red-400"
  defp priority_bg(priority) when priority <= 6, do: "bg-yellow-500/20 text-yellow-400"
  defp priority_bg(_priority), do: "bg-green-500/20 text-green-400"

  defp status_badge_classes(status) do
    case status do
      "pending" -> "bg-gray-500/20 text-gray-400"
      "assigned" -> "bg-blue-500/20 text-blue-400"
      "running" -> "bg-purple-500/20 text-purple-400"
      "paused" -> "bg-yellow-500/20 text-yellow-400"
      "completed" -> "bg-green-500/20 text-green-400"
      "failed" -> "bg-red-500/20 text-red-400"
      "cancelled" -> "bg-gray-500/20 text-gray-500"
      _ -> "bg-gray-500/20 text-gray-400"
    end
  end

  defp status_icon(status) do
    case status do
      "pending" -> "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
      "assigned" -> "M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
      "running" -> "M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"
      "paused" -> "M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z"
      "completed" -> "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
      "failed" -> "M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
      "cancelled" -> "M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"
      _ -> "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
    end
  end

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
    end
  end
end
