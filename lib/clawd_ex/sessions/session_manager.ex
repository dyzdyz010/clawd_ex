defmodule ClawdEx.Sessions.SessionManager do
  @moduledoc """
  会话管理器 - 使用 DynamicSupervisor 管理活跃会话进程
  """
  use DynamicSupervisor

  alias ClawdEx.Sessions.SessionWorker

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  启动或获取会话进程
  """
  @spec start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_key, opts \\ []) do
    case find_session(session_key) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        spec = {SessionWorker, [session_key: session_key] ++ opts}
        DynamicSupervisor.start_child(__MODULE__, spec)
    end
  end

  @doc """
  查找会话进程
  """
  @spec find_session(String.t()) :: {:ok, pid()} | :not_found
  def find_session(session_key) do
    case Registry.lookup(ClawdEx.SessionRegistry, session_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc """
  停止会话进程
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_key) do
    case find_session(session_key) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  列出所有活跃会话
  """
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    Registry.select(ClawdEx.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
