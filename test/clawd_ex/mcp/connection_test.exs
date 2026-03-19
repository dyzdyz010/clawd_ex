defmodule ClawdEx.MCP.ConnectionTest do
  use ExUnit.Case, async: false

  alias ClawdEx.MCP.Connection

  @fake_server_path Path.expand("../../support/fake_mcp_server.exs", __DIR__)

  setup do
    # Ensure MCP Registry is available for via_name lookups
    case Registry.start_link(keys: :unique, name: ClawdEx.MCP.Registry) do
      {:ok, pid} -> on_exit(fn -> Process.exit(pid, :normal) end)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp elixir_path do
    System.find_executable("elixir") || raise "elixir not found in PATH"
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  # Start a connection to the fake MCP server
  defp start_fake_connection(name, extra_args \\ []) do
    opts = [
      name: name,
      command: elixir_path(),
      args: [@fake_server_path | extra_args],
      gen_name: nil
    ]

    Connection.start_link(opts)
  end

  # Wait for connection to become ready
  defp wait_ready(pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_ready_loop(pid, deadline)
  end

  defp wait_ready_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case Connection.status(pid) do
        {:ok, %{status: :ready}} -> :ok
        {:ok, %{status: :error}} -> {:error, :init_failed}
        _ ->
          Process.sleep(50)
          wait_ready_loop(pid, deadline)
      end
    end
  end

  # ============================================================================
  # start_link and basic status
  # ============================================================================

  describe "start_link/1 and status/1" do
    test "starts a connection process" do
      name = unique_name("test-start")
      opts = [name: name, command: "cat", args: [], gen_name: nil]

      {:ok, pid} = Connection.start_link(opts)
      assert is_pid(pid)
      assert Process.alive?(pid)

      Connection.stop(pid)
    end

    test "returns error for non-existent server via noproc" do
      assert {:error, :not_running} = Connection.status({:global, :nonexistent_server})
    end
  end

  # ============================================================================
  # Connection Startup + Initialize Handshake
  # ============================================================================

  describe "initialization handshake" do
    test "completes initialization with fake MCP server" do
      name = unique_name("test-init")
      {:ok, pid} = start_fake_connection(name)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      assert :ok = wait_ready(pid)

      {:ok, info} = Connection.status(pid)
      assert info.status == :ready
      assert info.server_info["name"] == "fake-mcp-server"
      assert info.server_info["version"] == "1.0.0"
      assert info.capabilities["tools"] == %{}
    end

    test "reports error when init fails" do
      name = unique_name("test-fail-init")
      {:ok, pid} = start_fake_connection(name, ["--fail-init"])

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      # Wait for init to be processed
      Process.sleep(2_000)

      {:ok, info} = Connection.status(pid)
      # Server info should remain nil on failed init
      assert info.server_info == nil
    end
  end

  # ============================================================================
  # tools/list
  # ============================================================================

  describe "list_tools/2" do
    setup do
      name = unique_name("test-list")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      %{pid: pid}
    end

    test "returns tools from server", %{pid: pid} do
      assert {:ok, tools} = Connection.list_tools(pid)
      assert is_list(tools)
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1["name"])
      assert "echo" in tool_names
      assert "add" in tool_names
    end

    test "tools have correct schema", %{pid: pid} do
      {:ok, tools} = Connection.list_tools(pid)

      echo_tool = Enum.find(tools, &(&1["name"] == "echo"))
      assert echo_tool["description"] == "Echo back the input"
      assert echo_tool["inputSchema"]["type"] == "object"
      assert echo_tool["inputSchema"]["properties"]["message"]["type"] == "string"

      add_tool = Enum.find(tools, &(&1["name"] == "add"))
      assert add_tool["description"] == "Add two numbers"
      assert add_tool["inputSchema"]["required"] == ["a", "b"]
    end

    test "returns error when not ready" do
      name = unique_name("test-notready")
      opts = [name: name, command: "cat", args: [], gen_name: nil]

      {:ok, pid} = Connection.start_link(opts)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      # cat won't complete handshake
      assert {:error, _} = Connection.list_tools(pid, 500)
    end
  end

  # ============================================================================
  # tools/call
  # ============================================================================

  describe "call_tool/4" do
    setup do
      name = unique_name("test-call")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      %{pid: pid}
    end

    test "calls echo tool successfully", %{pid: pid} do
      assert {:ok, result} = Connection.call_tool(pid, "echo", %{"message" => "hello world"})

      assert result["content"] == [
               %{"type" => "text", "text" => "hello world"}
             ]
    end

    test "calls add tool successfully", %{pid: pid} do
      assert {:ok, result} = Connection.call_tool(pid, "add", %{"a" => 3, "b" => 4})

      assert result["content"] == [
               %{"type" => "text", "text" => "7"}
             ]
    end

    test "handles unknown tool", %{pid: pid} do
      assert {:ok, result} = Connection.call_tool(pid, "nonexistent", %{})
      assert result["isError"] == true
    end

    test "returns error when not ready" do
      name = unique_name("test-calltool-notready")
      opts = [name: name, command: "cat", args: [], gen_name: nil]

      {:ok, pid} = Connection.start_link(opts)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      assert {:error, _} = Connection.call_tool(pid, "some_tool", %{}, 500)
    end
  end

  # ============================================================================
  # ping
  # ============================================================================

  describe "ping/2" do
    test "pings server successfully" do
      name = unique_name("test-ping")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      assert :ok = Connection.ping(pid)
    end
  end

  # ============================================================================
  # Status
  # ============================================================================

  describe "status/1" do
    test "returns full connection info" do
      name = unique_name("test-status")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      {:ok, info} = Connection.status(pid)

      assert info.name == name
      assert info.status == :ready
      assert is_map(info.server_info)
      assert is_map(info.capabilities)
    end
  end

  # ============================================================================
  # Buffer handling (sequential operations)
  # ============================================================================

  describe "buffer handling" do
    test "handles multiple rapid sequential calls" do
      name = unique_name("test-buffer")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      # Multiple rapid calls to exercise the buffer
      for i <- 1..5 do
        assert {:ok, result} =
                 Connection.call_tool(pid, "echo", %{"message" => "msg-#{i}"})

        assert result["content"] == [
                 %{"type" => "text", "text" => "msg-#{i}"}
               ]
      end
    end

    test "alternating list_tools and call_tool works" do
      name = unique_name("test-interleave")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Connection.stop(pid)
      end)

      assert {:ok, tools} = Connection.list_tools(pid)
      assert length(tools) == 2

      assert {:ok, result} = Connection.call_tool(pid, "add", %{"a" => 1, "b" => 2})
      assert result["content"] == [%{"type" => "text", "text" => "3"}]

      assert {:ok, tools2} = Connection.list_tools(pid)
      assert length(tools2) == 2
    end
  end

  # ============================================================================
  # Stop
  # ============================================================================

  describe "stop/1" do
    test "stops the connection cleanly" do
      name = unique_name("test-stop")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      assert :ok = Connection.stop(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "stop on dead process returns ok" do
      assert :ok = Connection.stop({:global, :nonexistent_connection})
    end
  end

  # ============================================================================
  # Server process exit
  # ============================================================================

  describe "server process exit" do
    test "connection detects server exit" do
      name = unique_name("test-exit")
      {:ok, pid} = start_fake_connection(name)
      :ok = wait_ready(pid)

      ref = Process.monitor(pid)

      # Stop the connection (which closes the port)
      Connection.stop(pid)

      # Should receive DOWN
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end
end
