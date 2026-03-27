defmodule ClawdEx.Agent.AutoStarterBindingTest do
  @moduledoc "Tests for AutoStarter channel binding integration"
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agent.AutoStarter
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Channels.ChannelBinding
  alias ClawdEx.Sessions.SessionManager

  setup do
    # Ensure Channel Registry is running and Telegram is registered
    ensure_channel_registry()
    :ok
  end

  defp ensure_channel_registry do
    case Process.whereis(ClawdEx.Channels.Registry) do
      nil ->
        {:ok, _} = ClawdEx.Channels.Registry.start_link()
        ClawdEx.Channels.Registry.register("telegram", ClawdEx.Channels.Telegram)

      _pid ->
        case ClawdEx.Channels.Registry.get("telegram") do
          nil -> ClawdEx.Channels.Registry.register("telegram", ClawdEx.Channels.Telegram)
          _ -> :ok
        end
    end
  end

  describe "AutoStarter with channel bindings" do
    test "creates binding sessions on boot" do
      # Create an auto_start agent with a channel binding
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "as_binding_test_#{System.unique_integer([:positive])}",
          active: true,
          auto_start: true,
          always_on: true
        })
        |> Repo.insert()

      config = %{"chat_id" => "-100500", "topic_id" => "77"}
      session_key = "telegram:-100500:topic:77:agent:#{agent.id}"

      {:ok, _binding} =
        %ChannelBinding{}
        |> ChannelBinding.changeset(%{
          agent_id: agent.id,
          channel: "telegram",
          channel_config: config,
          session_key: session_key,
          active: true
        })
        |> Repo.insert()

      # Start AutoStarter with short delay and custom name
      auto_name = :"as_binding_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AutoStarter.start_link(
          delay: 100,
          health_check_interval: 300_000,
          name: auto_name
        )

      # Wait for auto_start to fire
      Process.sleep(3_000)

      # The binding session should be running
      assert {:ok, _} = SessionManager.find_session(session_key)

      # The always_on fallback session should NOT exist (agent has bindings)
      assert :not_found = SessionManager.find_session("agent:#{agent.name}:always_on")

      # Cleanup
      GenServer.stop(pid)
      SessionManager.stop_session(session_key)
    end

    test "creates always_on session when no bindings exist" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "as_no_binding_#{System.unique_integer([:positive])}",
          active: true,
          auto_start: true,
          always_on: true
        })
        |> Repo.insert()

      # No bindings created

      {:ok, pid} =
        AutoStarter.start_link(
          delay: 100,
          health_check_interval: 300_000,
          name: :"as_no_binding_#{System.unique_integer([:positive])}"
        )

      Process.sleep(2_000)

      # Should have always_on session as fallback
      session_key = "agent:#{agent.name}:always_on"
      assert {:ok, _} = SessionManager.find_session(session_key)

      # Cleanup
      GenServer.stop(pid)
      SessionManager.stop_session(session_key)
    end
  end
end
