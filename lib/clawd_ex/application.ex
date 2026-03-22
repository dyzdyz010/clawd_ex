defmodule ClawdEx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # 初始化文件日志
    ClawdEx.Logging.setup_file_handler()

    # 初始化工作区
    init_workspace()

    children = [
      ClawdExWeb.Telemetry,
      ClawdEx.Repo,
      # Note: Finch for Telegex is started by Telegex.Application, don't duplicate
      {DNSCluster, query: Application.get_env(:clawd_ex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClawdEx.PubSub},
      # Session Registry for process lookup
      {Registry, keys: :unique, name: ClawdEx.SessionRegistry},
      # Agent Loop Registry
      {Registry, keys: :unique, name: ClawdEx.AgentLoopRegistry},
      # A2A subsystem (Registry, DynamicSupervisor, Router)
      ClawdEx.A2A.Supervisor,
      # Agent Loop Task Supervisor (for supervised AI/tool tasks)
      {Task.Supervisor, name: ClawdEx.AgentTaskSupervisor},
      # Memory Manager (unified memory backend coordination)
      {ClawdEx.Memory.Manager, %{}},
      # OAuth credential manager (handles token refresh)
      ClawdEx.AI.OAuth,
      # Background process manager
      ClawdEx.Tools.Process,
      # API Key manager (ETS-backed)
      ClawdEx.Security.ApiKey,
      # Node registry for paired devices
      ClawdEx.Nodes.Registry,
      # Node pairing service (pair codes, token management)
      ClawdEx.Nodes.Pairing,
      # Browser subsystem (CDP → Server)
      ClawdEx.Browser.Supervisor,
      # Skills subsystem (Manager → Registry → Watcher)
      ClawdEx.Skills.Supervisor,
      # Channel Registry (dynamic channel lookup) — must start before Plugins
      ClawdEx.Channels.Registry,
      # Plugins subsystem (Manager — registers builtin channels on init)
      ClawdEx.Plugins.Supervisor,
      # MCP subsystem (Server connections + Tool proxy)
      ClawdEx.MCP.Supervisor,
      # Progressive Output Manager
      ClawdEx.Agent.OutputManager,
      # Task Manager (periodic task health checks)
      ClawdEx.Tasks.Manager,
      # Cron subsystem (Scheduler)
      ClawdEx.Cron.Supervisor,
      # Webhook Manager (outbound webhook dispatch + retry)
      {Task.Supervisor, name: ClawdEx.WebhookTaskSupervisor},
      ClawdEx.Webhooks.Manager,
      # Session Manager (DynamicSupervisor)
      ClawdEx.Sessions.SessionManager,
      # Discord channel (optional, starts if configured)
      ClawdEx.Channels.DiscordSupervisor,
      # Telegram channel (optional, starts if configured)
      ClawdEx.Channels.TelegramSupervisor,
      # Start to serve requests, typically the last entry
      ClawdExWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    # In test env, increase max_restarts to prevent cascading supervisor shutdown
    # when spawned processes hit DB sandbox ownership errors
    max_restarts = if Application.get_env(:clawd_ex, :env) == :test, do: 100, else: 3
    opts = [strategy: :one_for_one, name: ClawdEx.Supervisor, max_restarts: max_restarts, max_seconds: 5]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClawdExWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Initialize workspace with bootstrap files
  defp init_workspace do
    require Logger

    workspace = Application.get_env(:clawd_ex, :workspace) ||
                System.get_env("CLAWD_WORKSPACE") ||
                "~/.clawd/workspace"

    case ClawdEx.Agent.Workspace.init(workspace) do
      {:ok, path} ->
        Logger.info("Workspace initialized: #{path}")

      {:error, reason} ->
        Logger.warning("Failed to initialize workspace: #{inspect(reason)}")
    end
  end

end
