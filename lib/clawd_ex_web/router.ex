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

    get "/", PageController, :home
    live "/chat", ChatLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClawdExWeb do
  #   pipe_through :api
  # end
end
