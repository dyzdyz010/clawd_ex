defmodule ClawdEx.Browser.ServerTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Browser.Server
  alias ClawdEx.Browser.CDP

  setup do
    # Ensure CDP is running (may already be started by application)
    unless Process.whereis(CDP) do
      start_supervised!({CDP, name: CDP})
    end

    # Stop existing Server if running, then start fresh
    if pid = Process.whereis(Server) do
      GenServer.stop(pid, :normal, 5000)
    end

    start_supervised!({Server, name: Server})

    :ok
  end

  describe "status/0" do
    test "returns stopped status when browser is not running" do
      status = Server.status()

      assert status.status == "stopped"
      assert status.connected == false
    end
  end

  describe "start_browser/1" do
    @tag :browser
    @tag :integration
    test "starts browser in headless mode" do
      # 这个测试需要安装 Chrome/Chromium
      case Server.start_browser(headless: true) do
        {:ok, result} ->
          assert result.status == "running"
          assert result.headless == true
          assert is_binary(result.ws_url)

          # 清理
          Server.stop_browser()

        {:error, :chrome_not_found} ->
          # Chrome 未安装，跳过测试
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end

  describe "list_tabs/0" do
    test "returns error when browser is not running" do
      # 确保浏览器已停止
      Server.stop_browser()

      assert {:error, :not_running} = Server.list_tabs()
    end
  end

  describe "open_tab/1" do
    test "returns error when browser is not running" do
      assert {:error, :not_running} = Server.open_tab("https://example.com")
    end
  end

  describe "close_tab/1" do
    test "returns error when browser is not running" do
      assert {:error, :not_running} = Server.close_tab("some-target-id")
    end
  end
end
