defmodule ClawdExWeb.SkillsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders skills page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ "Skills"
    end

    test "displays stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ "Total Skills"
      assert html =~ "Loaded"
      assert html =~ "Unavailable"
      assert html =~ "Disabled"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ "Search skills"
    end

    test "has filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ "All"
      assert html =~ "Loaded"
      assert html =~ "Unavailable"
      assert html =~ "Disabled"
    end

    test "has refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ "Refresh"
    end
  end

  describe "events" do
    test "search event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      view
      |> render_keyup("search", %{"search" => "test-skill"})

      html = render(view)
      assert html =~ "Skills"
    end

    test "filter_status event for eligible does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      view
      |> render_click("filter_status", %{"status" => "eligible"})

      html = render(view)
      assert html =~ "Skills"
    end

    test "filter_status event for unavailable does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      view
      |> render_click("filter_status", %{"status" => "unavailable"})

      html = render(view)
      assert html =~ "Skills"
    end

    test "filter_status event for disabled does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      view
      |> render_click("filter_status", %{"status" => "disabled"})

      html = render(view)
      assert html =~ "Skills"
    end

    test "filter_status event for all does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      # Switch to eligible then back to all
      view |> render_click("filter_status", %{"status" => "eligible"})
      view |> render_click("filter_status", %{"status" => "all"})

      html = render(view)
      assert html =~ "Skills"
    end

    test "refresh event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      view
      |> render_click("refresh")

      html = render(view)
      assert html =~ "Skills"
    end
  end
end
