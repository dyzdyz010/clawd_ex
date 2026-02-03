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

  # Other scopes may use custom stacks.
  # scope "/api", ClawdExWeb do
  #   pipe_through :api
  # end
end
