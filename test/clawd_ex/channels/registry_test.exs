defmodule ClawdEx.Channels.MockTestChannel do
  @behaviour ClawdEx.Channels.Channel

  @impl true
  def name, do: "mock-test"

  @impl true
  def ready?, do: true

  @impl true
  def send_message(chat_id, content, _opts) do
    {:ok, %{sent: true, chat_id: chat_id, content: content}}
  end

  @impl true
  def handle_message(_message), do: :ok
end

defmodule ClawdEx.Channels.RegistryTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Channels.Registry

  @mock_channel ClawdEx.Channels.MockTestChannel

  setup do
    # Ensure the Registry is running
    case GenServer.whereis(Registry) do
      nil -> Registry.start_link([])
      _pid -> :ok
    end

    # Clean all registered channels for test isolation
    Registry.list()
    |> Enum.each(fn entry -> Registry.unregister(entry.id) end)

    :ok
  end

  describe "register/3 + get/1 roundtrip" do
    test "registers and retrieves a channel" do
      assert :ok = Registry.register("test-chan", @mock_channel,
        label: "Test Channel",
        source: :plugin,
        plugin_id: "my-plugin"
      )

      entry = Registry.get("test-chan")

      assert entry.id == "test-chan"
      assert entry.module == @mock_channel
      assert entry.label == "Test Channel"
      assert entry.source == :plugin
      assert entry.plugin_id == "my-plugin"
    end

    test "get returns nil for unregistered channel" do
      assert Registry.get("nonexistent") == nil
    end

    test "register with defaults" do
      assert :ok = Registry.register("simple", @mock_channel)

      entry = Registry.get("simple")
      assert entry.label == "simple"
      assert entry.source == :builtin
      assert entry.plugin_id == nil
    end
  end

  describe "unregister/1" do
    test "removes a registered channel" do
      Registry.register("removeme", @mock_channel)
      assert Registry.get("removeme") != nil

      assert :ok = Registry.unregister("removeme")
      assert Registry.get("removeme") == nil
    end

    test "unregistering non-existent channel returns :ok" do
      assert :ok = Registry.unregister("does-not-exist")
    end
  end

  describe "list/0" do
    test "returns empty list when no channels registered" do
      assert Registry.list() == []
    end

    test "returns sorted entries" do
      Registry.register("zeta", @mock_channel, label: "Zeta")
      Registry.register("alpha", @mock_channel, label: "Alpha")
      Registry.register("mid", @mock_channel, label: "Mid")

      entries = Registry.list()

      assert length(entries) == 3
      ids = Enum.map(entries, & &1.id)
      assert ids == ["alpha", "mid", "zeta"]
    end
  end

  describe "send_message/4" do
    test "delegates to the registered channel module" do
      Registry.register("mock", @mock_channel)

      result = Registry.send_message("mock", "chat123", "hello world", [])

      assert {:ok, %{sent: true, chat_id: "chat123", content: "hello world"}} = result
    end

    test "returns error for unknown channel" do
      result = Registry.send_message("unknown", "chat1", "hi", [])

      assert {:error, {:unknown_channel, "unknown"}} = result
    end
  end

  describe "ready?/1" do
    test "returns false for unknown channel" do
      refute Registry.ready?("unknown-channel")
    end

    test "delegates to module's ready? for registered channel" do
      Registry.register("mock", @mock_channel)

      assert Registry.ready?("mock") == true
    end
  end
end
