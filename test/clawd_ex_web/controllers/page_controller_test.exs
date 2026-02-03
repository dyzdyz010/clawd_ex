defmodule ClawdExWeb.PageControllerTest do
  use ClawdExWeb.ConnCase

  test "GET / shows dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard"
  end
end
