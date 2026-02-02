# 测试 API 请求
alias ClawdEx.AI.OAuth
alias ClawdEx.AI.OAuth.Anthropic, as: AnthropicOAuth

IO.puts "=== API 测试 ==="

case OAuth.get_api_key(:anthropic) do
  {:ok, api_key} ->
    IO.puts "1. 获取到 API key: #{String.slice(api_key, 0..20)}..."
    IO.puts "2. 是否 OAuth token: #{OAuth.oauth_token?(api_key)}"
    
    headers = AnthropicOAuth.api_headers(api_key)
    IO.puts "3. Headers:"
    Enum.each(headers, fn {k, v} -> IO.puts "   #{k}: #{String.slice(v, 0..50)}..." end)
    
    # 发送测试请求
    body = %{
      model: "claude-sonnet-4-20250514",
      max_tokens: 100,
      messages: [%{role: "user", content: "Hi"}],
      system: AnthropicOAuth.build_system_prompt("Test")
    }
    
    IO.puts "4. 发送请求..."
    
    headers = headers
      |> Enum.reject(fn {k, _} -> k == "accept" end)
      |> Kernel.++([
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ])
    
    case Req.post("https://api.anthropic.com/v1/messages", json: body, headers: headers) do
      {:ok, %{status: status, body: resp_body}} ->
        IO.puts "5. 状态码: #{status}"
        IO.puts "6. 响应: #{inspect(resp_body) |> String.slice(0..500)}"
      {:error, reason} ->
        IO.puts "5. 请求失败: #{inspect(reason)}"
    end
    
  {:error, reason} ->
    IO.puts "获取 API key 失败: #{inspect(reason)}"
end
