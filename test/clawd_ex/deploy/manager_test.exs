defmodule ClawdEx.Deploy.ManagerTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Deploy.Manager

  setup do
    # Reset deploy state to avoid leaking state between tests
    Manager.reset_state()
    :ok
  end

  describe "status/0" do
    test "returns current deploy status" do
      assert {:ok, status} = Manager.status()
      assert is_binary(status.version)
      assert is_binary(status.git_sha)
      assert is_binary(status.started_at)
      assert is_integer(status.uptime_seconds)
      assert is_binary(status.environment)
    end
  end

  describe "history/0" do
    test "returns deploy history as a list" do
      assert {:ok, history} = Manager.history()
      assert is_list(history)
    end
  end

  describe "trigger/0" do
    test "starts a deployment and returns deploy record" do
      # Note: This will actually try to run deploy.sh, which may fail
      # in test environment, but the trigger itself should succeed
      assert {:ok, deploy} = Manager.trigger()
      assert deploy.status == "running"
      assert is_binary(deploy.id)
      assert is_binary(deploy.started_at)
      assert deploy.trigger == "api"

      # Wait for the async deploy to complete (it will likely fail in test env)
      Process.sleep(2_000)
    end

    test "rejects concurrent deploys" do
      # Trigger first deploy
      {:ok, _} = Manager.trigger()

      # Try to trigger another immediately
      assert {:error, :deploy_in_progress} = Manager.trigger()

      # Wait for the async deploy to complete
      Process.sleep(2_000)
    end
  end
end
