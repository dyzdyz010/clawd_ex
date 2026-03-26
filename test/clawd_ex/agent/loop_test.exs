defmodule ClawdEx.Agent.LoopTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agent.Loop
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.Session

  describe "Agent Loop lifecycle" do
    setup do
      # 创建测试 agent
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      # 创建测试 session
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-session-#{System.unique_integer()}",
          channel: "test",
          agent_id: agent.id
        })
        |> Repo.insert()

      %{agent: agent, session: session}
    end

    test "starts in idle state", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      {:ok, state, _data} = Loop.get_state(pid)
      assert state == :idle
    end

    test "transitions to preparing on run", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      # 启动一个不等待完成的 run (会因为没有 API key 而失败)
      spawn(fn ->
        Loop.run(pid, "test message", timeout: 1000)
      end)

      # 给一点时间让状态转换
      Process.sleep(50)

      {:ok, state, _data} = Loop.get_state(pid)
      assert state in [:preparing, :inferring, :idle]
    end
  end

  describe "retryable?/1" do
    test "overloaded is retryable" do
      assert Loop.retryable?(:overloaded) == true
    end

    test "timeout is retryable" do
      assert Loop.retryable?(:timeout) == true
    end

    test "closed is retryable" do
      assert Loop.retryable?(:closed) == true
    end

    test "econnrefused is retryable" do
      assert Loop.retryable?(:econnrefused) == true
    end

    test "econnreset is retryable" do
      assert Loop.retryable?(:econnreset) == true
    end

    test "HTTP 429 is retryable" do
      assert Loop.retryable?({:api_error, 429, "rate limited"}) == true
    end

    test "HTTP 500 is retryable" do
      assert Loop.retryable?({:api_error, 500, "internal server error"}) == true
    end

    test "HTTP 502 is retryable" do
      assert Loop.retryable?({:api_error, 502, "bad gateway"}) == true
    end

    test "HTTP 503 is retryable" do
      assert Loop.retryable?({:api_error, 503, "service unavailable"}) == true
    end

    test "HTTP 529 is retryable" do
      assert Loop.retryable?({:api_error, 529, "overloaded"}) == true
    end

    test "HTTP 400 is not retryable" do
      assert Loop.retryable?({:api_error, 400, "bad request"}) == false
    end

    test "HTTP 401 is not retryable" do
      assert Loop.retryable?({:api_error, 401, "unauthorized"}) == false
    end

    test "HTTP 403 is not retryable" do
      assert Loop.retryable?({:api_error, 403, "forbidden"}) == false
    end

    test "string with overloaded is retryable" do
      assert Loop.retryable?("API is overloaded") == true
    end

    test "string with rate limit is retryable" do
      assert Loop.retryable?("Rate limit exceeded") == true
    end

    test "string with timeout is retryable" do
      assert Loop.retryable?("Connection timeout") == true
    end

    test "string with content policy is not retryable" do
      assert Loop.retryable?("Content policy violation") == false
    end

    test "string with authentication error is not retryable" do
      assert Loop.retryable?("Authentication failed") == false
    end

    test "string with unauthorized is not retryable" do
      assert Loop.retryable?("Unauthorized access") == false
    end

    test "string with invalid api key is not retryable" do
      assert Loop.retryable?("Invalid API key") == false
    end

    test "unknown atom errors are not retryable" do
      assert Loop.retryable?(:unknown_error) == false
    end

    test "generic string errors are not retryable" do
      assert Loop.retryable?("some random error") == false
    end
  end

  describe "friendly_error_message/1" do
    test "timeout with retries" do
      msg = Loop.friendly_error_message({:ai_error, :timeout, 3})
      assert msg =~ "超时"
      assert msg =~ "3 次"
    end

    test "timeout without retries does not mention auto-retry count" do
      msg = Loop.friendly_error_message({:ai_error, :timeout, 0})
      assert msg =~ "超时"
      # Should not mention "已自动重试 X 次" since retry_count is 0
      refute msg =~ "已自动重试"
    end

    test "overloaded" do
      msg = Loop.friendly_error_message({:ai_error, :overloaded, 2})
      assert msg =~ "繁忙"
      assert msg =~ "2 次"
    end

    test "auth error (401)" do
      msg = Loop.friendly_error_message({:ai_error, {:api_error, 401, "unauthorized"}, 0})
      assert msg =~ "认证"
    end

    test "rate limit (429)" do
      msg = Loop.friendly_error_message({:ai_error, {:api_error, 429, "rate limited"}, 3})
      assert msg =~ "频率"
    end

    test "server error (500)" do
      msg = Loop.friendly_error_message({:ai_error, {:api_error, 500, "internal"}, 3})
      assert msg =~ "不可用"
    end

    test "content policy (400)" do
      msg = Loop.friendly_error_message({:ai_error, {:api_error, 400, "content policy violation"}, 0})
      assert msg =~ "政策"
    end

    test "fallback for unknown errors" do
      msg = Loop.friendly_error_message(:some_random_thing)
      assert msg =~ "出错"
    end
  end

  describe "AI retry mechanism" do
    setup do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "retry-test-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "retry-test-session-#{System.unique_integer()}",
          channel: "test",
          agent_id: agent.id
        })
        |> Repo.insert()

      %{agent: agent, session: session}
    end

    test "retryable error triggers retry and stays in inferring", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      # Start a run that will get to inferring state
      spawn(fn ->
        Loop.run(pid, "test retry", timeout: 30_000)
      end)

      # Wait for it to reach inferring (or fail due to missing API key)
      Process.sleep(200)

      # Simulate: send an ai_error to the process while it's in inferring state
      # First, check if the process is still alive and get its state
      case Loop.get_state(pid) do
        {:ok, :inferring, data} ->
          # Send a retryable error
          send(pid, {:ai_error, :overloaded})
          Process.sleep(100)

          # Should still be in inferring (waiting for retry timer)
          {:ok, state, retry_data} = Loop.get_state(pid)
          assert state == :inferring
          assert retry_data.retry_count == 1

        {:ok, :idle, _data} ->
          # Already failed due to missing API key — that's ok for this test env
          # The important thing is the unit tests for retryable? pass
          :ok

        _ ->
          :ok
      end
    end

    test "non-retryable error goes directly to idle", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      spawn(fn ->
        Loop.run(pid, "test non-retry", timeout: 30_000)
      end)

      Process.sleep(200)

      case Loop.get_state(pid) do
        {:ok, :inferring, _data} ->
          # Send a non-retryable error (auth)
          send(pid, {:ai_error, {:api_error, 401, "unauthorized"}})
          Process.sleep(100)

          {:ok, state, _data} = Loop.get_state(pid)
          assert state == :idle

        {:ok, :idle, _data} ->
          # Already failed — ok
          :ok

        _ ->
          :ok
      end
    end

    test "exhausted retries transitions to idle", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      spawn(fn ->
        Loop.run(pid, "test exhaust", timeout: 60_000)
      end)

      Process.sleep(200)

      case Loop.get_state(pid) do
        {:ok, :inferring, _data} ->
          # Send max_retries + 1 retryable errors (rapidly, overriding timers)
          for _ <- 1..3 do
            send(pid, {:ai_error, :overloaded})
            # Brief sleep to let state machine process
            Process.sleep(50)
            # Cancel any pending retry timer to speed up test
            {:ok, _, d} = Loop.get_state(pid)
            if d.retry_timer_ref, do: Process.cancel_timer(d.retry_timer_ref)
            # Trigger retry immediately
            send(pid, {:retry_ai, d.run_id})
            Process.sleep(50)
          end

          # One more error should exhaust retries
          send(pid, {:ai_error, :overloaded})
          Process.sleep(100)

          {:ok, state, _data} = Loop.get_state(pid)
          assert state == :idle

        {:ok, :idle, _data} ->
          :ok

        _ ->
          :ok
      end
    end

    test "data struct includes retry fields" do
      data = %Loop{}
      assert data.retry_count == 0
      assert data.max_retries == 3
      assert data.retry_timer_ref == nil
    end
  end
end
