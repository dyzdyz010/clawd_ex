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

  test "renders cron job detail with key sections", %{conn: conn} do
    job = create_cron_job(%{name: "my-detail-job", schedule: "*/15 * * * *", command: "echo test-command"})

    {:ok, _view, html} = live(conn, "/cron/#{job.id}")

    assert html =~ "my-detail-job"
    assert html =~ "Configuration"
    assert html =~ "*/15 * * * *"
    assert html =~ "Statistics"
    assert html =~ "Total Runs"
    assert html =~ "Command"
    assert html =~ "echo test-command"
    assert html =~ "Run History"
    assert html =~ "No runs yet"
    assert html =~ "Back to Cron Jobs"
    assert html =~ "Enabled"
    assert html =~ "Run Now"
    assert html =~ "Edit"
    assert html =~ "Delete"
  end

  test "redirects when job not found", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/cron"}}} = live(conn, "/cron/#{Ecto.UUID.generate()}")
  end

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
