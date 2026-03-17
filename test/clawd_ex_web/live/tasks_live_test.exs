defmodule ClawdExWeb.TasksLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Tasks.Task
  alias ClawdEx.Agents.Agent

  defp create_agent(_context \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "test-agent-#{System.unique_integer([:positive])}", active: true})
      |> Repo.insert()

    agent
  end

  defp create_task(attrs \\ %{}) do
    defaults = %{title: "Test Task #{System.unique_integer([:positive])}", status: "pending", priority: 5}

    {:ok, task} =
      %Task{}
      |> Task.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    task
  end

  describe "mount" do
    test "renders tasks page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tasks")

      assert html =~ "Tasks"
      assert html =~ "Manage and monitor agent tasks"
    end

    test "shows empty state when no tasks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tasks")

      assert html =~ "No tasks found"
      assert html =~ "Create your first task"
    end

    test "contains key UI elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tasks")

      # Title
      assert html =~ "Tasks"
      # Create button
      assert html =~ "New Task"
      # Filter buttons
      assert html =~ "Pending"
      assert html =~ "Running"
      assert html =~ "Completed"
      assert html =~ "Failed"
      # Search box
      assert html =~ "Search tasks"
      # Stats
      assert html =~ "Total"
    end

    test "renders tasks when they exist", %{conn: conn} do
      create_task(%{title: "My Important Task"})
      {:ok, _view, html} = live(conn, "/tasks")

      assert html =~ "My Important Task"
      refute html =~ "No tasks found"
    end

    test "shows stats correctly", %{conn: conn} do
      create_task(%{title: "Pending one", status: "pending"})
      create_task(%{title: "Running one", status: "running"})
      create_task(%{title: "Done one", status: "completed"})

      {:ok, _view, html} = live(conn, "/tasks")

      # Stats section should show counts
      assert html =~ "Total"
      assert html =~ "Pending"
      assert html =~ "Running"
      assert html =~ "Completed"
    end
  end

  describe "events" do
    test "filter event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tasks")

      html = render_click(view, "filter", %{"status" => "pending"})
      assert html =~ "Tasks"

      html = render_click(view, "filter", %{"status" => "completed"})
      assert html =~ "Tasks"

      html = render_click(view, "filter", %{"status" => "all"})
      assert html =~ "Tasks"
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

    test "search event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tasks")

      html = render_keyup(view, "search", %{"search" => "test"})
      assert html =~ "Tasks"
    end

    test "search filters tasks by title", %{conn: conn} do
      create_task(%{title: "Alpha Task"})
      create_task(%{title: "Beta Task"})

      {:ok, view, _html} = live(conn, "/tasks")

      html = render_keyup(view, "search", %{"search" => "Alpha"})
      assert html =~ "Alpha Task"
      refute html =~ "Beta Task"
    end

    test "open_create_modal event shows modal", %{conn: conn} do
      {:ok, view, html} = live(conn, "/tasks")

      refute html =~ "Create Task"

      html = render_click(view, "open_create_modal")
      assert html =~ "Create Task"
      assert html =~ "Title"
      assert html =~ "Description"
      assert html =~ "Priority"
    end

    test "close_create_modal event hides modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tasks")

      render_click(view, "open_create_modal")
      html = render_click(view, "close_create_modal")

      refute html =~ "Create Task"
    end

    test "create_task event creates a new task", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tasks")

      render_click(view, "open_create_modal")

      html =
        view
        |> form("form", %{title: "Brand New Task", description: "A description", priority: "3", agent_id: ""})
        |> render_submit()

      assert html =~ "Brand New Task"
      assert html =~ "Task created"
    end

    test "delete_task event removes a task", %{conn: conn} do
      task = create_task(%{title: "Deletable Task"})
      {:ok, view, html} = live(conn, "/tasks")
      assert html =~ "Deletable Task"

      html = render_click(view, "delete_task", %{"id" => to_string(task.id)})
      assert html =~ "Task deleted"
      refute html =~ "Deletable Task"
    end

    test "cancel_task event cancels a task", %{conn: conn} do
      task = create_task(%{title: "Cancellable Task", status: "pending"})
      {:ok, view, _html} = live(conn, "/tasks")

      html = render_click(view, "cancel_task", %{"id" => to_string(task.id)})
      assert html =~ "Task cancelled"
    end

    test "retry_task event queues task for retry", %{conn: conn} do
      task = create_task(%{title: "Failed Task", status: "failed"})
      {:ok, view, _html} = live(conn, "/tasks")

      html = render_click(view, "retry_task", %{"id" => to_string(task.id)})
      assert html =~ "Task queued for retry"
    end
  end
end
