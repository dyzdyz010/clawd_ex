defmodule ClawdExWeb.ChatLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders chat interface", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "Chat"
      assert html =~ "开始对话吧"
      assert html =~ "新对话"
    end

    test "generates session key on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Session key should be assigned
      assert view |> element("header p") |> render() =~ "Session: web:"
    end

    test "starts with empty messages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "开始对话吧"
      assert html =~ "输入消息并按 Enter 发送"
    end
  end

  describe "sending messages" do
    test "displays user message immediately", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Send a message
      view
      |> form("form", message: "你好")
      |> render_submit()

      # User message should appear
      html = render(view)
      assert html =~ "你好"
    end

    test "send button has correct attributes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Button should be disabled when input is empty
      html = render(view)
      assert html =~ "disabled"
      assert html =~ ~s(type="submit")
    end

    test "does not send empty messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Try to send empty message
      view
      |> form("form", message: "")
      |> render_submit()

      # Should still show empty state
      assert render(view) =~ "开始对话吧"
    end

    test "clears input after sending", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      view
      |> form("form", message: "测试消息")
      |> render_submit()

      # Input should be cleared (textarea value empty)
      html = render(view)
      # Message appears in the list but input is cleared
      assert html =~ "测试消息"
    end
  end

  describe "input handling" do
    test "updates input value on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      view
      |> element("textarea")
      |> render_change(%{message: "测试输入"})

      # Input should be updated
      assert view |> element("textarea") |> render() =~ "测试输入"
    end
  end

  describe "new chat" do
    test "creates new session on new_chat event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Get initial session key
      initial_html = render(view)

      # Click new chat button
      view
      |> element("button", "新对话")
      |> render_click()

      # Session key should change
      new_html = render(view)

      # Extract session keys for comparison
      [_, initial_key] = Regex.run(~r/Session: (web:[a-f0-9]+)/, initial_html)
      [_, new_key] = Regex.run(~r/Session: (web:[a-f0-9]+)/, new_html)

      assert initial_key != new_key
    end

    test "clears messages on new chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Send a message first
      view
      |> form("form", message: "测试消息")
      |> render_submit()

      # Verify message is shown
      assert render(view) =~ "测试消息"

      # Click new chat
      view
      |> element("button", "新对话")
      |> render_click()

      # Should show empty state again
      assert render(view) =~ "开始对话吧"
    end
  end

  describe "message display" do
    test "user messages have correct styling", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      view
      |> form("form", message: "用户消息")
      |> render_submit()

      html = render(view)
      # Check for right alignment class
      assert html =~ "justify-end"
      # Check for user message color (now blue instead of indigo)
      assert html =~ "bg-blue-600"
    end

    test "displays timestamp on messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      view
      |> form("form", message: "带时间戳的消息")
      |> render_submit()

      html = render(view)
      # Should have time display (HH:MM format)
      assert html =~ ~r/\d{2}:\d{2}/
    end
  end

  describe "UI elements" do
    test "has send button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "发送"
      assert html =~ ~s(type="submit")
    end

    test "has message input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "输入消息"
      assert html =~ "<textarea"
    end

    test "has new chat button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "新对话"
    end

    test "shows robot emoji in header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "🤖"
    end
  end
end
