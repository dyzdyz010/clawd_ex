defmodule ClawdEx.Sessions.SessionWorkerTest do
  @moduledoc """
  Tests for SessionWorker GenServer.

  SessionWorker depends on DB (Session/Agent schemas), Registry,
  AgentLoop, and PubSub. We start workers via SessionManager so
  the supervision tree is consistent, then interact via the
  public API.
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  defp unique_key, do: "sw_test_#{:erlang.unique_integer([:positive])}"

  setup do
    key = unique_key()
    {:ok, pid} = SessionManager.start_session(session_key: key)

    on_exit(fn ->
      # Best-effort cleanup
      try do
        SessionManager.stop_session(key)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    %{key: key, pid: pid}
  end

  describe "start_link (via SessionManager)" do
    test "worker is alive and registered", %{key: key, pid: pid} do
      assert Process.alive?(pid)
      assert {:ok, ^pid} = SessionManager.find_session(key)
    end
  end

  describe "get_state/1" do
    test "returns session state map", %{key: key} do
      state = SessionWorker.get_state(key)

      assert state.session_key == key
      assert state.session_id != nil
      assert state.agent_id != nil
      assert is_binary(state.channel)
      assert is_boolean(state.agent_running)
      assert is_binary(state.streaming_content)
    end
  end

  describe "get_history/1" do
    test "returns empty list for fresh session", %{key: key} do
      messages = SessionWorker.get_history(key)
      assert messages == []
    end

    test "respects limit option", %{key: key} do
      # Insert some messages directly
      state = SessionWorker.get_state(key)

      for i <- 1..5 do
        %ClawdEx.Sessions.Message{}
        |> ClawdEx.Sessions.Message.changeset(%{
          session_id: state.session_id,
          role: :user,
          content: "Message #{i}"
        })
        |> Repo.insert!()
      end

      messages = SessionWorker.get_history(key, limit: 2)
      assert length(messages) == 2
    end
  end

  describe "stop_run/1" do
    test "does not crash the worker", %{key: key, pid: pid} do
      # Cast, should not crash the process
      SessionWorker.stop_run(key)
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "reset_streaming_cache/1" do
    test "clears streaming content", %{key: key} do
      SessionWorker.reset_streaming_cache(key)
      Process.sleep(50)
      state = SessionWorker.get_state(key)
      assert state.streaming_content == ""
    end
  end

  describe "handle_info catch-all" do
    test "ignores unknown messages without crashing", %{key: _key, pid: pid} do
      send(pid, {:random_unknown_message, 42})
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "send_message/2 - reset trigger" do
    test "/new resets session and returns confirmation", %{key: key} do
      result = SessionWorker.send_message(key, "/new")
      assert {:ok, msg} = result
      assert String.contains?(msg, "reset") or String.contains?(msg, "Reset")
    end
  end
end
