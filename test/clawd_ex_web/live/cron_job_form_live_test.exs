defmodule ClawdExWeb.CronJobFormLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  defp create_agent(attrs \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(%{name: "test-agent-#{System.unique_integer([:positive])}"}, attrs))
      |> Repo.insert()

    agent
  end

  test "renders new cron job form with key elements", %{conn: conn} do
    create_agent(%{name: "cron-form-agent"})

    {:ok, _view, html} = live(conn, "/cron/new")

    assert html =~ "New Cron Job"
    assert html =~ "Name"
    assert html =~ "Schedule"
    assert html =~ "Cron Expression"
    assert html =~ "Command"
    assert html =~ "Agent"
    assert html =~ "Timezone"
    assert html =~ "Enabled"
    assert html =~ "Cron Expression Help"
    assert html =~ "Back to Cron Jobs"
    assert html =~ "cron-form-agent"
  end

  test "validate does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cron/new")

    html =
      view
      |> form("form", cron_job: %{name: "test-job", schedule: "0 9 * * *", command: "echo hi"})
      |> render_change()

    assert html =~ "New Cron Job"
  end

  test "save creates a new cron job with valid data", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cron/new")

    view
    |> form("form", cron_job: %{name: "my-new-job", schedule: "0 9 * * *", command: "echo hello"})
    |> render_submit()

    assert_redirect(view, "/cron")
  end
end
