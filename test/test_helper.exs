# ==============================================================================
# Test Helper — Boot test infrastructure for --no-start mode
# ==============================================================================

# Start required OTP applications that our app depends on
# (--no-start means clawd_ex app tree won't auto-start, but we need deps)
{:ok, _} = Application.ensure_all_started(:logger)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = Application.ensure_all_started(:ssl)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:phoenix_live_view)
{:ok, _} = Application.ensure_all_started(:bandit)

# Ensure test env marker is set
Application.put_env(:clawd_ex, :env, :test)

# ---------------------------------------------------------------------------
# 1. Database — Start Repo and configure sandbox
# ---------------------------------------------------------------------------
{:ok, _} = ClawdEx.Repo.start_link(
  Application.get_env(:clawd_ex, ClawdEx.Repo) |> Keyword.put(:pool_size, 10)
)

# ---------------------------------------------------------------------------
# 2. Phoenix Endpoint (persistent_term, verified routes, etc.)
# ---------------------------------------------------------------------------
{:ok, _} = ClawdExWeb.Endpoint.start_link(
  Application.get_env(:clawd_ex, ClawdExWeb.Endpoint)
)

# Telemetry supervisor
{:ok, _} = ClawdExWeb.Telemetry.start_link([])

# ---------------------------------------------------------------------------
# 3. PubSub + Registries
# ---------------------------------------------------------------------------
{:ok, _} = Supervisor.start_link(
  [{Phoenix.PubSub, name: ClawdEx.PubSub}],
  strategy: :one_for_one
)
{:ok, _} = Registry.start_link(keys: :unique, name: ClawdEx.SessionRegistry)
{:ok, _} = Registry.start_link(keys: :unique, name: ClawdEx.AgentLoopRegistry)

# ---------------------------------------------------------------------------
# 4. Subsystem supervisors and GenServers (no DB at init)
# ---------------------------------------------------------------------------

# A2A subsystem (includes A2AMailboxRegistry, A2AMailboxSupervisor, A2A.Router)
{:ok, _} = ClawdEx.A2A.Supervisor.start_link([])

# Task supervisors
{:ok, _} = Task.Supervisor.start_link(name: ClawdEx.AgentTaskSupervisor)
{:ok, _} = Task.Supervisor.start_link(name: ClawdEx.WebhookTaskSupervisor)

# Core GenServers (no DB in init)
{:ok, _} = ClawdEx.Memory.Manager.start_link(%{})
{:ok, _} = ClawdEx.AI.OAuth.start_link([])
{:ok, _} = ClawdEx.Tools.Process.start_link([])
{:ok, _} = ClawdEx.Security.ApiKey.start_link([])
{:ok, _} = ClawdEx.Security.DmPairing.Server.start_link([])

# Nodes
{:ok, _} = ClawdEx.Nodes.Registry.start_link([])
{:ok, _} = ClawdEx.Nodes.Pairing.start_link([])

# Browser subsystem (CDP + Server)
{:ok, _} = ClawdEx.Browser.Supervisor.start_link([])

# Skills subsystem (Manager → Registry → Watcher)
{:ok, _} = ClawdEx.Skills.Supervisor.start_link([])

# Channel Registry
{:ok, _} = ClawdEx.Channels.Registry.start_link([])

# Plugins subsystem (NodeBridge + Manager)
{:ok, _} = ClawdEx.Plugins.Supervisor.start_link([])

# MCP subsystem (Registry + ServerManager)
{:ok, _} = ClawdEx.MCP.Supervisor.start_link([])

# ACP subsystem (SessionRegistry + Registry + SessionSupervisor)
{:ok, _} = ClawdEx.ACP.Supervisor.start_link([])

# Output Manager
{:ok, _} = ClawdEx.Agent.OutputManager.start_link([])

# Session Manager (DynamicSupervisor)
{:ok, _} = ClawdEx.Sessions.SessionManager.start_link([])

# Discord and Telegram supervisors (they check enabled? internally, safe to start)
ClawdEx.Channels.DiscordSupervisor.start_link([])
ClawdEx.Channels.TelegramSupervisor.start_link([])

# ---------------------------------------------------------------------------
# 5. DB-dependent GenServers — start with shared sandbox checkout
#    These GenServers fire DB queries from timers (load_jobs, check_tasks, etc.)
#    We give them a shared sandbox connection, then switch to :manual for tests.
# ---------------------------------------------------------------------------

# Allow the test process to checkout a shared connection that background
# GenServers can piggyback on during startup
Ecto.Adapters.SQL.Sandbox.mode(ClawdEx.Repo, {:shared, self()})

# Deploy Manager (no DB dependency, just file-based)
{:ok, _} = ClawdEx.Deploy.Manager.start_link([])

# Start DB-dependent GenServers under a tolerant supervisor
{:ok, _db_sup} = Supervisor.start_link(
  [
    ClawdEx.Tasks.Manager,
    ClawdEx.Cron.Supervisor,
    ClawdEx.Webhooks.Manager,
  ],
  strategy: :one_for_one,
  max_restarts: 50,
  max_seconds: 10
)

# Give the GenServers time to complete their initial DB queries
Process.sleep(2_000)

# ---------------------------------------------------------------------------
# 6. ExUnit
# ---------------------------------------------------------------------------
ExUnit.start(exclude: [:requires_chrome])

# Switch sandbox back to :manual for test isolation
# Individual tests use DataCase.setup_sandbox/1 to checkout connections
Ecto.Adapters.SQL.Sandbox.mode(ClawdEx.Repo, :manual)
