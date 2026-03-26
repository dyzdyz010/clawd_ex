defmodule ClawdExWeb.TasksLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Tasks.Task
  alias ClawdEx.Agents.Agent

  defp create_task(attrs \\ %{}) do
    defaults = %{title: "Test Task #{System.unique_integer([:positive])}", status: "pending", priority: 5}

    {:ok, task} =
      %Task{}
      |> Task.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    task
  end

  test "renders tasks page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tasks")

    assert html =~ "Tasks"
    assert html =~ "Manage and monitor agent tasks"
    assert html =~ "No tasks found"
    assert html =~ "New Task"
    assert html =~ "Pending"
    assert html =~ "Running"
    assert html =~ "Completed"
    assert html =~ "Failed"
    assert html =~ "Search tasks"
  end

  test "filter shows only matching tasks", %{conn: conn} do
    create_task(%{title: "Pending Task", status: "pending"})
    create_task(%{title: "Completed Task", status: "completed"})

    {:ok, view, _html} = live(conn, "/tasks")

    html = render_click(view, "filter", %{"status" => "pending"})
    assert html =~ "Pending Task"
    refute html =~ "Completed Task"

    html = render_click(view, "filter", %{"status" => "completed"})
    refute html =~ "Pending Task"
    assert html =~ "Completed Task"
  end

  test "search filters tasks by title", %{conn: conn} do
    create_task(%{title: "Alpha Task"})
    create_task(%{title: "Beta Task"})

    {:ok, view, _html} = live(conn, "/tasks")

    html = render_keyup(view, "search", %{"search" => "Alpha"})
    assert html =~ "Alpha Task"
    refute html =~ "Beta Task"
  end

  test "create task modal and submission", %{conn: conn} do
    {:ok, view, html} = live(conn, "/tasks")
    refute html =~ "Create Task"

    html = render_click(view, "open_create_modal")
    assert html =~ "Create Task"
    assert html =~ "Title"
    assert html =~ "Description"

    html =
      view
      |> form("form", %{title: "Brand New Task", description: "A description", priority: "3", agent_id: ""})
      |> render_submit()

    assert html =~ "Brand New Task"
    assert html =~ "Task created"
  end

  test "delete_task removes a task", %{conn: conn} do
    task = create_task(%{title: "Deletable Task"})
    {:ok, view, html} = live(conn, "/tasks")
    assert html =~ "Deletable Task"

    html = render_click(view, "delete_task", %{"id" => to_string(task.id)})
    assert html =~ "Task deleted"
    refute html =~ "Deletable Task"
  end

  test "cancel and retry tasks", %{conn: conn} do
    task = create_task(%{title: "Cancellable Task", status: "pending"})
    {:ok, view, _html} = live(conn, "/tasks")

    html = render_click(view, "cancel_task", %{"id" => to_string(task.id)})
    assert html =~ "Task cancelled"

    failed = create_task(%{title: "Failed Task", status: "failed"})
    {:ok, view2, _html} = live(conn, "/tasks")

    html = render_click(view2, "retry_task", %{"id" => to_string(failed.id)})
    assert html =~ "Task queued for retry"
  end
end
