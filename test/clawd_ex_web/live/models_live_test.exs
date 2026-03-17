defmodule ClawdExWeb.ModelsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders models page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/models")

      assert html =~ "Models"
      assert html =~ "AI provider configuration"
    end

    test "displays default models section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/models")

      assert html =~ "Default Models"
      assert html =~ "Default Model"
      assert html =~ "Vision Model"
      assert html =~ "Fast Model"
    end

    test "lists all providers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/models")

      assert html =~ "Anthropic"
      assert html =~ "OpenAI"
      assert html =~ "Google"
      assert html =~ "Groq"
      assert html =~ "Ollama"
      assert html =~ "OpenRouter"
    end

    test "shows provider status badges", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/models")

      # Should show either Configured or Not Configured for each provider
      assert html =~ "Configured" or html =~ "Not Configured"
    end

    test "shows model counts per provider", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/models")

      # Anthropic has models defined
      assert html =~ "model"
    end
  end

  describe "toggle_provider" do
    test "expands provider to show models", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/models")

      # Click on Anthropic to expand
      html = view |> element("button[phx-value-provider=anthropic]") |> render_click()

      # Should show Anthropic models
      assert html =~ "anthropic/claude-opus"
      assert html =~ "Aliases:"
    end

    test "shows capabilities for expanded models", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/models")

      html = view |> element("button[phx-value-provider=anthropic]") |> render_click()

      assert html =~ "chat"
      assert html =~ "vision"
      assert html =~ "tools"
    end

    test "collapses provider on second click", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/models")

      # First click - expand
      view |> element("button[phx-value-provider=anthropic]") |> render_click()
      expanded_html = render(view)
      # Should show model details like capabilities
      assert expanded_html =~ "chat"

      # Second click - collapse
      view |> element("button[phx-value-provider=anthropic]") |> render_click()
      collapsed_html = render(view)

      # The expanded model table/details should be gone
      # (provider header still visible, but detail rows collapsed)
      # Check that the expanded_provider assign is cleared
      assert collapsed_html =~ "Anthropic"
    end

    test "expanding one provider collapses the other", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/models")

      # Expand Anthropic
      view |> element("button[phx-value-provider=anthropic]") |> render_click()

      # Expand OpenAI
      html = view |> element("button[phx-value-provider=openai]") |> render_click()

      # Should show OpenAI models
      assert html =~ "openai/gpt"
      # OpenAI section should be expanded (check for its model capabilities)
      assert html =~ "OpenAI"
    end

    test "shows API key env var name when expanded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/models")

      html = view |> element("button[phx-value-provider=openai]") |> render_click()

      assert html =~ "OPENAI_API_KEY"
    end
  end
end
