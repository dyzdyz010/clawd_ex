defmodule ClawdEx.Agent.AutoStarter do
  @moduledoc """
  Agent 自启动服务 — 系统启动时自动为 auto_start: true 的 Agent 创建 persistent session。

  启动流程:
  1. 系统启动后延迟 3 秒（等待 DB 和 SessionManager 就绪）
  2. 查询所有 auto_start: true 的 Agent
  3. 为每个 Agent 启动 always_on session (key: "agent:{name}:always_on")
  4. 每 60 秒执行 health check，确保所有 auto_start agent 的 session 都在运行
  5. 初始启动后调用 A2A discover 验证注册状态
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.SessionManager
  alias ClawdEx.Channels.BindingManager

  @start_delay_ms 3_000
  @health_check_interval_ms 60_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
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
    health_interval = Keyword.get(opts, :health_check_interval, @health_check_interval_ms)
    Process.send_after(self(), :auto_start, delay)
    {:ok, %{started: [], health_check_interval: health_interval, uptimes: %{}}}
  end

  @impl true
  def handle_info(:auto_start, state) do
    # Sync agent definitions from priv/agents.json → DB before starting sessions
    ClawdEx.Agents.Seeder.sync!()

    started = start_auto_agents()
    now = System.monotonic_time(:second)

    uptimes =
      Enum.reduce(started, state.uptimes, fn key, acc ->
        Map.put_new(acc, key, now)
      end)

    # Verify A2A registration after all sessions are started
    verify_a2a_registration()

    # Schedule first health check
    schedule_health_check(state.health_check_interval)

    {:noreply, %{state | started: started, uptimes: uptimes}}
  end

  @impl true
  def handle_info(:health_check, state) do
    {started, uptimes} = run_health_check(state.started, state.uptimes)

    # Schedule next health check
    schedule_health_check(state.health_check_interval)

    {:noreply, %{state | started: started, uptimes: uptimes}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:started_sessions, _from, state) do
    {:reply, state.started, state}
  end

  # ============================================================================
  # Private — Initial Start
  # ============================================================================

  defp start_auto_agents do
    agents = fetch_auto_start_agents()

    if agents == [] do
      Logger.info("[AutoStarter] No auto_start agents found")
      []
    else
      Logger.info("[AutoStarter] Starting #{length(agents)} auto_start agent(s)")

      Enum.reduce(agents, [], fn agent, acc ->
        # Query channel bindings for this agent
        bindings = BindingManager.list_active_bindings(agent.id)

        if bindings == [] do
          # No bindings — fallback to always_on session (for A2A registration)
          session_key = "agent:#{agent.name}:always_on"

          case SessionManager.start_session(
                 session_key: session_key,
                 agent_id: agent.id,
                 channel: "system"
               ) do
            {:ok, pid} ->
              Logger.info(
                "[AutoStarter] Started fallback session #{session_key} | agent=#{agent.name} | pid=#{inspect(pid)}"
              )

              [session_key | acc]

            {:error, reason} ->
              Logger.warning(
                "[AutoStarter] Failed to start fallback session for agent #{agent.name}: #{inspect(reason)}"
              )

              acc
          end
        else
          # Start binding sessions
          binding_keys =
            Enum.reduce(bindings, [], fn binding, bacc ->
              case BindingManager.ensure_binding_session(binding) do
                {:ok, pid} ->
                  Logger.info(
                    "[AutoStarter] Started binding session #{binding.session_key} | agent=#{agent.name} | pid=#{inspect(pid)}"
                  )

                  [binding.session_key | bacc]

                {:error, reason} ->
                  Logger.warning(
                    "[AutoStarter] Failed to start binding session #{binding.session_key}: #{inspect(reason)}"
                  )

                  bacc

                :skip ->
                  bacc
              end
            end)

          binding_keys ++ acc
        end
      end)
      |> Enum.reverse()
    end
  rescue
    e ->
      Logger.warning("[AutoStarter] Failed to query auto_start agents: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("[AutoStarter] DB unavailable: #{inspect(reason)}")
      []
  end

  # ============================================================================
  # Private — Health Check
  # ============================================================================

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end

  defp run_health_check(current_started, uptimes) do
    agents = fetch_auto_start_agents()

    if agents == [] do
      Logger.debug("[AutoStarter] Health check: no auto_start agents")
      {current_started, uptimes}
    else
      Logger.info("[AutoStarter] Health check: checking #{length(agents)} agent(s)")
      now = System.monotonic_time(:second)

      Enum.reduce(agents, {current_started, uptimes}, fn agent, {started_acc, uptimes_acc} ->
        # Get binding sessions for this agent
        bindings = BindingManager.list_active_bindings(agent.id)

        if bindings == [] do
          # Fallback: check always_on session
          check_and_restart_session(
            "agent:#{agent.name}:always_on",
            agent,
            "system",
            nil,
            now,
            started_acc,
            uptimes_acc
          )
        else
          # Check each binding session
          Enum.reduce(bindings, {started_acc, uptimes_acc}, fn binding, {sacc, uacc} ->
            check_and_restart_session(
              binding.session_key,
              agent,
              binding.channel,
              binding.channel_config,
              now,
              sacc,
              uacc
            )
          end)
        end
      end)
    end
  rescue
    e ->
      Logger.warning("[AutoStarter] Health check failed: #{Exception.message(e)}")
      {current_started, uptimes}
  catch
    :exit, reason ->
      Logger.warning("[AutoStarter] Health check DB unavailable: #{inspect(reason)}")
      {current_started, uptimes}
  end

  defp check_and_restart_session(session_key, agent, channel, channel_config, now, started_acc, uptimes_acc) do
    case SessionManager.find_session(session_key) do
      {:ok, pid} ->
        uptime_start = Map.get(uptimes_acc, session_key, now)
        uptime_s = now - uptime_start

        Logger.info(
          "[AutoStarter] ✓ #{agent.name} (#{session_key}) — running | pid=#{inspect(pid)} | uptime=#{uptime_s}s"
        )

        {started_acc, uptimes_acc}

      :not_found ->
        Logger.warning(
          "[AutoStarter] ✗ #{agent.name} (#{session_key}) — not found, restarting..."
        )

        start_opts =
          [session_key: session_key, agent_id: agent.id, channel: channel]
          |> maybe_add_channel_config(channel_config)

        case SessionManager.start_session(start_opts) do
          {:ok, pid} ->
            Logger.info(
              "[AutoStarter] ✓ #{agent.name} restarted successfully | pid=#{inspect(pid)}"
            )

            new_started =
              if session_key in started_acc,
                do: started_acc,
                else: started_acc ++ [session_key]

            new_uptimes = Map.put(uptimes_acc, session_key, now)
            {new_started, new_uptimes}

          {:error, reason} ->
            Logger.error(
              "[AutoStarter] ✗ #{agent.name} restart failed: #{inspect(reason)}"
            )

            {started_acc, uptimes_acc}
        end
    end
  end

  defp maybe_add_channel_config(opts, nil), do: opts
  defp maybe_add_channel_config(opts, config), do: Keyword.put(opts, :channel_config, config)

  # ============================================================================
  # Private — A2A Verification
  # ============================================================================

  defp verify_a2a_registration do
    case ClawdEx.A2A.Router.discover() do
      {:ok, agents} ->
        registered = Enum.filter(agents, &Map.has_key?(&1, :registered_at))
        db_only = Enum.reject(agents, &Map.has_key?(&1, :registered_at))

        Logger.info(
          "[AutoStarter] A2A verification: #{length(agents)} agent(s) discoverable | " <>
            "#{length(registered)} in-memory registered | #{length(db_only)} DB-only"
        )

        for a <- registered do
          Logger.info(
            "[AutoStarter] A2A: #{Map.get(a, :name, "id=#{a.agent_id}")} | capabilities=#{inspect(a.capabilities)}"
          )
        end

      {:error, reason} ->
        Logger.warning("[AutoStarter] A2A verification failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[AutoStarter] A2A verification error: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("[AutoStarter] A2A Router unavailable: #{inspect(reason)}")
  end

  # ============================================================================
  # Private — DB
  # ============================================================================

  defp fetch_auto_start_agents do
    Agent
    |> where([a], a.auto_start == true and a.active == true)
    |> Repo.all()
  end
end
