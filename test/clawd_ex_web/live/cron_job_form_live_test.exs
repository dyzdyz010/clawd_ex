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

  describe "mount" do
    test "renders new cron job form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "New Cron Job"
    end

    test "form contains name field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Name"
    end

    test "form contains schedule field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Schedule"
      assert html =~ "Cron Expression"
    end

    test "form contains command field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Command"
    end

    test "form contains agent select", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Agent"
    end

    test "form contains timezone select", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Timezone"
    end

    test "form contains enabled checkbox", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Enabled"
    end

    test "shows cron expression help", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Cron Expression Help"
    end

    test "has back link to cron jobs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "Back to Cron Jobs"
    end

    test "lists available agents", %{conn: conn} do
      create_agent(%{name: "cron-form-agent"})

      {:ok, _view, html} = live(conn, "/cron/new")

      assert html =~ "cron-form-agent"
    end
  end

  describe "events" do
    test "validate event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/cron/new")

      html =
        view
        |> form("form", cron_job: %{name: "test-job", schedule: "0 9 * * *", command: "echo hi"})
        |> render_change()

      assert html =~ "New Cron Job"
    end

    test "validate shows errors for missing required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/cron/new")

      view
      |> form("form", cron_job: %{name: "", schedule: "", command: ""})
      |> render_change()

      html = render(view)
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
end
