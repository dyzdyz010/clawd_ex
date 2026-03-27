defmodule ClawdEx.Channels.ChannelBindingE2ETest do
  @moduledoc """
  End-to-end test for channel bindings.
  Creates an agent with a channel binding, verifies the session starts,
  sends a message through the session, and verifies a response comes back.

  Tagged with :e2e so it can be excluded from fast CI runs.
  """
  use ClawdEx.DataCase, async: false

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias ClawdEx.Agents.Agent
  alias ClawdEx.Channels.{BindingManager, ChannelBinding}
  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  setup do
    ensure_channel_registry()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        name: "e2e_binding_agent_#{System.unique_integer([:positive])}",
        active: true,
        auto_start: false,
        always_on: false
      })
      |> Repo.insert()

    %{agent: agent}
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

  @tag :e2e
  test "create binding → session starts → send message → get response", %{agent: agent} do
    config = %{"chat_id" => "-100e2e", "topic_id" => "42"}

    # 1. Create a channel binding
    assert {:ok, binding} = BindingManager.create_binding(agent.id, "telegram", config)
    assert binding.active == true
    expected_key = "telegram:-100e2e:topic:42:agent:#{agent.id}"
    assert binding.session_key == expected_key

    # 2. Verify session started automatically
    assert {:ok, _pid} = SessionManager.find_session(binding.session_key)

    # 3. Send a message through the session (calls LLM)
    result = SessionWorker.send_message(
      binding.session_key,
      "Reply with exactly: BINDING_TEST_OK",
      timeout: 60_000
    )

    # 4. Verify response comes back
    assert {:ok, response} = result
    assert is_binary(response)
    assert byte_size(response) > 0

    # The response should contain our expected phrase (LLM should follow instructions)
    assert String.contains?(response, "BINDING_TEST_OK"),
           "Expected response to contain 'BINDING_TEST_OK', got: #{String.slice(response, 0, 200)}"

    # 5. Verify we can remove the binding
    assert {:ok, _} = BindingManager.remove_binding(binding.id)

    # Give the supervisor a moment to fully terminate the child process
    Process.sleep(100)
    assert :not_found = SessionManager.find_session(binding.session_key)
  end
end
