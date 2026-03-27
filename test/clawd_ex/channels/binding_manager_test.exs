defmodule ClawdEx.Channels.BindingManagerTest do
  @moduledoc "Tests for BindingManager CRUD and session lifecycle"
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Channels.BindingManager
  alias ClawdEx.Channels.ChannelBinding
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.SessionManager

  setup do
    # Ensure Channel Registry is running and Telegram is registered
    ensure_channel_registry()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        name: "binding_test_agent_#{System.unique_integer([:positive])}",
        active: true,
        auto_start: false
      })
      |> Repo.insert()

    %{agent: agent}
  end

  defp ensure_channel_registry do
    # Channel Registry may not be started in test env
    case Process.whereis(ClawdEx.Channels.Registry) do
      nil ->
        {:ok, _} = ClawdEx.Channels.Registry.start_link()
        ClawdEx.Channels.Registry.register("telegram", ClawdEx.Channels.Telegram)

      _pid ->
        # Make sure telegram is registered
        case ClawdEx.Channels.Registry.get("telegram") do
          nil -> ClawdEx.Channels.Registry.register("telegram", ClawdEx.Channels.Telegram)
          _ -> :ok
        end
    end
  end

  describe "create_binding/3" do
    test "creates a binding with auto-generated session_key", %{agent: agent} do
      config = %{"chat_id" => "-100111", "topic_id" => "42"}

      assert {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)
      assert binding.agent_id == agent.id
      assert binding.channel == "telegram"
      assert binding.channel_config == config
      assert binding.session_key == "telegram:-100111:topic:42:agent:#{agent.id}"
      assert binding.active == true
    end

    test "creates binding without topic_id", %{agent: agent} do
      config = %{"chat_id" => "-100222"}

      assert {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)
      assert binding.session_key == "telegram:-100222:agent:#{agent.id}"
    end

    test "rejects duplicate binding", %{agent: agent} do
      config = %{"chat_id" => "-100333", "topic_id" => "1"}

      assert {:ok, _} = BindingManager.create_binding(agent.id, "telegram", config)
      assert {:error, _changeset} = BindingManager.create_binding(agent.id, "telegram", config)
    end

    test "starts a session for the new binding", %{agent: agent} do
      config = %{"chat_id" => "-100444", "topic_id" => "99"}

      assert {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)

      # Session should be running
      assert {:ok, _pid} = SessionManager.find_session(binding.session_key)

      # Cleanup
      SessionManager.stop_session(binding.session_key)
    end
  end

  describe "remove_binding/1" do
    test "deactivates a binding", %{agent: agent} do
      config = %{"chat_id" => "-100555", "topic_id" => "7"}
      {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)

      assert {:ok, updated} = BindingManager.remove_binding(binding.id)
      assert updated.active == false
    end

    test "stops the session on remove", %{agent: agent} do
      config = %{"chat_id" => "-100666", "topic_id" => "8"}
      {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)

      # Verify session exists
      assert {:ok, _pid} = SessionManager.find_session(binding.session_key)

      # Remove
      assert {:ok, _} = BindingManager.remove_binding(binding.id)

      # Session should be gone
      assert :not_found = SessionManager.find_session(binding.session_key)
    end

    test "returns error for non-existent binding" do
      assert {:error, :not_found} = BindingManager.remove_binding(999_999_999)
    end
  end

  describe "list_bindings/1" do
    test "lists all bindings for an agent", %{agent: agent} do
      config1 = %{"chat_id" => "-100777", "topic_id" => "1"}
      config2 = %{"chat_id" => "-100777", "topic_id" => "2"}

      {:ok, _} = BindingManager.create_binding(agent.id, "telegram", config1)
      {:ok, _} = BindingManager.create_binding(agent.id, "telegram", config2)

      bindings = BindingManager.list_bindings(agent.id)
      assert length(bindings) == 2

      # Cleanup
      Enum.each(bindings, fn b -> SessionManager.stop_session(b.session_key) end)
    end

    test "returns empty list for agent with no bindings" do
      {:ok, agent2} =
        %Agent{}
        |> Agent.changeset(%{name: "no_bindings_#{System.unique_integer([:positive])}", active: true})
        |> Repo.insert()

      assert BindingManager.list_bindings(agent2.id) == []
    end
  end

  describe "list_active_bindings/0" do
    test "returns only active bindings", %{agent: agent} do
      config = %{"chat_id" => "-100888", "topic_id" => "3"}
      {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)

      active_bindings = BindingManager.list_active_bindings()
      assert Enum.any?(active_bindings, fn b -> b.id == binding.id end)

      # Deactivate
      BindingManager.remove_binding(binding.id)

      active_bindings = BindingManager.list_active_bindings()
      refute Enum.any?(active_bindings, fn b -> b.id == binding.id end)
    end
  end

  describe "start_all_binding_sessions/0" do
    test "starts sessions for all active bindings", %{agent: agent} do
      config1 = %{"chat_id" => "-100999", "topic_id" => "11"}
      config2 = %{"chat_id" => "-100999", "topic_id" => "12"}

      # Create bindings directly in DB (not via create_binding which auto-starts)
      {:ok, b1} =
        %ChannelBinding{}
        |> ChannelBinding.changeset(%{
          agent_id: agent.id,
          channel: "telegram",
          channel_config: config1,
          session_key: "telegram:-100999:topic:11:agent:#{agent.id}",
          active: true
        })
        |> Repo.insert()

      {:ok, b2} =
        %ChannelBinding{}
        |> ChannelBinding.changeset(%{
          agent_id: agent.id,
          channel: "telegram",
          channel_config: config2,
          session_key: "telegram:-100999:topic:12:agent:#{agent.id}",
          active: true
        })
        |> Repo.insert()

      # Start all
      count = BindingManager.start_all_binding_sessions()
      assert count >= 2

      # Sessions should be running
      assert {:ok, _} = SessionManager.find_session(b1.session_key)
      assert {:ok, _} = SessionManager.find_session(b2.session_key)

      # Cleanup
      SessionManager.stop_session(b1.session_key)
      SessionManager.stop_session(b2.session_key)
    end
  end

  describe "ensure_binding_session/1" do
    test "starts session if not running", %{agent: agent} do
      binding = %ChannelBinding{
        id: nil,
        agent_id: agent.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-101010", "topic_id" => "20"},
        session_key: "telegram:-101010:topic:20:agent:#{agent.id}",
        active: true
      }

      # Insert into DB first
      {:ok, binding} =
        %ChannelBinding{}
        |> ChannelBinding.changeset(%{
          agent_id: agent.id,
          channel: "telegram",
          channel_config: binding.channel_config,
          session_key: binding.session_key,
          active: true
        })
        |> Repo.insert()

      assert {:ok, pid} = BindingManager.ensure_binding_session(binding)
      assert is_pid(pid)

      # Cleanup
      SessionManager.stop_session(binding.session_key)
    end

    test "skips inactive bindings", %{agent: agent} do
      binding = %ChannelBinding{
        agent_id: agent.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-101111"},
        session_key: "telegram:-101111:agent:#{agent.id}",
        active: false
      }

      assert :skip = BindingManager.ensure_binding_session(binding)
    end
  end

  describe "find_binding_for_channel/2" do
    test "finds binding matching channel config", %{agent: agent} do
      config = %{"chat_id" => "-102222", "topic_id" => "30"}

      {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)

      found = BindingManager.find_binding_for_channel("telegram", config)
      assert found.id == binding.id

      # Cleanup
      SessionManager.stop_session(binding.session_key)
    end

    test "returns nil when no binding matches" do
      config = %{"chat_id" => "-109999", "topic_id" => "999"}
      assert BindingManager.find_binding_for_channel("telegram", config) == nil
    end
  end
end
