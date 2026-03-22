defmodule ClawdExWeb.Channels.SessionChannelTest do
  use ClawdExWeb.ChannelCase, async: false

  alias ClawdExWeb.Channels.GatewaySocket

  # A simple GenServer that mimics SessionWorker for find_session + get_state
  defmodule FakeSessionWorker do
    use GenServer

    def start_link(opts) do
      session_key = Keyword.fetch!(opts, :session_key)
      session_id = Keyword.fetch!(opts, :session_id)
      GenServer.start_link(__MODULE__, %{session_key: session_key, session_id: session_id}, name: via(session_key))
    end

    defp via(session_key) do
      {:via, Registry, {ClawdEx.SessionRegistry, session_key}}
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end
  end

  setup do
    # Dev mode: no token configured so connect succeeds with gateway auth
    Application.delete_env(:clawd_ex, :gateway_token)
    Application.delete_env(:clawd_ex, :api_token)

    # Create a real agent + session in DB
    {:ok, agent} =
      %ClawdEx.Agents.Agent{}
      |> ClawdEx.Agents.Agent.changeset(%{name: "ch_agent_#{System.unique_integer([:positive])}"})
      |> ClawdEx.Repo.insert()

    session_key = "test:ws:#{System.unique_integer([:positive])}"

    {:ok, session} =
      %ClawdEx.Sessions.Session{}
      |> ClawdEx.Sessions.Session.changeset(%{
        session_key: session_key,
        channel: "api",
        agent_id: agent.id
      })
      |> ClawdEx.Repo.insert()

    # Start a fake session worker that responds to :get_state
    {:ok, fake_pid} = FakeSessionWorker.start_link(
      session_key: session_key,
      session_id: session.id
    )

    {:ok, socket} = connect(GatewaySocket, %{"token" => "any"})

    on_exit(fn ->
      if Process.alive?(fake_pid), do: GenServer.stop(fake_pid)
      Application.delete_env(:clawd_ex, :gateway_token)
      Application.delete_env(:clawd_ex, :api_token)
    end)

    %{socket: socket, session_key: session_key, session: session, agent: agent}
  end

  describe "join/3" do
    test "joins an existing session", %{socket: socket, session_key: session_key} do
      assert {:ok, _, _socket} =
               subscribe_and_join(socket, "session:#{session_key}", %{})
    end

    test "rejects join for non-existent session", %{socket: socket} do
      assert {:error, %{reason: "session_not_found"}} =
               subscribe_and_join(socket, "session:nonexistent_key_xyz", %{})
    end
  end

  describe "handle_in typing" do
    test "broadcasts typing indicator to other subscribers", %{socket: socket, session_key: session_key} do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      push(socket, "typing", %{"is_typing" => true})

      # broadcast_from! sends to other subscribers (not the sender).
      # Since our test process is subscribed to the topic, we should see it.
      assert_broadcast "typing", %{user_id: "anonymous", is_typing: true}
    end
  end

  describe "handle_in subscribe" do
    test "acknowledges subscribe request", %{socket: socket, session_key: session_key} do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      ref = push(socket, "subscribe", %{})
      assert_reply ref, :ok
    end
  end

  describe "PubSub event relay" do
    test "pushes message:delta when receiving agent_chunk", %{
      socket: socket,
      session_key: session_key
    } do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      # Send agent_chunk directly to channel process to test handle_info
      send(socket.channel_pid, {:agent_chunk, "run_1", "partial text"})

      assert_push "message:delta", %{delta: "partial text"}
    end

    test "pushes message:start when receiving agent started", %{
      socket: socket,
      session_key: session_key
    } do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      send(socket.channel_pid, {:agent_status, "run_1", :started, %{model: "gpt-4"}})

      assert_push "message:start", %{role: "assistant", model: "gpt-4"}
    end

    test "pushes new_message when receiving agent done", %{
      socket: socket,
      session_key: session_key
    } do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      send(socket.channel_pid, {:agent_status, "run_1", :done, %{content_preview: "Hello!"}})

      assert_push "new_message", %{role: "assistant", content: "Hello!"}
    end

    test "pushes message:error when receiving agent error", %{
      socket: socket,
      session_key: session_key
    } do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      send(socket.channel_pid, {:agent_status, "run_1", :error, %{reason: "timeout"}})

      assert_push "message:error", %{error: "timeout"}
    end

    test "pushes message:segment when receiving agent segment", %{
      socket: socket,
      session_key: session_key
    } do
      {:ok, _, socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      send(socket.channel_pid, {:agent_segment, "run_1", "segment text", %{}})

      assert_push "message:segment", %{content: "segment text"}
    end

    test "auto-subscribes to PubSub agent topic after join", %{
      socket: socket,
      session_key: session_key,
      session: session
    } do
      {:ok, _, _socket} = subscribe_and_join(socket, "session:#{session_key}", %{})

      # Give after_join time to subscribe
      Process.sleep(100)

      # Broadcast via PubSub and verify the channel pushes it
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "agent:#{session.id}",
        {:agent_chunk, "run_2", "via pubsub"}
      )

      assert_push "message:delta", %{delta: "via pubsub"}
    end
  end
end
