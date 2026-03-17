defmodule ClawdExWeb.TaskDetailLive do
  @moduledoc "Task detail page with subtasks, timeline, and heartbeat status"
  use ClawdExWeb, :live_view

  alias ClawdEx.Repo
  alias ClawdEx.Tasks.Task
  alias ClawdEx.Tasks.Manager, as: TaskManager

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Task |> Repo.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found")
         |> push_navigate(to: ~p"/tasks")}

      task ->
        task = Repo.preload(task, [:agent, :parent_task, subtasks: :agent])

        if connected?(socket) do
          Phoenix.PubSub.subscribe(ClawdEx.PubSub, "tasks:updates")
          # Poll heartbeat status every 10s
          :timer.send_interval(10_000, self(), :refresh)
        end

        socket =
          socket
          |> assign(:page_title, task.title)
          |> assign(:task, task)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("start_task", _params, socket) do
    case TaskManager.start_task(socket.assigns.task.id) do
      {:ok, _} -> {:noreply, reload_task(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to start task")}
    end
  end

  @impl true
  def handle_event("pause_task", _params, socket) do
    case TaskManager.update_task(socket.assigns.task.id, %{status: "paused"}) do
      {:ok, _} -> {:noreply, reload_task(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to pause task")}
    end
  end

  @impl true
  def handle_event("cancel_task", _params, socket) do
    case TaskManager.cancel_task(socket.assigns.task.id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Task cancelled") |> reload_task()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to cancel task")}
    end
  end

  @impl true
  def handle_event("retry_task", _params, socket) do
    case TaskManager.update_task(socket.assigns.task.id, %{status: "pending", retry_count: 0, completed_at: nil, started_at: nil}) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Task queued for retry") |> reload_task()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to retry task")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, reload_task(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, reload_task(socket)}
  end

  defp reload_task(socket) do
    case Task |> Repo.get(socket.assigns.task.id) do
      nil ->
        socket
        |> put_flash(:error, "Task no longer exists")
        |> push_navigate(to: ~p"/tasks")

      task ->
        task = Repo.preload(task, [:agent, :parent_task, subtasks: :agent])
        assign(socket, :task, task)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

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

  defp priority_bg(priority) when priority <= 3, do: "bg-red-500/20 text-red-400"
  defp priority_bg(priority) when priority <= 6, do: "bg-yellow-500/20 text-yellow-400"
  defp priority_bg(_priority), do: "bg-green-500/20 text-green-400"

  defp heartbeat_status(task) do
    cond do
      task.status != "running" -> :inactive
      is_nil(task.last_heartbeat_at) -> :unknown
      true ->
        seconds_ago = DateTime.diff(DateTime.utc_now(), task.last_heartbeat_at, :second)
        cond do
          seconds_ago < 60 -> :healthy
          seconds_ago < task.timeout_seconds -> :warning
          true -> :stale
        end
    end
  end

  defp heartbeat_color(:healthy), do: "text-green-400"
  defp heartbeat_color(:warning), do: "text-yellow-400"
  defp heartbeat_color(:stale), do: "text-red-400"
  defp heartbeat_color(_), do: "text-gray-500"

  defp heartbeat_label(:healthy), do: "Healthy"
  defp heartbeat_label(:warning), do: "Warning"
  defp heartbeat_label(:stale), do: "Stale"
  defp heartbeat_label(:unknown), do: "No heartbeat"
  defp heartbeat_label(:inactive), do: "Inactive"

  defp heartbeat_pulse(:healthy), do: "animate-pulse"
  defp heartbeat_pulse(_), do: ""

  defp timeline_steps(task) do
    steps = [
      %{label: "Created", time: task.inserted_at, done: true},
      %{label: "Assigned", time: if(task.agent_id, do: task.updated_at), done: task.status not in ["pending"]},
      %{label: "Running", time: task.started_at, done: task.status in ["running", "paused", "completed", "failed"]},
      %{label: terminal_label(task.status), time: task.completed_at, done: task.status in ["completed", "failed", "cancelled"]}
    ]

    steps
  end

  defp terminal_label("completed"), do: "Completed"
  defp terminal_label("failed"), do: "Failed"
  defp terminal_label("cancelled"), do: "Cancelled"
  defp terminal_label(_), do: "Completed"

  defp terminal_color("completed"), do: "text-green-400 border-green-400"
  defp terminal_color("failed"), do: "text-red-400 border-red-400"
  defp terminal_color("cancelled"), do: "text-gray-400 border-gray-400"
  defp terminal_color(_), do: "text-gray-600 border-gray-600"

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
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

  defp format_result(result) when result == %{}, do: nil
  defp format_result(nil), do: nil
  defp format_result(result), do: Jason.encode!(result, pretty: true)
end
