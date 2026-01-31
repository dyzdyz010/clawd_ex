defmodule ClawdEx.Tools.Exec do
  @moduledoc """
  执行 Shell 命令工具

  支持:
  - 同步执行（默认）
  - 后台执行（background: true）
  - 超时后自动后台（yieldMs）
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.Tools.Process, as: ProcessTool

  @impl true
  def name, do: "exec"

  @impl true
  def description do
    "Execute shell commands. Use background=true or yieldMs for long-running commands. Returns stdout, stderr, and exit code."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description: "Shell command to execute"
        },
        workdir: %{
          type: "string",
          description: "Working directory (defaults to workspace)"
        },
        timeout: %{
          type: "integer",
          description: "Timeout in seconds (default 30, max 1800)"
        },
        yieldMs: %{
          type: "integer",
          description: "Milliseconds to wait before backgrounding (default 10000)"
        },
        background: %{
          type: "boolean",
          description: "Run in background immediately"
        },
        env: %{
          type: "object",
          description: "Environment variables to set"
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(params, context) do
    command = params["command"] || params[:command]
    workdir = params["workdir"] || params[:workdir] || context[:workspace] || "."
    timeout = min((params["timeout"] || params[:timeout] || 30) * 1000, 1_800_000)
    yield_ms = params["yieldMs"] || params[:yieldMs] || 10_000
    background = params["background"] || params[:background] || false
    env = params["env"] || params[:env] || %{}

    resolved_workdir = resolve_path(workdir)
    agent_id = context[:agent_id]

    Logger.debug("Executing command: #{command} in #{resolved_workdir}")

    # 构建环境变量
    env_list = Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    if background do
      # 立即后台执行
      run_background(command, resolved_workdir, env_list, agent_id)
    else
      # 同步执行，可能转为后台
      run_sync_or_yield(command, resolved_workdir, env_list, timeout, yield_ms, agent_id)
    end
  end

  defp run_sync_or_yield(command, workdir, env, timeout, yield_ms, agent_id) do
    task =
      Task.async(fn ->
        try do
          {output, exit_code} =
            System.cmd(
              "sh",
              ["-c", command],
              cd: workdir,
              env: env,
              stderr_to_stdout: true
            )

          {:ok, output, exit_code}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    # 使用较小的等待时间：min(timeout, yield_ms)
    # 如果 timeout 比 yield_ms 小，我们应该遵守 timeout
    wait_time = min(timeout, yield_ms)

    case Task.yield(task, wait_time) do
      {:ok, {:ok, output, exit_code}} ->
        if exit_code == 0 do
          {:ok, output}
        else
          {:error, "Command exited with code #{exit_code}\n\n#{output}"}
        end

      {:ok, {:error, reason}} ->
        {:error, "Failed to execute command: #{reason}"}

      nil ->
        # 检查是否是因为 timeout 还是 yield_ms
        if wait_time >= timeout do
          # 超时了，终止任务
          Task.shutdown(task, :brutal_kill)
          {:error, "Command timed out after #{div(timeout, 1000)} seconds"}
        else
          # 超过 yield_ms 但还没到 timeout，转为后台
          Logger.info("Command running longer than #{yield_ms}ms, backgrounding...")

          session_id = generate_session_id()

          # 启动后台监控
          spawn(fn ->
            monitor_background_task(task, agent_id, session_id, command, timeout - yield_ms)
          end)

          {:ok,
           %{
             status: "running",
             sessionId: session_id,
             message: "Command still running. Use process tool to check status."
           }}
        end
    end
  end

  defp run_background(command, workdir, env, agent_id) do
    session_id = generate_session_id()

    # 使用 Port 启动后台进程
    port =
      Port.open(
        {:spawn, "sh -c '#{escape_command(command)}'"},
        [:binary, :exit_status, :stderr_to_stdout, {:cd, workdir}, {:env, env}]
      )

    # 注册到 ProcessTool
    ProcessTool.register_process(agent_id, session_id, port, command)

    # 启动监控进程
    spawn(fn -> monitor_port(port, agent_id, session_id) end)

    {:ok,
     %{
       status: "running",
       sessionId: session_id,
       message: "Command started in background. Use process tool to check status."
     }}
  end

  defp monitor_background_task(task, agent_id, session_id, command, remaining_timeout) do
    # 注册（没有 port，因为用的是 Task）
    ProcessTool.register_process(agent_id, session_id, nil, command)

    case Task.yield(task, remaining_timeout) || Task.shutdown(task) do
      {:ok, {:ok, output, exit_code}} ->
        ProcessTool.append_output(agent_id, session_id, output)
        ProcessTool.mark_completed(agent_id, session_id, exit_code)

      {:ok, {:error, reason}} ->
        ProcessTool.append_output(agent_id, session_id, "Error: #{reason}")
        ProcessTool.mark_completed(agent_id, session_id, 1)

      nil ->
        ProcessTool.append_output(agent_id, session_id, "Process timed out")
        ProcessTool.mark_completed(agent_id, session_id, :timeout)
    end
  end

  defp monitor_port(port, agent_id, session_id) do
    receive do
      {^port, {:data, data}} ->
        ProcessTool.append_output(agent_id, session_id, data)
        monitor_port(port, agent_id, session_id)

      {^port, {:exit_status, status}} ->
        ProcessTool.mark_completed(agent_id, session_id, status)

      {:EXIT, ^port, reason} ->
        ProcessTool.mark_completed(agent_id, session_id, {:exit, reason})
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp escape_command(command) do
    String.replace(command, "'", "'\\''")
  end

  defp resolve_path(path) do
    cond do
      String.starts_with?(path, "/") -> path
      String.starts_with?(path, "~") -> Path.expand(path)
      true -> Path.expand(path)
    end
  end
end
