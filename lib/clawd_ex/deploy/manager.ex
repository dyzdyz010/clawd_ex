defmodule ClawdEx.Deploy.Manager do
  @moduledoc """
  GenServer that manages deployment state and history.

  Persists deploy history to `~/.clawd/deploy/history.json`.
  Provides status, trigger, history, and rollback operations.
  """
  use GenServer

  require Logger

  @history_file "~/.clawd/deploy/history.json"
  @max_history 100
  @deploy_script "bin/deploy.sh"

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current deploy status"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Trigger a new deployment"
  def trigger do
    GenServer.call(__MODULE__, :trigger)
  end

  @doc "Get deployment history"
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc "Rollback to the previous version"
  def rollback do
    GenServer.call(__MODULE__, :rollback)
  end

  @doc "Record deploy result (called by async deploy task)"
  def record_result(deploy_id, exit_code, output) do
    GenServer.cast(__MODULE__, {:record_result, deploy_id, exit_code, output})
  end

  @doc "Reset deploy state (for testing only)"
  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    history = load_history()
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    state = %{
      history: history,
      started_at: started_at,
      current_deploy: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    git_sha = get_git_sha()
    version = get_version()
    last_deploy = List.first(state.history)

    status = %{
      version: version,
      git_sha: git_sha,
      started_at: state.started_at,
      uptime_seconds: get_uptime(),
      last_deploy_at: get_last_deploy_time(last_deploy),
      last_deploy_status: get_last_deploy_status(last_deploy),
      environment: get_environment(),
      current_deploy: state.current_deploy
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:reset_state, _from, state) do
    {:reply, :ok, %{state | current_deploy: nil}}
  end

  @impl true
  def handle_call(:trigger, _from, state) do
    if state.current_deploy do
      {:reply, {:error, :deploy_in_progress}, state}
    else
      deploy_id = System.system_time(:second) |> to_string()
      started_at = DateTime.utc_now() |> DateTime.to_iso8601()
      git_sha = get_git_sha()

      deploy_record = %{
        id: deploy_id,
        status: "running",
        started_at: started_at,
        completed_at: nil,
        git_sha: git_sha,
        version: get_version(),
        exit_code: nil,
        output: nil,
        trigger: "api"
      }

      # Start async deploy
      project_root = get_project_root()
      Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
        {output, exit_code} = System.cmd("bash", [@deploy_script],
          cd: project_root,
          stderr_to_stdout: true
        )
        record_result(deploy_id, exit_code, output)
      end)

      new_state = %{state | current_deploy: deploy_record}
      {:reply, {:ok, deploy_record}, new_state}
    end
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, {:ok, state.history}, state}
  end

  @impl true
  def handle_call(:rollback, _from, state) do
    if state.current_deploy do
      {:reply, {:error, :deploy_in_progress}, state}
    else
      deploy_id = System.system_time(:second) |> to_string()
      started_at = DateTime.utc_now() |> DateTime.to_iso8601()

      deploy_record = %{
        id: deploy_id,
        status: "running",
        started_at: started_at,
        completed_at: nil,
        git_sha: get_git_sha(),
        version: get_version(),
        exit_code: nil,
        output: nil,
        trigger: "rollback"
      }

      project_root = get_project_root()
      Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
        {output, exit_code} = System.cmd("bash", [@deploy_script, "--rollback"],
          cd: project_root,
          stderr_to_stdout: true
        )
        record_result(deploy_id, exit_code, output)
      end)

      new_state = %{state | current_deploy: deploy_record}
      {:reply, {:ok, deploy_record}, new_state}
    end
  end

  @impl true
  def handle_cast({:record_result, deploy_id, exit_code, output}, state) do
    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()
    status = if exit_code == 0, do: "success", else: "failed"

    # Truncate output to avoid huge history files
    truncated_output = String.slice(output || "", 0, 5000)

    completed_record = %{
      id: deploy_id,
      status: status,
      started_at: (state.current_deploy || %{})[:started_at] || completed_at,
      completed_at: completed_at,
      git_sha: (state.current_deploy || %{})[:git_sha] || "unknown",
      version: (state.current_deploy || %{})[:version] || "unknown",
      exit_code: exit_code,
      output: truncated_output,
      trigger: (state.current_deploy || %{})[:trigger] || "unknown"
    }

    # Prepend to history (newest first) and cap at max
    history = [completed_record | state.history] |> Enum.take(@max_history)

    # Persist to disk
    save_history(history)

    Logger.info("Deploy #{deploy_id} completed with status: #{status} (exit_code: #{exit_code})")

    new_state = %{state | history: history, current_deploy: nil}
    {:noreply, new_state}
  end

  # --- Private Helpers ---

  defp get_git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"],
           cd: get_project_root(),
           stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp get_version do
    case Application.spec(:clawd_ex, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  defp get_uptime do
    {wall_clock_ms, _} = :erlang.statistics(:wall_clock)
    div(wall_clock_ms, 1000)
  end

  defp get_environment do
    case Application.get_env(:clawd_ex, :env) do
      nil -> System.get_env("MIX_ENV") || "dev"
      env -> to_string(env)
    end
  end

  defp get_last_deploy_time(nil), do: nil
  defp get_last_deploy_time(%{completed_at: t}), do: t

  defp get_last_deploy_status(nil), do: nil
  defp get_last_deploy_status(%{status: s}), do: s

  defp get_project_root do
    # In release mode, app_dir points inside _build; go up to project root
    # In dev mode, use File.cwd!()
    cond do
      File.exists?(Path.join(File.cwd!(), "mix.exs")) ->
        File.cwd!()

      true ->
        app_dir = Application.app_dir(:clawd_ex)
        Path.join(app_dir, "../..") |> Path.expand()
    end
  end

  defp history_path do
    Path.expand(@history_file)
  end

  defp load_history do
    path = history_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) ->
            Enum.map(list, fn entry ->
              # Convert string keys to atom keys
              Map.new(entry, fn {k, v} -> {String.to_atom(k), v} end)
            end)

          _ ->
            Logger.warning("Invalid deploy history file, starting fresh")
            []
        end

      {:error, :enoent} ->
        # File doesn't exist yet — that's fine
        []

      {:error, reason} ->
        Logger.warning("Failed to read deploy history: #{inspect(reason)}")
        []
    end
  end

  defp save_history(history) do
    path = history_path()

    # Ensure directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    # Convert atom keys to string keys for JSON
    json_history = Enum.map(history, fn entry ->
      Map.new(entry, fn {k, v} -> {to_string(k), v} end)
    end)

    case Jason.encode(json_history, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.error("Failed to encode deploy history: #{inspect(reason)}")
    end
  end
end
