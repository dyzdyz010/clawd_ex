defmodule ClawdExWeb.SkillsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders skills page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/skills")

    assert html =~ "Skills"
    assert html =~ "Total Skills"
    assert html =~ "Loaded"
    assert html =~ "Unavailable"
    assert html =~ "Disabled"
    assert html =~ "Search skills"
    assert html =~ "All"
    assert html =~ "Refresh"
  end

  test "search and filter events do not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/skills")

    view |> render_keyup("search", %{"search" => "test-skill"})

    for status <- ["eligible", "unavailable", "disabled", "all"] do
      html = view |> render_click("filter_status", %{"status" => status})
      assert html =~ "Skills"
    end

    html = view |> render_click("refresh")
    assert html =~ "Skills"
  end
end
