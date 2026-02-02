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
    # 使用 Port 运行命令，这样可以实时获取输出
    port =
      Port.open(
        {:spawn, "sh -c '#{escape_command(command)}'"},
        [:binary, :exit_status, :stderr_to_stdout, {:cd, workdir}, {:env, env}]
      )

    # 收集输出，最多等待 yield_ms
    wait_time = min(timeout, yield_ms)
    deadline = System.monotonic_time(:millisecond) + wait_time
    
    collect_port_output(port, "", deadline, timeout, yield_ms, agent_id, command)
  end
  
  defp collect_port_output(port, output, deadline, timeout, yield_ms, agent_id, command) do
    remaining = deadline - System.monotonic_time(:millisecond)
    
    if remaining <= 0 do
      # 超过 yield_ms，检查是否应该后台化或超时
      if yield_ms >= timeout do
        # 总 timeout 已到，杀死进程
        Port.close(port)
        {:error, "Command timed out after #{div(timeout, 1000)} seconds\n\n#{output}"}
      else
        # 转为后台模式
        Logger.info("Command running longer than #{yield_ms}ms, backgrounding...")
        
        session_id = generate_session_id()
        remaining_timeout = timeout - yield_ms
        
        # 注册进程并保存已有输出
        ProcessTool.register_process(agent_id, session_id, port, command)
        if output != "", do: ProcessTool.append_output(agent_id, session_id, output)
        
        # 启动后台监控，并转移 Port 控制权
        monitor_pid = spawn(fn -> 
          receive do
            :start -> monitor_port_with_timeout(port, agent_id, session_id, remaining_timeout)
          end
        end)
        
        # 转移 Port 控制权给监控进程
        Port.connect(port, monitor_pid)
        send(monitor_pid, :start)
        
        {:ok,
         %{
           status: "running",
           sessionId: session_id,
           message: "Command still running. Use process tool to check status."
         }}
      end
    else
      receive do
        {^port, {:data, data}} ->
          collect_port_output(port, output <> data, deadline, timeout, yield_ms, agent_id, command)
          
        {^port, {:exit_status, exit_code}} ->
          if exit_code == 0 do
            {:ok, output}
          else
            {:error, "Command exited with code #{exit_code}\n\n#{output}"}
          end
      after
        remaining ->
          # 超时，重新检查
          collect_port_output(port, output, deadline, timeout, yield_ms, agent_id, command)
      end
    end
  end
  
  defp monitor_port_with_timeout(port, agent_id, session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_monitor_port(port, agent_id, session_id, deadline)
  end
  
  defp do_monitor_port(port, agent_id, session_id, :infinity) do
    receive do
      {^port, {:data, data}} ->
        ProcessTool.append_output(agent_id, session_id, data)
        do_monitor_port(port, agent_id, session_id, :infinity)
        
      {^port, {:exit_status, status}} ->
        ProcessTool.mark_completed(agent_id, session_id, status)
        
      {:EXIT, ^port, reason} ->
        ProcessTool.mark_completed(agent_id, session_id, {:exit, reason})
    end
  end
  
  defp do_monitor_port(port, agent_id, session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    
    if remaining <= 0 do
      Port.close(port)
      ProcessTool.append_output(agent_id, session_id, "\n[Process timed out]")
      ProcessTool.mark_completed(agent_id, session_id, :timeout)
    else
      receive do
        {^port, {:data, data}} ->
          ProcessTool.append_output(agent_id, session_id, data)
          do_monitor_port(port, agent_id, session_id, deadline)
          
        {^port, {:exit_status, status}} ->
          ProcessTool.mark_completed(agent_id, session_id, status)
          
        {:EXIT, ^port, reason} ->
          ProcessTool.mark_completed(agent_id, session_id, {:exit, reason})
      after
        min(remaining, 1000) ->
          do_monitor_port(port, agent_id, session_id, deadline)
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

    # 启动监控进程（无限超时），并转移 Port 控制权
    monitor_pid = spawn(fn -> 
      receive do
        :start -> do_monitor_port(port, agent_id, session_id, :infinity) 
      end
    end)
    
    Port.connect(port, monitor_pid)
    send(monitor_pid, :start)

    {:ok,
     %{
       status: "running",
       sessionId: session_id,
       message: "Command started in background. Use process tool to check status."
     }}
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
