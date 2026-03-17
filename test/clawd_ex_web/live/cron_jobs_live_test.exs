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

  describe "mount" do
    test "renders cron jobs page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron")

      assert html =~ "Cron Jobs"
      assert html =~ "Manage scheduled tasks"
    end

    test "shows empty state when no jobs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron")

      assert html =~ "No cron jobs yet"
      assert html =~ "Create your first job"
    end

    test "contains key UI elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cron")

      # Title
      assert html =~ "Cron Jobs"
      # Create link
      assert html =~ "New Job"
      # Stats
      assert html =~ "Total Jobs"
      assert html =~ "Enabled"
      assert html =~ "Disabled"
      assert html =~ "Total Runs"
      assert html =~ "Failed Runs"
      # Filters
      assert html =~ "All"
      assert html =~ "Enabled Only"
    end

    test "renders jobs when they exist", %{conn: conn} do
      create_job(%{name: "My Cron Job", schedule: "*/5 * * * *"})
      {:ok, _view, html} = live(conn, "/cron")

      assert html =~ "My Cron Job"
      assert html =~ "*/5 * * * *"
      refute html =~ "No cron jobs yet"
    end
  end

  describe "events" do
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

    test "handle_params with filter does not crash", %{conn: conn} do
      create_job(%{enabled: true})
      create_job(%{enabled: false})

      {:ok, _view, html} = live(conn, "/cron?filter=enabled")
      assert html =~ "Cron Jobs"

      {:ok, _view, html} = live(conn, "/cron?filter=all")
      assert html =~ "Cron Jobs"
    end

    test "run_now event does not crash", %{conn: conn} do
      job = create_job(%{name: "Runnable Job"})
      {:ok, view, _html} = live(conn, "/cron")

      # run_now will try to execute; it may fail due to missing agent config
      # but the event handler should not crash the LiveView
      html = render_click(view, "run_now", %{"id" => job.id})
      assert html =~ "Cron Jobs"
    end
  end
end
