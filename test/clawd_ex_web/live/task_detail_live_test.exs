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
          %{title: "Test Task #{System.unique_integer([:positive])}", description: "A test task",
            status: "pending", priority: 5, agent_id: agent.id},
          attrs
        )
      )
      |> Repo.insert()

    task
  end

  test "renders task detail with key sections", %{conn: conn} do
    agent = create_agent()
    task = create_task(agent, %{title: "My Test Task", description: "Detailed description here", status: "pending", priority: 3})

    {:ok, _view, html} = live(conn, "/tasks/#{task.id}")

    assert html =~ "My Test Task"
    assert html =~ "Pending"
    assert html =~ "P3"
    assert html =~ "Detailed description here"
    assert html =~ "Start"
    assert html =~ "Back"
  end

  test "task action events do not crash", %{conn: conn} do
    agent = create_agent()

    # Test start
    task = create_task(agent, %{status: "pending"})
    {:ok, view, _html} = live(conn, "/tasks/#{task.id}")
    view |> render_click("start_task")
    assert render(view) =~ task.title

    # Test cancel
    task2 = create_task(agent, %{status: "running", started_at: DateTime.utc_now()})
    {:ok, view2, _html} = live(conn, "/tasks/#{task2.id}")
    view2 |> render_click("cancel_task")
    assert render(view2) =~ task2.title

    # Test retry
    task3 = create_task(agent, %{status: "failed"})
    {:ok, view3, _html} = live(conn, "/tasks/#{task3.id}")
    view3 |> render_click("retry_task")
    assert render(view3) =~ task3.title
  end
end
