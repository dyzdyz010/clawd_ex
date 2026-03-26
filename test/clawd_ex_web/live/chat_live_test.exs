defmodule ClawdExWeb.ChatLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders chat interface with key elements", %{conn: conn} do
    {:ok, view, html} = live(conn, "/chat")

    assert html =~ "Chat"
    assert html =~ "开始对话吧"
    assert html =~ "新对话"
    assert html =~ "发送"
    assert html =~ "<textarea"
    assert html =~ "输入消息"
    assert html =~ "🤖"
    assert html =~ "输入消息并按 Enter 发送"
    # Session key assigned
    assert view |> element("header p") |> render() =~ "Session: web:"
    # Send button disabled when empty
    assert html =~ "disabled"
  end

  test "sends message and displays it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    view |> form("form", message: "你好") |> render_submit()

    html = render(view)
    assert html =~ "你好"
    assert html =~ "justify-end"
    assert html =~ "bg-blue-600"
    assert html =~ ~r/\d{2}:\d{2}/
  end

  test "does not send empty messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    view |> form("form", message: "") |> render_submit()

    assert render(view) =~ "开始对话吧"
  end

  test "new chat creates new session and clears messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    [_, initial_key] = Regex.run(~r/Session: (web:[a-f0-9]+)/, render(view))

    view |> form("form", message: "测试消息") |> render_submit()
    assert render(view) =~ "测试消息"

    view |> element("button", "新对话") |> render_click()

    html = render(view)
    [_, new_key] = Regex.run(~r/Session: (web:[a-f0-9]+)/, html)
    assert initial_key != new_key
    assert html =~ "开始对话吧"
  end

  test "updates input value on change", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    view |> element("textarea") |> render_change(%{message: "测试输入"})

    assert view |> element("textarea") |> render() =~ "测试输入"
  end
end
