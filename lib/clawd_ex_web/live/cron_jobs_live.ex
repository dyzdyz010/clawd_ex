defmodule ClawdExWeb.CronJobsLive do
  use ClawdExWeb, :live_view

  alias ClawdEx.Automation

  @impl true
  def mount(_params, _session, socket) do
    jobs = Automation.list_jobs()
    stats = Automation.get_stats()

    {:ok,
     assign(socket,
       page_title: "Cron Jobs",
       jobs: jobs,
       stats: stats,
       filter: "all"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = Map.get(params, "filter", "all")
    jobs = load_jobs(filter)

    {:noreply, assign(socket, filter: filter, jobs: jobs)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    job = Automation.get_job(id)

    case Automation.toggle_job(job) do
      {:ok, _updated} ->
        jobs = load_jobs(socket.assigns.filter)
        stats = Automation.get_stats()
        {:noreply, assign(socket, jobs: jobs, stats: stats)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle job")}
    end
  end

  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    job = Automation.get_job(id)

    case Automation.run_job_now(job) do
      {:ok, _run} ->
        # 等待任务完成后刷新数据
        Process.sleep(200)
        jobs = load_jobs(socket.assigns.filter)
        stats = Automation.get_stats()

        {:noreply,
         socket
         |> put_flash(:info, "Job executed successfully")
         |> assign(jobs: jobs, stats: stats)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to run job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    job = Automation.get_job(id)

    case Automation.delete_job(job) do
      {:ok, _} ->
        jobs = load_jobs(socket.assigns.filter)
        stats = Automation.get_stats()
        {:noreply, assign(socket, jobs: jobs, stats: stats)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete job")}
    end
  end

  defp load_jobs("enabled"), do: Automation.list_jobs(enabled_only: true)
  defp load_jobs(_), do: Automation.list_jobs()
end
