defmodule ClawdEx.Tools.NodesTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Nodes

  describe "execute/2 validation" do
    test "returns error for unknown action" do
      assert {:error, msg} = Nodes.execute(%{"action" => "unknown_action"}, %{})
      assert msg =~ "Unknown action"
    end

    test "validates node is required for node-specific actions" do
      for action <- ~w(describe notify camera_snap camera_clip camera_list screen_record location_get) do
        assert {:error, msg} = Nodes.execute(%{"action" => action}, %{})
        assert msg =~ "node parameter is required", "Action #{action} should require node"
      end
    end

    test "validates command required for run and node required for run" do
      assert {:error, msg} = Nodes.execute(%{"action" => "run", "node" => "test"}, %{})
      assert msg =~ "command parameter is required"

      assert {:error, msg} = Nodes.execute(%{"action" => "run", "command" => ["echo"]}, %{})
      assert msg =~ "node parameter is required"
    end

    test "validates requestId required for approve and reject" do
      assert {:error, msg} = Nodes.execute(%{"action" => "approve"}, %{})
      assert msg =~ "requestId parameter is required"

      assert {:error, msg} = Nodes.execute(%{"action" => "reject"}, %{})
      assert msg =~ "requestId parameter is required"
    end
  end

  describe "parameter handling" do
    test "accepts both string and atom keys" do
      result_str = Nodes.execute(%{"action" => "describe", "node" => "test"}, %{})
      refute match?({:error, "node parameter is required" <> _}, result_str)

      result_atom = Nodes.execute(%{action: "describe", node: "test"}, %{})
      refute match?({:error, "node parameter is required" <> _}, result_atom)
    end
  end

  describe "gateway URL configuration" do
    test "uses various gateway URL sources without crashing" do
      assert {:error, _} = Nodes.execute(%{"action" => "status"}, %{})
      assert {:error, _} = Nodes.execute(%{"action" => "status", "gatewayUrl" => "http://custom:3030"}, %{})
      assert {:error, _} = Nodes.execute(%{"action" => "status"}, %{gateway_url: "http://context:3030"})
    end
  end

  describe "action parameter acceptance" do
    test "notify with all params passes validation" do
      result =
        Nodes.execute(
          %{
            "action" => "notify",
            "node" => "test-node",
            "title" => "Test",
            "body" => "Body",
            "priority" => "active"
          },
          %{}
        )

      assert match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, "node parameter is required" <> _}, result)
    end

    test "run with all params passes validation" do
      result =
        Nodes.execute(
          %{
            "action" => "run",
            "node" => "test-node",
            "command" => ["echo", "hello"],
            "cwd" => "/tmp",
            "commandTimeoutMs" => 5000
          },
          %{}
        )

      assert match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, "command parameter is required" <> _}, result)
    end
  end
end
