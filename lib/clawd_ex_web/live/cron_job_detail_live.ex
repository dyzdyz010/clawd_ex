defmodule ClawdExWeb.CronJobDetailLive do
  use ClawdExWeb, :live_view

  alias ClawdEx.Automation

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    job = Automation.get_job_with_runs(id, 50)

    if job do
      {:ok,
       assign(socket,
         page_title: job.name,
         job: job,
         runs: job.runs
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Job not found")
       |> push_navigate(to: ~p"/cron")}
    end
  end

  @impl true
  def handle_event("run_now", _params, socket) do
    case Automation.run_job_now(socket.assigns.job) do
      {:ok, _run} ->
        # 等待任务完成后刷新数据
        Process.sleep(200)
        # Reload job and runs
        job = Automation.get_job_with_runs(socket.assigns.job.id, 50)

        {:noreply,
         socket
         |> put_flash(:info, "Job executed successfully")
         |> assign(job: job, runs: job.runs)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to run job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    case Automation.toggle_job(socket.assigns.job) do
      {:ok, updated_job} ->
        {:noreply, assign(socket, job: %{updated_job | runs: socket.assigns.runs})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle job")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Automation.delete_job(socket.assigns.job) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job deleted")
         |> push_navigate(to: ~p"/cron")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete job")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-start justify-between">
        <div>
          <.link navigate={~p"/cron"} class="text-gray-400 hover:text-white text-sm flex items-center gap-1 mb-2">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
            </svg>
            Back to Cron Jobs
          </.link>
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold text-white"><%= @job.name %></h1>
            <.status_badge enabled={@job.enabled} />
          </div>
          <%= if @job.description do %>
            <p class="text-gray-400 mt-1"><%= @job.description %></p>
          <% end %>
        </div>

        <div class="flex items-center gap-2">
          <button phx-click="run_now" class="btn-primary">
            <svg class="w-4 h-4 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
            </svg>
            Run Now
          </button>
          <button
            phx-click="toggle"
            class={if @job.enabled, do: "btn-secondary text-yellow-400", else: "btn-secondary text-green-400"}
          >
            <%= if @job.enabled, do: "Disable", else: "Enable" %>
          </button>
          <.link navigate={~p"/cron/#{@job.id}/edit"} class="btn-secondary">
            Edit
          </.link>
          <button
            phx-click="delete"
            data-confirm="Are you sure you want to delete this job?"
            class="btn-secondary text-red-400"
          >
            Delete
          </button>
        </div>
      </div>

      <!-- Job Info -->
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="bg-gray-800 rounded-lg p-6">
          <h3 class="text-lg font-medium text-white mb-4">Configuration</h3>
          <dl class="space-y-4">
            <div>
              <dt class="text-sm text-gray-400">Schedule</dt>
              <dd class="mt-1">
                <code class="text-lg text-white bg-gray-700 px-3 py-1 rounded font-mono">
                  <%= @job.schedule %>
                </code>
              </dd>
            </div>
            <div>
              <dt class="text-sm text-gray-400">Timezone</dt>
              <dd class="text-white"><%= @job.timezone %></dd>
            </div>
            <div>
              <dt class="text-sm text-gray-400">Agent</dt>
              <dd class="text-white"><%= @job.agent_id || "None" %></dd>
            </div>
          </dl>
        </div>

        <div class="bg-gray-800 rounded-lg p-6">
          <h3 class="text-lg font-medium text-white mb-4">Statistics</h3>
          <dl class="space-y-4">
            <div>
              <dt class="text-sm text-gray-400">Total Runs</dt>
              <dd class="text-2xl font-bold text-white"><%= @job.run_count %></dd>
            </div>
            <div>
              <dt class="text-sm text-gray-400">Last Run</dt>
              <dd class="text-white"><%= format_datetime(@job.last_run_at) %></dd>
            </div>
            <div>
              <dt class="text-sm text-gray-400">Next Run</dt>
              <dd class="text-white"><%= format_datetime(@job.next_run_at) %></dd>
            </div>
          </dl>
        </div>
      </div>

      <!-- Command -->
      <div class="bg-gray-800 rounded-lg p-6">
        <h3 class="text-lg font-medium text-white mb-4">Command</h3>
        <pre class="bg-gray-900 rounded-lg p-4 overflow-x-auto text-sm text-gray-300"><%= @job.command %></pre>
      </div>

      <!-- Run History -->
      <div class="bg-gray-800 rounded-lg overflow-hidden">
        <div class="px-6 py-4 border-b border-gray-700">
          <h3 class="text-lg font-medium text-white">Run History</h3>
        </div>

        <%= if Enum.empty?(@runs) do %>
          <div class="p-8 text-center text-gray-400">
            <p>No runs yet</p>
            <button phx-click="run_now" class="text-blue-400 hover:underline mt-2">
              Run this job now
            </button>
          </div>
        <% else %>
          <table class="w-full">
            <thead class="bg-gray-700/50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Started</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Duration</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Status</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Output</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700">
              <%= for run <- @runs do %>
                <tr class="hover:bg-gray-700/30">
                  <td class="px-4 py-3 text-sm text-gray-300">
                    <%= format_datetime(run.started_at) %>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-400">
                    <%= format_duration(run.duration_ms) %>
                  </td>
                  <td class="px-4 py-3">
                    <.run_status_badge status={run.status} />
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-400">
                    <%= if run.error do %>
                      <span class="text-red-400 truncate block max-w-xs" title={run.error}>
                        <%= String.slice(run.error || "", 0, 50) %>...
                      </span>
                    <% else %>
                      <span class="truncate block max-w-xs" title={run.output}>
                        <%= String.slice(run.output || "", 0, 50) %>
                      </span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    {text, classes} =
      if assigns.enabled do
        {"Enabled", "bg-green-500/20 text-green-400"}
      else
        {"Disabled", "bg-gray-500/20 text-gray-400"}
      end

    assigns = assign(assigns, text: text, classes: classes)

    ~H"""
    <span class={"px-2 py-1 rounded text-xs font-medium #{@classes}"}>
      <%= @text %>
    </span>
    """
  end

  defp run_status_badge(assigns) do
    {text, classes} =
      case assigns.status do
        "completed" -> {"Completed", "bg-green-500/20 text-green-400"}
        "running" -> {"Running", "bg-blue-500/20 text-blue-400"}
        "failed" -> {"Failed", "bg-red-500/20 text-red-400"}
        "timeout" -> {"Timeout", "bg-yellow-500/20 text-yellow-400"}
        _ -> {assigns.status, "bg-gray-500/20 text-gray-400"}
      end

    assigns = assign(assigns, text: text, classes: classes)

    ~H"""
    <span class={"px-2 py-1 rounded text-xs font-medium #{@classes}"}>
      <%= @text %>
    </span>
    """
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_duration(nil), do: "-"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"
end
