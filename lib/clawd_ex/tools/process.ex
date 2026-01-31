defmodule ClawdEx.Tools.Process do
  @moduledoc """
  后台进程管理工具

  管理由 exec 启动的后台进程。
  """
  @behaviour ClawdEx.Tools.Tool

  use GenServer
  require Logger

  @table_name :background_processes

  # ============================================================================
  # Tool Behaviour
  # ============================================================================

  @impl ClawdEx.Tools.Tool
  def name, do: "process"

  @impl ClawdEx.Tools.Tool
  def description do
    "Manage background exec sessions: list, poll, log, write, kill, clear."
  end

  @impl ClawdEx.Tools.Tool
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["list", "poll", "log", "write", "kill", "clear"],
          description: "Action to perform"
        },
        sessionId: %{
          type: "string",
          description: "Session ID for actions other than list"
        },
        data: %{
          type: "string",
          description: "Data to write for write action"
        },
        offset: %{
          type: "integer",
          description: "Log offset (line number)"
        },
        limit: %{
          type: "integer",
          description: "Log limit (number of lines)"
        }
      },
      required: ["action"]
    }
  end

  @impl ClawdEx.Tools.Tool
  def execute(params, context) do
    action = params["action"] || params[:action]
    session_id = params["sessionId"] || params[:sessionId]
    agent_id = context[:agent_id]

    case action do
      "list" -> list_sessions(agent_id)
      "poll" -> poll_session(agent_id, session_id)
      "log" -> get_log(agent_id, session_id, params)
      "write" -> write_to_session(agent_id, session_id, params["data"] || params[:data])
      "kill" -> kill_session(agent_id, session_id)
      "clear" -> clear_sessions(agent_id)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # ============================================================================
  # GenServer for background process management
  # ============================================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # 创建 ETS 表存储后台进程
    :ets.new(@table_name, [:named_table, :public, :set])
    {:ok, %{}}
  end

  # ============================================================================
  # Public API for Exec tool
  # ============================================================================

  @doc """
  注册一个后台进程
  """
  def register_process(agent_id, session_id, port, command) do
    entry = %{
      session_id: session_id,
      agent_id: agent_id,
      command: command,
      port: port,
      output: "",
      exit_code: nil,
      started_at: DateTime.utc_now(),
      ended_at: nil
    }

    :ets.insert(@table_name, {{agent_id, session_id}, entry})
    {:ok, session_id}
  end

  @doc """
  追加输出到进程记录
  """
  def append_output(agent_id, session_id, data) do
    case :ets.lookup(@table_name, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, entry}] ->
        updated = %{entry | output: entry.output <> data}
        :ets.insert(@table_name, {{agent_id, session_id}, updated})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  标记进程已结束
  """
  def mark_completed(agent_id, session_id, exit_code) do
    case :ets.lookup(@table_name, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, entry}] ->
        updated = %{entry |
          exit_code: exit_code,
          ended_at: DateTime.utc_now()
        }
        :ets.insert(@table_name, {{agent_id, session_id}, updated})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # ============================================================================
  # Tool Actions
  # ============================================================================

  defp list_sessions(agent_id) do
    sessions =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {{a_id, _}, _} -> a_id == agent_id end)
      |> Enum.map(fn {{_, session_id}, entry} ->
        %{
          sessionId: session_id,
          command: entry.command,
          status: if(entry.exit_code == nil, do: "running", else: "completed"),
          exitCode: entry.exit_code,
          startedAt: entry.started_at
        }
      end)

    {:ok, %{sessions: sessions}}
  end

  defp poll_session(agent_id, session_id) do
    case :ets.lookup(@table_name, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, entry}] ->
        result = %{
          sessionId: session_id,
          status: if(entry.exit_code == nil, do: "running", else: "completed"),
          exitCode: entry.exit_code,
          output: entry.output
        }
        {:ok, result}

      [] ->
        {:error, "Session not found: #{session_id}"}
    end
  end

  defp get_log(agent_id, session_id, params) do
    offset = params["offset"] || params[:offset] || 0
    limit = params["limit"] || params[:limit] || 100

    case :ets.lookup(@table_name, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, entry}] ->
        lines = String.split(entry.output, "\n")

        selected =
          lines
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.join("\n")

        {:ok, %{
          sessionId: session_id,
          log: selected,
          totalLines: length(lines)
        }}

      [] ->
        {:error, "Session not found: #{session_id}"}
    end
  end

  defp write_to_session(agent_id, session_id, data) do
    case :ets.lookup(@table_name, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, entry}] ->
        if entry.port && entry.exit_code == nil do
          Port.command(entry.port, data)
          {:ok, %{written: byte_size(data)}}
        else
          {:error, "Process is not running"}
        end

      [] ->
        {:error, "Session not found: #{session_id}"}
    end
  end

  defp kill_session(agent_id, session_id) do
    case :ets.lookup(@table_name, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, entry}] ->
        if entry.port && entry.exit_code == nil do
          Port.close(entry.port)
          mark_completed(agent_id, session_id, :killed)
          {:ok, %{killed: true}}
        else
          {:ok, %{killed: false, reason: "already_completed"}}
        end

      [] ->
        {:error, "Session not found: #{session_id}"}
    end
  end

  defp clear_sessions(agent_id) do
    # 先 kill 所有运行中的进程
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {{a_id, _}, entry} ->
      a_id == agent_id && entry.exit_code == nil
    end)
    |> Enum.each(fn {{_, session_id}, entry} ->
      if entry.port, do: Port.close(entry.port)
      mark_completed(agent_id, session_id, :killed)
    end)

    # 删除所有该 agent 的记录
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {{a_id, _}, _} -> a_id == agent_id end)
    |> Enum.each(fn {key, _} -> :ets.delete(@table_name, key) end)

    {:ok, %{cleared: true}}
  end
end
