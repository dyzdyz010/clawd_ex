defmodule ClawdEx.Agent.AutoStarter do
  @moduledoc """
  Agent 自启动服务 — 系统启动时自动为 auto_start: true 的 Agent 创建 persistent session。

  启动流程:
  1. 系统启动后延迟 3 秒（等待 DB 和 SessionManager 就绪）
  2. 查询所有 auto_start: true 的 Agent
  3. 为每个 Agent 启动 always_on session (key: "agent:{name}:always_on")
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.SessionManager

  @start_delay_ms 3_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the list of auto-started session keys (for inspection/testing).
  """
  @spec started_sessions() :: [String.t()]
  def started_sessions do
    GenServer.call(__MODULE__, :started_sessions)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    delay = Keyword.get(opts, :delay, @start_delay_ms)
    Process.send_after(self(), :auto_start, delay)
    {:ok, %{started: []}}
  end

  @impl true
  def handle_info(:auto_start, state) do
    started = start_auto_agents()
    {:noreply, %{state | started: started}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:started_sessions, _from, state) do
    {:reply, state.started, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp start_auto_agents do
    agents = fetch_auto_start_agents()

    if agents == [] do
      Logger.debug("AutoStarter: No auto_start agents found")
      []
    else
      Logger.info("AutoStarter: Starting #{length(agents)} auto_start agent(s)")

      Enum.reduce(agents, [], fn agent, acc ->
        session_key = "agent:#{agent.name}:always_on"

        case SessionManager.start_session(session_key: session_key, agent_id: agent.id, channel: "system") do
          {:ok, _pid} ->
            Logger.info("AutoStarter: Started session #{session_key} for agent #{agent.name}")
            [session_key | acc]

          {:error, reason} ->
            Logger.warning("AutoStarter: Failed to start session for agent #{agent.name}: #{inspect(reason)}")
            acc
        end
      end)
      |> Enum.reverse()
    end
  rescue
    e ->
      Logger.warning("AutoStarter: Failed to query auto_start agents: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("AutoStarter: DB unavailable: #{inspect(reason)}")
      []
  end

  defp fetch_auto_start_agents do
    Agent
    |> where([a], a.auto_start == true and a.active == true)
    |> Repo.all()
  end
end
