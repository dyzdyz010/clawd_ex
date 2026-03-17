defmodule ClawdExWeb.TaskDetailLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Tasks.Task

  defp create_agent(attrs \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(%{name: "test-agent-#{System.unique_integer([:positive])}"}, attrs))
      |> Repo.insert()

    agent
  end

  defp create_task(agent, attrs \\ %{}) do
    {:ok, task} =
      %Task{}
      |> Task.changeset(
        Map.merge(
          %{
            title: "Test Task #{System.unique_integer([:positive])}",
            description: "A test task",
            status: "pending",
            priority: 5,
            agent_id: agent.id
          },
          attrs
        )
      )
      |> Repo.insert()

    task
  end

  describe "mount" do
    test "renders task detail page", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{title: "My Test Task"})

      {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

      assert html =~ "My Test Task"
    end

    test "displays task status", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{title: "Status Task", status: "pending"})

      {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

      assert html =~ "Pending"
    end

    test "displays task priority", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{title: "Priority Task", priority: 3})

      {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

      assert html =~ "P3"
    end

    test "displays task description", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{title: "Desc Task", description: "Detailed description here"})

      {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

      assert html =~ "Detailed description here"
    end

    test "shows action buttons for pending task", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{status: "pending"})

      {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

      assert html =~ "Start"
    end

    test "shows back link", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent)

      {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

      assert html =~ "Back"
    end
  end

  describe "events" do
    test "start_task does not crash for pending task", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{status: "pending"})

      {:ok, view, _html} = live(conn, "/tasks/#{task.id}")

      # start_task calls TaskManager which may interact with sessions
      # The event itself should not crash the LiveView
      view |> render_click("start_task")

      html = render(view)
      # It should still show the task page (may show error flash or status change)
      assert html =~ task.title
    end

    test "cancel_task does not crash", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{status: "running", started_at: DateTime.utc_now()})

      {:ok, view, _html} = live(conn, "/tasks/#{task.id}")

      view |> render_click("cancel_task")

      html = render(view)
      assert html =~ task.title
    end

    test "retry_task does not crash", %{conn: conn} do
      agent = create_agent()
      task = create_task(agent, %{status: "failed"})

      {:ok, view, _html} = live(conn, "/tasks/#{task.id}")

      view |> render_click("retry_task")

      html = render(view)
      assert html =~ task.title
    end
  end
end
