defmodule ClawdEx.Security.DmPairingTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Security.DmPairing
  alias ClawdEx.Agents.Agent

  setup do
    # Clear ETS cache
    if GenServer.whereis(DmPairing.Server), do: DmPairing.Server.clear()

    # Create a test agent with a known pairing code
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "test-agent-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    # Update with a known pairing code for testing
    {:ok, agent} =
      agent
      |> Ecto.Changeset.change(%{pairing_code: "testcode123"})
      |> Repo.update()

    %{agent: agent}
  end

  describe "Server.lookup/2" do
    test "returns :not_paired for unknown user" do
      assert :not_paired = DmPairing.Server.lookup("user999", "telegram")
    end

    test "returns {:ok, agent_id} after pairing" do
      %{agent: agent} = setup_agent()

      {:ok, _} = DmPairing.Server.pair("user1", "telegram", agent.pairing_code)

      assert {:ok, agent_id} = DmPairing.Server.lookup("user1", "telegram")
      assert agent_id == agent.id
    end

    test "different channels are independent" do
      %{agent: agent} = setup_agent()

      {:ok, _} = DmPairing.Server.pair("user2", "telegram", agent.pairing_code)

      assert {:ok, _} = DmPairing.Server.lookup("user2", "telegram")
      assert :not_paired = DmPairing.Server.lookup("user2", "discord")
    end
  end

  describe "Server.pair/3" do
    test "pairs user to agent with valid code", %{agent: agent} do
      assert {:ok, %{agent_id: id, agent_name: name}} =
               DmPairing.Server.pair("user3", "telegram", agent.pairing_code)

      assert id == agent.id
      assert name == agent.name
    end

    test "returns error for invalid code" do
      assert {:error, :invalid_code} =
               DmPairing.Server.pair("user4", "telegram", "bad_code")
    end

    test "re-pairing updates the binding", %{agent: agent} do
      # Create a second agent
      {:ok, agent2} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent2-#{System.unique_integer([:positive])}"})
        |> Repo.insert()

      {:ok, agent2} =
        agent2
        |> Ecto.Changeset.change(%{pairing_code: "code222"})
        |> Repo.update()

      # Pair to first agent
      {:ok, _} = DmPairing.Server.pair("user5", "telegram", agent.pairing_code)
      assert {:ok, id1} = DmPairing.Server.lookup("user5", "telegram")
      assert id1 == agent.id

      # Re-pair to second agent
      {:ok, _} = DmPairing.Server.pair("user5", "telegram", agent2.pairing_code)
      assert {:ok, id2} = DmPairing.Server.lookup("user5", "telegram")
      assert id2 == agent2.id
    end

    test "persists to database", %{agent: agent} do
      {:ok, _} = DmPairing.Server.pair("user6", "telegram", agent.pairing_code)

      # Check DB directly
      pairing = Repo.get_by(DmPairing, user_id: "user6", channel: "telegram")
      assert pairing != nil
      assert pairing.agent_id == agent.id
      assert pairing.paired_at != nil
    end
  end

  describe "Server.unpair/2" do
    test "removes an existing pairing", %{agent: agent} do
      {:ok, _} = DmPairing.Server.pair("user7", "telegram", agent.pairing_code)
      assert {:ok, _} = DmPairing.Server.lookup("user7", "telegram")

      assert :ok = DmPairing.Server.unpair("user7", "telegram")
      assert :not_paired = DmPairing.Server.lookup("user7", "telegram")
    end

    test "returns error for non-existent pairing" do
      assert {:error, :not_found} = DmPairing.Server.unpair("nonexistent", "telegram")
    end
  end

  describe "Ecto schema" do
    test "changeset validates required fields" do
      changeset = DmPairing.changeset(%DmPairing{}, %{})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :user_id)
      assert Keyword.has_key?(changeset.errors, :channel)
      assert Keyword.has_key?(changeset.errors, :agent_id)
    end
  end

  # Helper to avoid setup context issues with re-usable agent creation
  defp setup_agent do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "helper-agent-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent} =
      agent
      |> Ecto.Changeset.change(%{pairing_code: "helper#{System.unique_integer([:positive])}"})
      |> Repo.update()

    %{agent: agent}
  end
end
