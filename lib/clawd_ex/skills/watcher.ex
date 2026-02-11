defmodule ClawdEx.Skills.Watcher do
  @moduledoc """
  Watches skill directories for changes and triggers Registry refresh.

  Uses FileSystem to monitor directories, with debounce to avoid
  excessive refreshes on rapid file changes.
  """

  use GenServer

  require Logger

  alias ClawdEx.Skills.{Loader, Registry}

  @debounce_ms 1_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc "Start the Skills Watcher."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    dirs =
      opts
      |> Loader.skill_dirs()
      |> Enum.map(fn {dir, _source} -> dir end)

    if dirs != [] do
      {:ok, watcher_pid} = FileSystem.start_link(dirs: dirs)
      FileSystem.subscribe(watcher_pid)
      {:ok, %{watcher_pid: watcher_pid, debounce_ref: nil, opts: opts}}
    else
      Logger.debug("Skills Watcher: no directories to watch")
      {:ok, %{watcher_pid: nil, debounce_ref: nil, opts: opts}}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {_path, _events}}, state) do
    # Debounce: cancel previous timer, start new one
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    ref = Process.send_after(self(), :do_refresh, @debounce_ms)
    {:noreply, %{state | debounce_ref: ref}}
  end

  @impl true
  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("Skills Watcher: file system monitor stopped")
    {:noreply, state}
  end

  @impl true
  def handle_info(:do_refresh, state) do
    Logger.debug("Skills Watcher: refreshing registry")
    Registry.refresh()
    {:noreply, %{state | debounce_ref: nil}}
  end
end
