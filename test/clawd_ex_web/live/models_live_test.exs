defmodule ClawdExWeb.ModelsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders models page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/models")

    assert html =~ "Models"
    assert html =~ "AI provider configuration"
    assert html =~ "Default Models"
    assert html =~ "Default Model"
    assert html =~ "Vision Model"
    assert html =~ "Fast Model"
    assert html =~ "Anthropic"
    assert html =~ "OpenAI"
    assert html =~ "Google"
    assert html =~ "Groq"
    assert html =~ "Ollama"
    assert html =~ "OpenRouter"
    assert html =~ "Configured" or html =~ "Not Configured"
  end

  test "expand provider shows models and capabilities", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/models")

    html = view |> element("button[phx-value-provider=anthropic]") |> render_click()

    assert html =~ "anthropic/claude"
    assert html =~ "chat"
    assert html =~ "vision"
    assert html =~ "tools"
  end

  test "collapse provider on second click", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/models")

    view |> element("button[phx-value-provider=anthropic]") |> render_click()
    view |> element("button[phx-value-provider=anthropic]") |> render_click()

    html = render(view)
    assert html =~ "Anthropic"
  end

  test "expanding different provider shows its details", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/models")

    html = view |> element("button[phx-value-provider=openai]") |> render_click()

    assert html =~ "openai/gpt"
    assert html =~ "OPENAI_API_KEY"
  end
end
