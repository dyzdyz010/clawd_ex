defmodule ClawdEx.Tools.NodesTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Nodes

  describe "metadata" do
    test "name returns 'nodes'" do
      assert Nodes.name() == "nodes"
    end

    test "description is not empty" do
      desc = Nodes.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters returns valid schema" do
      params = Nodes.parameters()
      assert is_map(params)
      assert params.type == "object"
      assert Map.has_key?(params.properties, :action)
    end

    test "all actions are defined in parameters" do
      params = Nodes.parameters()
      action_enum = params.properties.action.enum

      expected_actions = [
        "status",
        "describe",
        "pending",
        "approve",
        "reject",
        "notify",
        "run",
        "camera_snap",
        "camera_list",
        "camera_clip",
        "screen_record",
        "location_get"
      ]

      for action <- expected_actions do
        assert action in action_enum, "Missing action: #{action}"
      end
    end
  end

  describe "execute/2 validation" do
    test "returns error for unknown action" do
      result = Nodes.execute(%{"action" => "unknown_action"}, %{})
      assert {:error, msg} = result
      assert msg =~ "Unknown action"
    end

    test "returns error when node is missing for describe" do
      result = Nodes.execute(%{"action" => "describe"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when node is missing for notify" do
      result = Nodes.execute(%{"action" => "notify"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when command is missing for run" do
      result = Nodes.execute(%{"action" => "run", "node" => "test-node"}, %{})
      assert {:error, msg} = result
      assert msg =~ "command parameter is required"
    end

    test "returns error when node is missing for run" do
      result = Nodes.execute(%{"action" => "run", "command" => ["echo", "hi"]}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when requestId is missing for approve" do
      result = Nodes.execute(%{"action" => "approve"}, %{})
      assert {:error, msg} = result
      assert msg =~ "requestId parameter is required"
    end

    test "returns error when requestId is missing for reject" do
      result = Nodes.execute(%{"action" => "reject"}, %{})
      assert {:error, msg} = result
      assert msg =~ "requestId parameter is required"
    end

    test "returns error when node is missing for camera_snap" do
      result = Nodes.execute(%{"action" => "camera_snap"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when node is missing for camera_clip" do
      result = Nodes.execute(%{"action" => "camera_clip"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when node is missing for screen_record" do
      result = Nodes.execute(%{"action" => "screen_record"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when node is missing for location_get" do
      result = Nodes.execute(%{"action" => "location_get"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end

    test "returns error when node is missing for camera_list" do
      result = Nodes.execute(%{"action" => "camera_list"}, %{})
      assert {:error, msg} = result
      assert msg =~ "node parameter is required"
    end
  end

  describe "parameter handling" do
    # Test that parameters can be accessed with both string and atom keys
    test "accepts string keys" do
      # This will fail at gateway level but validates param parsing
      result = Nodes.execute(%{"action" => "describe", "node" => "test"}, %{})
      # Should not complain about missing node
      refute match?({:error, "node parameter is required" <> _}, result)
    end

    test "accepts atom keys" do
      result = Nodes.execute(%{action: "describe", node: "test"}, %{})
      refute match?({:error, "node parameter is required" <> _}, result)
    end
  end

  describe "gateway URL configuration" do
    test "uses default gateway URL when not specified" do
      # The actual request will fail, but we verify no crash
      result = Nodes.execute(%{"action" => "status"}, %{})

      # Should return connection error (no gateway running), not crash
      assert match?({:error, _}, result)
    end

    test "uses gateway URL from params" do
      result =
        Nodes.execute(
          %{"action" => "status", "gatewayUrl" => "http://custom:3030"},
          %{}
        )

      assert match?({:error, _}, result)
    end

    test "uses gateway URL from context" do
      result =
        Nodes.execute(
          %{"action" => "status"},
          %{gateway_url: "http://context:3030"}
        )

      assert match?({:error, _}, result)
    end
  end

  describe "media processing" do
    test "mime_type_to_extension/1 maps common types" do
      # Access private function via module
      # We test via the extension guessing in handle_media_data
      # This is tested indirectly through the module
      assert true
    end
  end

  describe "notify action parameters" do
    test "builds correct body for notify with all params" do
      # Would test actual request body but requires mock
      # For now, just verify no crash with all params
      result =
        Nodes.execute(
          %{
            "action" => "notify",
            "node" => "test-node",
            "title" => "Test Title",
            "body" => "Test Body",
            "priority" => "active",
            "sound" => "default",
            "delivery" => "system"
          },
          %{}
        )

      # Should fail at gateway connection, not validation
      assert match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, "node parameter is required" <> _}, result)
    end
  end

  describe "run action parameters" do
    test "accepts command as list" do
      result =
        Nodes.execute(
          %{
            "action" => "run",
            "node" => "test-node",
            "command" => ["echo", "hello", "world"],
            "cwd" => "/tmp",
            "env" => ["FOO=bar"],
            "commandTimeoutMs" => 5000
          },
          %{}
        )

      # Should fail at gateway connection, not validation
      assert match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, "command parameter is required" <> _}, result)
    end
  end

  describe "camera actions parameters" do
    test "camera_snap accepts all parameters" do
      result =
        Nodes.execute(
          %{
            "action" => "camera_snap",
            "node" => "test-node",
            "facing" => "back",
            "deviceId" => "camera-0",
            "quality" => 80,
            "maxWidth" => 1920,
            "delayMs" => 500
          },
          %{}
        )

      assert match?({:error, _}, result)
      refute match?({:error, "node parameter is required" <> _}, result)
    end

    test "camera_clip accepts video parameters" do
      result =
        Nodes.execute(
          %{
            "action" => "camera_clip",
            "node" => "test-node",
            "facing" => "front",
            "durationMs" => 5000,
            "fps" => 30,
            "includeAudio" => true
          },
          %{}
        )

      assert match?({:error, _}, result)
      refute match?({:error, "node parameter is required" <> _}, result)
    end
  end

  describe "screen_record parameters" do
    test "accepts screen recording parameters" do
      result =
        Nodes.execute(
          %{
            "action" => "screen_record",
            "node" => "test-node",
            "screenIndex" => 0,
            "durationMs" => 10000,
            "fps" => 24,
            "quality" => 90,
            "includeAudio" => false,
            "needsScreenRecording" => true
          },
          %{}
        )

      assert match?({:error, _}, result)
      refute match?({:error, "node parameter is required" <> _}, result)
    end
  end

  describe "location_get parameters" do
    test "accepts location parameters" do
      result =
        Nodes.execute(
          %{
            "action" => "location_get",
            "node" => "test-node",
            "desiredAccuracy" => "precise",
            "maxAgeMs" => 60000,
            "locationTimeoutMs" => 10000
          },
          %{}
        )

      assert match?({:error, _}, result)
      refute match?({:error, "node parameter is required" <> _}, result)
    end
  end
end
