defmodule ClawdEx.Agent.OutputManagerTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Agent.OutputManager

  describe "start_run/2 and deliver_segment/3" do
    test "broadcasts segment to output:{session_id} topic" do
      session_id = "session-#{System.unique_integer([:positive])}"
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      # Give the cast time to process
      Process.sleep(50)

      OutputManager.deliver_segment(run_id, "Hello from agent", %{step: 1})
      assert_receive {:output_segment, ^run_id, "Hello from agent", %{step: 1}}, 500
    end

    test "broadcasts multiple segments in order" do
      session_id = "session-#{System.unique_integer([:positive])}"
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      Process.sleep(50)

      OutputManager.deliver_segment(run_id, "Segment 1", %{})
      OutputManager.deliver_segment(run_id, "Segment 2", %{})
      OutputManager.deliver_segment(run_id, "Segment 3", %{})

      assert_receive {:output_segment, ^run_id, "Segment 1", _}, 500
      assert_receive {:output_segment, ^run_id, "Segment 2", _}, 500
      assert_receive {:output_segment, ^run_id, "Segment 3", _}, 500
    end
  end

  describe "deliver_progress/3" do
    test "broadcasts progress with :progress type in metadata" do
      session_id = "session-#{System.unique_integer([:positive])}"
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      Process.sleep(50)

      OutputManager.deliver_progress(run_id, "50% complete", %{percent: 50})

      assert_receive {:output_segment, ^run_id, "50% complete", metadata}, 500
      assert metadata.type == :progress
      assert metadata.percent == 50
    end

    test "does nothing for unregistered run" do
      run_id = "unregistered-#{System.unique_integer([:positive])}"

      # Should not crash
      OutputManager.deliver_progress(run_id, "progress", %{})
      Process.sleep(50)

      refute_receive {:output_segment, _, _, _}
    end
  end

  describe "deliver_complete/3" do
    test "broadcasts output_complete message" do
      session_id = "session-#{System.unique_integer([:positive])}"
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      Process.sleep(50)

      OutputManager.deliver_complete(run_id, "Final result", %{tokens: 100})

      assert_receive {:output_complete, ^run_id, "Final result", %{tokens: 100}}, 500
    end

    test "cleans up run state after completion" do
      session_id = "session-#{System.unique_integer([:positive])}"
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      Process.sleep(50)

      OutputManager.deliver_complete(run_id, "Done", %{})
      Process.sleep(50)

      # After completion, segments should go to fallback topic
      OutputManager.deliver_segment(run_id, "After complete", %{})

      # Should NOT receive on session topic (run was cleaned up)
      refute_receive {:output_segment, ^run_id, "After complete", _}, 200
    end
  end

  describe "graceful degradation" do
    test "broadcasts segment to fallback topic when run not registered" do
      run_id = "unregistered-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:run:#{run_id}")

      OutputManager.deliver_segment(run_id, "Fallback content", %{})

      assert_receive {:output_segment, ^run_id, "Fallback content", _}, 500
    end

    test "deliver_complete does not crash for unregistered run" do
      run_id = "unregistered-#{System.unique_integer([:positive])}"

      # Should not crash
      OutputManager.deliver_complete(run_id, "Final", %{})
      Process.sleep(50)

      refute_receive {:output_complete, _, _, _}
    end
  end

  describe "start_run/2" do
    test "accepts integer session_id" do
      session_id = System.unique_integer([:positive])
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      Process.sleep(50)

      OutputManager.deliver_segment(run_id, "Content", %{})
      assert_receive {:output_segment, ^run_id, "Content", _}, 500
    end

    test "accepts string session_id" do
      session_id = "string-session-#{System.unique_integer([:positive])}"
      run_id = "run-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")

      OutputManager.start_run(run_id, session_id)
      Process.sleep(50)

      OutputManager.deliver_segment(run_id, "Content", %{})
      assert_receive {:output_segment, ^run_id, "Content", _}, 500
    end
  end
end
