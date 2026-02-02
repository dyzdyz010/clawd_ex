# 测试工具调用流程
alias ClawdEx.Sessions.{SessionManager, SessionWorker}

IO.puts "=== 工具调用测试 ==="

# 1. 启动会话
session_key = "test:tools:#{System.unique_integer([:positive])}"
IO.puts "1. 启动会话: #{session_key}"

case SessionManager.start_session(session_key: session_key, channel: "test") do
  {:ok, pid} -> 
    IO.puts "   ✓ 会话启动成功"
  {:error, reason} ->
    IO.puts "   ✗ 启动失败: #{inspect(reason)}"
    System.halt(1)
end

# 2. 测试 web_search 工具
IO.puts "2. 测试工具调用 (web_search)..."
start_time = System.monotonic_time(:millisecond)

result = SessionWorker.send_message(
  session_key, 
  "Search the web for 'Elixir programming language' and tell me what it is in one sentence",
  timeout: 60_000
)

elapsed = System.monotonic_time(:millisecond) - start_time
IO.puts "   耗时: #{elapsed}ms"

case result do
  {:ok, response} ->
    IO.puts "   ✓ 收到响应: #{String.slice(response, 0..200)}..."
  {:error, reason} ->
    IO.puts "   ✗ 错误: #{inspect(reason)}"
end

IO.puts "=== 测试完成 ==="
