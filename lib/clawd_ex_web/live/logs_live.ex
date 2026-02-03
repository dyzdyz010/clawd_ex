defmodule ClawdExWeb.LogsLive do
  use ClawdExWeb, :live_view

  @log_dir "priv/logs"
  @default_lines 200

  @impl true
  def mount(_params, _session, socket) do
    # Ensure log directory exists
    File.mkdir_p!(@log_dir)

    log_files = list_log_files()

    {:ok,
     assign(socket,
       page_title: "Logs",
       log_files: log_files,
       selected_file: nil,
       log_content: [],
       filter: "",
       level: "all",
       auto_refresh: false,
       lines: @default_lines
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    file = Map.get(params, "file")
    level = Map.get(params, "level", "all")
    filter = Map.get(params, "filter", "")

    socket =
      socket
      |> assign(selected_file: file, level: level, filter: filter)
      |> load_logs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_file", %{"file" => file}, socket) do
    {:noreply, push_patch(socket, to: ~p"/logs?file=#{file}")}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    params = build_params(socket.assigns.selected_file, socket.assigns.level, filter)
    {:noreply, push_patch(socket, to: "/logs?" <> URI.encode_query(params))}
  end

  @impl true
  def handle_event("set_level", %{"level" => level}, socket) do
    params = build_params(socket.assigns.selected_file, level, socket.assigns.filter)
    {:noreply, push_patch(socket, to: "/logs?" <> URI.encode_query(params))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_logs(socket)}
  end

  @impl true
  def handle_event("toggle_auto_refresh", _params, socket) do
    auto_refresh = !socket.assigns.auto_refresh

    socket =
      if auto_refresh do
        :timer.send_interval(5000, self(), :auto_refresh)
        assign(socket, auto_refresh: true)
      else
        assign(socket, auto_refresh: false)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_logs", _params, socket) do
    if socket.assigns.selected_file do
      path = Path.join(@log_dir, socket.assigns.selected_file)
      File.write!(path, "")
    end

    {:noreply, load_logs(socket)}
  end

  @impl true
  def handle_info(:auto_refresh, socket) do
    if socket.assigns.auto_refresh do
      {:noreply, load_logs(socket)}
    else
      {:noreply, socket}
    end
  end

  defp load_logs(socket) do
    case socket.assigns.selected_file do
      nil ->
        assign(socket, log_content: [])

      file ->
        path = Path.join(@log_dir, file)

        content =
          if File.exists?(path) do
            path
            |> File.read!()
            |> String.split("\n")
            |> Enum.take(-socket.assigns.lines)
            |> filter_logs(socket.assigns.level, socket.assigns.filter)
            |> Enum.map(&parse_log_line/1)
          else
            []
          end

        assign(socket, log_content: content, log_files: list_log_files())
    end
  end

  defp filter_logs(lines, level, filter) do
    lines
    |> filter_by_level(level)
    |> filter_by_text(filter)
  end

  defp filter_by_level(lines, "all"), do: lines

  defp filter_by_level(lines, level) do
    level_pattern = "[#{String.upcase(level)}]"
    Enum.filter(lines, &String.contains?(&1, level_pattern))
  end

  defp filter_by_text(lines, ""), do: lines

  defp filter_by_text(lines, filter) do
    filter_lower = String.downcase(filter)
    Enum.filter(lines, &String.contains?(String.downcase(&1), filter_lower))
  end

  defp parse_log_line(line) do
    cond do
      String.contains?(line, "[ERROR]") || String.contains?(line, "[error]") ->
        %{text: line, level: :error}

      String.contains?(line, "[WARN]") || String.contains?(line, "[warn]") ->
        %{text: line, level: :warn}

      String.contains?(line, "[INFO]") || String.contains?(line, "[info]") ->
        %{text: line, level: :info}

      String.contains?(line, "[DEBUG]") || String.contains?(line, "[debug]") ->
        %{text: line, level: :debug}

      true ->
        %{text: line, level: :default}
    end
  end

  defp list_log_files do
    case File.ls(@log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  defp build_params(file, level, filter) do
    params = %{}
    params = if file, do: Map.put(params, "file", file), else: params
    params = if level != "all", do: Map.put(params, "level", level), else: params
    params = if filter != "", do: Map.put(params, "filter", filter), else: params
    params
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-white">Logs</h1>
          <p class="text-gray-400 text-sm mt-1">View application logs</p>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="toggle_auto_refresh"
            class={if @auto_refresh, do: "btn-primary", else: "btn-secondary"}
          >
            <svg class="w-4 h-4 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
            </svg>
            <%= if @auto_refresh, do: "Auto: ON", else: "Auto: OFF" %>
          </button>
          <button phx-click="refresh" class="btn-secondary">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
            </svg>
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
        <!-- File List -->
        <div class="lg:col-span-1">
          <div class="bg-gray-800 rounded-lg p-4">
            <h3 class="text-sm font-medium text-gray-400 mb-3">Log Files</h3>
            <%= if Enum.empty?(@log_files) do %>
              <p class="text-gray-500 text-sm">No log files found</p>
              <p class="text-gray-600 text-xs mt-2">Logs will appear in priv/logs/</p>
            <% else %>
              <ul class="space-y-1">
                <%= for file <- @log_files do %>
                  <li>
                    <button
                      phx-click="select_file"
                      phx-value-file={file}
                      class={"w-full text-left px-3 py-2 rounded text-sm #{if @selected_file == file, do: "bg-blue-600 text-white", else: "text-gray-300 hover:bg-gray-700"}"}
                    >
                      <%= file %>
                    </button>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </div>
        </div>

        <!-- Log Viewer -->
        <div class="lg:col-span-3">
          <div class="bg-gray-800 rounded-lg overflow-hidden">
            <!-- Filters -->
            <div class="px-4 py-3 border-b border-gray-700 flex items-center gap-4">
              <div class="flex items-center gap-2">
                <label class="text-sm text-gray-400">Level:</label>
                <select
                  phx-change="set_level"
                  name="level"
                  class="bg-gray-700 border-gray-600 text-white text-sm rounded px-2 py-1"
                >
                  <%= for level <- ["all", "error", "warn", "info", "debug"] do %>
                    <option value={level} selected={@level == level}>
                      <%= String.capitalize(level) %>
                    </option>
                  <% end %>
                </select>
              </div>

              <div class="flex-1">
                <form phx-change="filter" phx-submit="filter">
                  <input
                    type="text"
                    name="filter"
                    value={@filter}
                    placeholder="Filter logs..."
                    class="w-full bg-gray-700 border-gray-600 text-white text-sm rounded px-3 py-1"
                  />
                </form>
              </div>

              <%= if @selected_file do %>
                <button
                  phx-click="clear_logs"
                  data-confirm="Are you sure you want to clear this log file?"
                  class="text-red-400 hover:text-red-300 text-sm"
                >
                  Clear
                </button>
              <% end %>
            </div>

            <!-- Log Content -->
            <div class="h-[600px] overflow-auto p-4 font-mono text-sm">
              <%= if @selected_file == nil do %>
                <div class="text-gray-500 text-center py-8">
                  Select a log file to view
                </div>
              <% else %>
                <%= if Enum.empty?(@log_content) do %>
                  <div class="text-gray-500 text-center py-8">
                    No log entries found
                  </div>
                <% else %>
                  <div class="space-y-0.5">
                    <%= for entry <- @log_content do %>
                      <div class={"py-0.5 #{log_level_class(entry.level)}"}>
                        <%= entry.text %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp log_level_class(:error), do: "text-red-400"
  defp log_level_class(:warn), do: "text-yellow-400"
  defp log_level_class(:info), do: "text-blue-400"
  defp log_level_class(:debug), do: "text-gray-500"
  defp log_level_class(_), do: "text-gray-300"
end
