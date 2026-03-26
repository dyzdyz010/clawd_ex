defmodule ClawdExWeb.CronJobsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Automation.CronJob

  defp create_job(attrs \\ %{}) do
    defaults = %{
      name: "test-job-#{System.unique_integer([:positive])}",
      schedule: "0 * * * *",
      command: "echo hello",
      enabled: true
    }

    {:ok, job} =
      %CronJob{}
      |> CronJob.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    job
  end

  test "renders cron jobs page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/cron")

    assert html =~ "Cron Jobs"
    assert html =~ "Manage scheduled tasks"
    assert html =~ "No Cron Jobs"
    assert html =~ "New Job"
    assert html =~ "Total Jobs"
    assert html =~ "Enabled"
    assert html =~ "Disabled"
  end

  test "renders jobs when they exist", %{conn: conn} do
    create_job(%{name: "My Cron Job", schedule: "*/5 * * * *"})
    {:ok, _view, html} = live(conn, "/cron")

    assert html =~ "My Cron Job"
    assert html =~ "*/5 * * * *"
    refute html =~ "No Cron Jobs"
  end

  test "toggle event toggles job enabled state", %{conn: conn} do
    job = create_job(%{enabled: true})
    {:ok, view, _html} = live(conn, "/cron")

    render_click(view, "toggle", %{"id" => job.id})

    updated = Repo.get!(CronJob, job.id)
    refute updated.enabled
  end

  test "delete event removes a job", %{conn: conn} do
    job = create_job(%{name: "Deletable Job"})
    {:ok, view, html} = live(conn, "/cron")
    assert html =~ "Deletable Job"

    html = render_click(view, "delete", %{"id" => job.id})
    refute html =~ "Deletable Job"
  end

  test "run_now event does not crash", %{conn: conn} do
    job = create_job(%{name: "Runnable Job"})
    {:ok, view, _html} = live(conn, "/cron")

    html = render_click(view, "run_now", %{"id" => job.id})
    assert html =~ "Cron Jobs"
  end
end
