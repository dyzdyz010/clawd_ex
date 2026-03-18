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

  scope "/", ClawdExWeb do
    pipe_through :browser

    # Dashboard
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

    # Models
    live "/models", ModelsLive, :index

    # Settings
    live "/settings", SettingsLive, :index
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
  end
end
