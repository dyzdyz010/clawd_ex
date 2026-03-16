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

    # Settings
    live "/settings", SettingsLive, :index
  end

  # API endpoints
  scope "/api", ClawdExWeb do
    pipe_through :api

    post "/webhooks/inbound", WebhookController, :inbound
  end
end
