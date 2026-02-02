# 测试流式 API 请求
alias ClawdEx.AI.OAuth
alias ClawdEx.AI.OAuth.Anthropic, as: AnthropicOAuth

IO.puts "=== 流式 API 测试 ==="

case OAuth.get_api_key(:anthropic) do
  {:ok, api_key} ->
    IO.puts "1. 获取到 API key"
    
    headers = AnthropicOAuth.api_headers(api_key)
      |> Enum.reject(fn {k, _} -> k == "accept" end)
      |> Kernel.++([
        {"content-type", "application/json"},
        {"accept", "text/event-stream"}
      ])
    
    body = %{
      model: "claude-sonnet-4-20250514",
      max_tokens: 100,
      messages: [%{role: "user", content: "Say hi in one word"}],
      system: AnthropicOAuth.build_system_prompt("Test"),
      stream: true
    }
    
    IO.puts "2. 发送流式请求..."
    
    request = Req.new(
      url: "https://api.anthropic.com/v1/messages",
      method: :post,
      json: body,
      headers: headers,
      receive_timeout: 30_000,
      into: :self
    )
    
    case Req.request(request) do
      {:ok, response} ->
        IO.puts "3. 状态码: #{response.status}"
        IO.puts "4. 响应 body 类型: #{inspect(response.body)}"
        
        if response.status >= 200 and response.status < 300 do
          # 尝试接收流式数据
          async_ref = 
            case response.body do
              %{ref: ref} -> ref
              _ -> nil
            end
          
          IO.puts "5. Async ref: #{inspect(async_ref)}"
          
          if async_ref do
            receive do
              {^async_ref, {:data, data}} ->
                IO.puts "6. 收到数据: #{String.slice(data, 0..200)}..."
              {^async_ref, msg} ->
                IO.puts "6. 收到消息: #{inspect(msg)}"
            after
              5000 -> IO.puts "6. 超时"
            end
          end
        end
        
      {:error, reason} ->
        IO.puts "3. 请求失败: #{inspect(reason)}"
    end
    
  {:error, reason} ->
    IO.puts "获取 API key 失败: #{inspect(reason)}"
end
