defmodule ClawdExWeb.PageController do
  use ClawdExWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
