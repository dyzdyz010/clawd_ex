defmodule ClawdExWeb.Router do
  use ClawdExWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClawdExWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :browser_auth do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClawdExWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ClawdExWeb.Plugs.WebAuthPlug
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug ClawdExWeb.Plugs.Auth
  end

  pipeline :gateway_auth do
    plug :accepts, ["json"]
    plug ClawdExWeb.Plugs.BearerAuth
  end

  pipeline :api_v1_auth do
    plug :accepts, ["json"]
    plug ClawdExWeb.Plugs.RateLimitPlug
    plug ClawdExWeb.Plugs.ApiAuthPlug
  end

  pipeline :require_admin do
    plug ClawdExWeb.Plugs.RequireScopePlug, scope: :admin
  end

  # Public routes (login, auth callback, logout)
  scope "/", ClawdExWeb do
    pipe_through :browser

    live "/login", LoginLive, :index
    get "/auth/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :logout
    get "/auth/logout", AuthController, :logout
  end

  # Protected browser routes — require web auth
  scope "/", ClawdExWeb do
    pipe_through :browser_auth

    # Dashboard
    live_session :authenticated,
      on_mount: [{ClawdExWeb.Auth, :ensure_authenticated}] do
      live "/", DashboardLive, :index

      # Chat
      live "/chat", ChatLive, :index

      # Sessions
      live "/sessions", SessionsLive, :index
      live "/sessions/:id", SessionDetailLive, :show

      # Agents
      live "/agents", AgentsLive, :index
      live "/agents/new", AgentFormLive, :new
      live "/agents/:id/edit", AgentFormLive, :edit

      # Skills
      live "/skills", SkillsLive, :index

      # Webhooks
      live "/webhooks", WebhooksLive, :index

      # Tasks
      live "/tasks", TasksLive, :index
      live "/tasks/:id", TaskDetailLive, :show

      # A2A Communication
      live "/a2a", A2ALive, :index

      # Cron Jobs
      live "/cron", CronJobsLive, :index
      live "/cron/new", CronJobFormLive, :new
      live "/cron/:id", CronJobDetailLive, :show
      live "/cron/:id/edit", CronJobFormLive, :edit

      # Logs
      live "/logs", LogsLive, :index

      # Gateway
      live "/gateway", GatewayLive, :index

      # Plugins
      live "/plugins", PluginsLive, :index

      # Nodes
      live "/nodes", NodesLive, :index

      # Models
      live "/models", ModelsLive, :index

      # Settings
      live "/settings", SettingsLive, :index
    end
  end

  # Public API endpoints (no auth required)
  scope "/api", ClawdExWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Authenticated API endpoints
  scope "/api", ClawdExWeb do
    pipe_through [:api, :gateway_auth]

    post "/webhooks/inbound", WebhookController, :inbound
    post "/webhooks/inbound/generic", WebhookController, :inbound_generic
    post "/webhooks/:webhook_id/trigger", WebhookController, :trigger
  end

  # Gateway REST API v1 — Admin-only endpoints
  scope "/api/v1", ClawdExWeb.Api do
    pipe_through [:api, :api_v1_auth, :require_admin]

    # API Key management (admin only)
    get "/auth/keys", AuthController, :index
    post "/auth/keys", AuthController, :create
    delete "/auth/keys/:id", AuthController, :delete
  end

  # Gateway REST API v1
  scope "/api/v1", ClawdExWeb.Api do
    pipe_through [:api, :api_v1_auth]

    # Gateway status
    get "/gateway/status", GatewayController, :status
    get "/gateway/health", GatewayController, :health

    # Sessions
    get "/sessions", SessionController, :index
    get "/sessions/:key", SessionController, :show
    post "/sessions/:key/messages", SessionController, :send_message
    delete "/sessions/:key", SessionController, :delete

    # Agents
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show
    post "/agents", AgentController, :create
    put "/agents/:id", AgentController, :update

    # Tools
    get "/tools", ToolController, :index
    post "/tools/:name/execute", ToolController, :execute

    # SSE Streaming
    get "/sessions/:key/stream", StreamController, :stream
    post "/sessions/:key/chat", StreamController, :chat

    # Nodes (设备配对管理)
    post "/nodes/pair", NodeController, :pair
    post "/nodes/generate_code", NodeController, :generate_code
    get "/nodes/pending", NodeController, :pending
    get "/nodes", NodeController, :index
    get "/nodes/:id", NodeController, :show
    post "/nodes/:id/approve", NodeController, :approve
    post "/nodes/:id/reject", NodeController, :reject
    delete "/nodes/:id", NodeController, :delete
  end
end
