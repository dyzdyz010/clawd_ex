defmodule ClawdExWeb.CronJobDetailLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Automation.CronJob

  defp create_cron_job(attrs \\ %{}) do
    {:ok, job} =
      %CronJob{}
      |> CronJob.changeset(
        Map.merge(
          %{
            name: "test-job-#{System.unique_integer([:positive])}",
            schedule: "0 9 * * *",
            command: "echo hello",
            enabled: true,
            timezone: "UTC"
          },
          attrs
        )
      )
      |> Repo.insert()

    job
  end

  describe "mount" do
    test "renders cron job detail page", %{conn: conn} do
      job = create_cron_job(%{name: "my-detail-job"})

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "my-detail-job"
    end

    test "displays job configuration", %{conn: conn} do
      job = create_cron_job(%{name: "config-job", schedule: "*/15 * * * *"})

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Configuration"
      assert html =~ "*/15 * * * *"
    end

    test "displays statistics section", %{conn: conn} do
      job = create_cron_job()

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Statistics"
      assert html =~ "Total Runs"
    end

    test "displays command section", %{conn: conn} do
      job = create_cron_job(%{command: "echo test-command"})

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Command"
      assert html =~ "echo test-command"
    end

    test "displays run history section", %{conn: conn} do
      job = create_cron_job()

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Run History"
    end

    test "shows empty run history when no runs", %{conn: conn} do
      job = create_cron_job()

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "No runs yet"
    end

    test "has back link", %{conn: conn} do
      job = create_cron_job()

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Back to Cron Jobs"
    end

    test "shows enabled status badge", %{conn: conn} do
      job = create_cron_job(%{enabled: true})

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Enabled"
    end

    test "shows action buttons", %{conn: conn} do
      job = create_cron_job()

      {:ok, _view, html} = live(conn, "/cron/#{job.id}")

      assert html =~ "Run Now"
      assert html =~ "Edit"
      assert html =~ "Delete"
    end

    test "redirects when job not found", %{conn: conn} do
      # Use a valid UUID that doesn't exist
      assert {:error, {:live_redirect, %{to: "/cron"}}} = live(conn, "/cron/#{Ecto.UUID.generate()}")
    end
  end

  describe "events" do
    test "toggle event does not crash", %{conn: conn} do
      job = create_cron_job(%{enabled: true})

      {:ok, view, _html} = live(conn, "/cron/#{job.id}")

      view |> render_click("toggle")

      html = render(view)
      assert html =~ job.name
    end

    test "delete event redirects to cron list", %{conn: conn} do
      job = create_cron_job()

      {:ok, view, _html} = live(conn, "/cron/#{job.id}")

      view |> render_click("delete")

      assert_redirect(view, "/cron")
    end
  end
end
