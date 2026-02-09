defmodule ClawdEx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
      # OAuth credential manager (handles token refresh)
      ClawdEx.AI.OAuth,
      # Unified Memory Manager (multi-backend)
      {ClawdEx.Memory.Manager, memory_config()},
      # Background process manager
      ClawdEx.Tools.Process,
      # Node registry for paired devices
      ClawdEx.Nodes.Registry,
      # Browser CDP client
      ClawdEx.Browser.CDP,
      # Browser server (manages Chrome process)
      ClawdEx.Browser.Server,
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
    opts = [strategy: :one_for_one, name: ClawdEx.Supervisor]
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

  # Build memory manager configuration
  defp memory_config do
    # 读取 ClawdEx 配置文件
    clawd_config = read_clawd_config()

    workspace = Application.get_env(:clawd_ex, :workspace) ||
                System.get_env("CLAWD_WORKSPACE") ||
                get_in(clawd_config, ["workspace"]) ||
                "~/.clawd/workspace"

    # MemOS 配置优先级：环境变量 > 配置文件
    memos_config = get_in(clawd_config, ["memos"]) || %{}
    memos_api_key = System.get_env("MEMOS_API_KEY") ||
                    memos_config["api_key"]
    memos_user_id = System.get_env("MEMOS_USER_ID") ||
                    memos_config["user_id"] ||
                    "default"
    memos_base_url = memos_config["base_url"] ||
                     "https://memos.memtensor.cn/api/openmem/v1"

    memos_enabled = memos_api_key != nil and memos_api_key != ""

    if memos_enabled do
      require Logger
      Logger.info("MemOS backend enabled (user_id: #{memos_user_id})")
    end

    %{
      backends: %{
        local_file: %{
          module: ClawdEx.Memory.Backends.LocalFile,
          enabled: true,
          priority: 1,
          types: [:episodic, :semantic, :procedural],
          config: %{workspace: workspace}
        },
        memos: %{
          module: ClawdEx.Memory.Backends.MemOS,
          enabled: memos_enabled,
          priority: 2,
          types: [:episodic],
          config: %{
            api_key: memos_api_key,
            user_id: memos_user_id,
            base_url: memos_base_url
          }
        },
        pgvector: %{
          module: ClawdEx.Memory.Backends.PgVector,
          enabled: true,
          priority: 3,
          types: [:semantic, :procedural],
          config: %{}
        }
      }
    }
  end

  # 读取 ~/.clawd/config.json
  defp read_clawd_config do
    config_path = Path.expand("~/.clawd/config.json")

    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} -> config
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
