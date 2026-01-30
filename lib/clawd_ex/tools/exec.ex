defmodule ClawdEx.Tools.Exec do
  @moduledoc """
  执行 Shell 命令工具
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @impl true
  def name, do: "exec"

  @impl true
  def description do
    "Execute shell commands. Returns stdout, stderr, and exit code."
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
          description: "Timeout in seconds (default 30)"
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
    timeout = (params["timeout"] || params[:timeout] || 30) * 1000
    env = params["env"] || params[:env] || %{}

    resolved_workdir = resolve_path(workdir)

    Logger.debug("Executing command: #{command} in #{resolved_workdir}")

    # 构建环境变量
    env_list = Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    # 使用 Port 执行命令
    case run_command(command, resolved_workdir, env_list, timeout) do
      {:ok, output, exit_code} ->
        if exit_code == 0 do
          {:ok, output}
        else
          {:error, "Command exited with code #{exit_code}\n\n#{output}"}
        end

      {:error, :timeout} ->
        {:error, "Command timed out after #{div(timeout, 1000)} seconds"}

      {:error, reason} ->
        {:error, "Failed to execute command: #{inspect(reason)}"}
    end
  end

  defp run_command(command, workdir, env, timeout) do
    # 使用 System.cmd 包装器
    task = Task.async(fn ->
      try do
        {output, exit_code} = System.cmd(
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

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp resolve_path(path) do
    cond do
      String.starts_with?(path, "/") -> path
      String.starts_with?(path, "~") -> Path.expand(path)
      true -> Path.expand(path)
    end
  end
end
