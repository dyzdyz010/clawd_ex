# 测试消息发送流程
alias ClawdEx.Sessions.{SessionManager, SessionWorker}

IO.puts "=== 测试开始 ==="

# 1. 启动会话
session_key = "test:#{System.unique_integer([:positive])}"
IO.puts "1. 启动会话: #{session_key}"

case SessionManager.start_session(session_key: session_key, channel: "test") do
  {:ok, pid} -> 
    IO.puts "   ✓ 会话启动成功: #{inspect(pid)}"
  {:error, reason} ->
    IO.puts "   ✗ 启动失败: #{inspect(reason)}"
    System.halt(1)
end

# 2. 发送简单消息
IO.puts "2. 发送消息: 'Hello'"
start_time = System.monotonic_time(:millisecond)

result = SessionWorker.send_message(session_key, "Hello, just say hi back briefly", timeout: 30_000)

elapsed = System.monotonic_time(:millisecond) - start_time
IO.puts "   耗时: #{elapsed}ms"

case result do
  {:ok, response} ->
    IO.puts "   ✓ 收到响应: #{String.slice(response, 0..100)}..."
  {:error, reason} ->
    IO.puts "   ✗ 错误: #{inspect(reason)}"
end

IO.puts "=== 测试完成 ==="
