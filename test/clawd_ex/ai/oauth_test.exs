defmodule ClawdEx.AI.OAuthTest do
  use ExUnit.Case, async: true

  alias ClawdEx.AI.OAuth
  alias ClawdEx.AI.OAuth.Anthropic, as: AnthropicOAuth

  describe "oauth_token?/1" do
    test "detects OAuth tokens" do
      assert OAuth.oauth_token?("sk-ant-oat-abc123")
      assert OAuth.oauth_token?("sk-ant-oat01-xyz789")
    end

    test "rejects regular API keys" do
      refute OAuth.oauth_token?("sk-ant-api-abc123")
      refute OAuth.oauth_token?("sk-1234567890")
      refute OAuth.oauth_token?(nil)
    end
  end

  describe "AnthropicOAuth.generate_pkce/0" do
    test "generates valid PKCE pair" do
      {verifier, challenge} = AnthropicOAuth.generate_pkce()

      assert is_binary(verifier)
      assert is_binary(challenge)
      assert byte_size(verifier) > 30
      assert byte_size(challenge) > 30

      # Verify challenge is SHA256 hash of verifier
      expected_challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      assert challenge == expected_challenge
    end
  end

  describe "AnthropicOAuth.build_auth_url/1" do
    test "builds valid authorization URL" do
      {_verifier, challenge} = AnthropicOAuth.generate_pkce()
      url = AnthropicOAuth.build_auth_url(challenge)

      assert String.starts_with?(url, "https://claude.ai/oauth/authorize")
      assert String.contains?(url, "client_id=")
      assert String.contains?(url, "code_challenge=#{URI.encode_www_form(challenge)}")
      assert String.contains?(url, "response_type=code")
      assert String.contains?(url, "redirect_uri=")
    end
  end

  describe "AnthropicOAuth.api_headers/1" do
    test "returns Claude Code compatible headers" do
      headers = AnthropicOAuth.api_headers("sk-ant-oat-test123")

      header_map = Map.new(headers)

      assert header_map["authorization"] == "Bearer sk-ant-oat-test123"
      assert header_map["anthropic-version"] == "2023-06-01"
      assert header_map["anthropic-dangerous-direct-browser-access"] == "true"
      assert String.contains?(header_map["anthropic-beta"], "oauth-2025-04-20")
      assert String.contains?(header_map["anthropic-beta"], "claude-code-20250219")
      assert String.contains?(header_map["user-agent"], "claude-cli")
      assert header_map["x-app"] == "cli"
    end
  end

  describe "AnthropicOAuth.build_system_prompt/1" do
    test "builds system prompt with Claude Code prefix" do
      blocks = AnthropicOAuth.build_system_prompt("Custom instructions")

      assert length(blocks) == 2

      [prefix_block, user_block] = blocks

      assert prefix_block["text"] == "You are Claude Code, Anthropic's official CLI for Claude."
      assert prefix_block["cache_control"]["type"] == "ephemeral"

      assert user_block["text"] == "Custom instructions"
      assert user_block["cache_control"]["type"] == "ephemeral"
    end

    test "builds system prompt without user instructions" do
      blocks = AnthropicOAuth.build_system_prompt(nil)

      assert length(blocks) == 1

      [prefix_block] = blocks
      assert prefix_block["text"] == "You are Claude Code, Anthropic's official CLI for Claude."
    end

    test "builds system prompt with empty user instructions" do
      blocks = AnthropicOAuth.build_system_prompt("")

      assert length(blocks) == 1
    end
  end

  describe "AnthropicOAuth.needs_refresh?/1" do
    test "returns true when token is expired" do
      expired = %{expires: System.system_time(:millisecond) - 1000}
      assert AnthropicOAuth.needs_refresh?(expired)
    end

    test "returns false when token is valid" do
      valid = %{expires: System.system_time(:millisecond) + 60_000}
      refute AnthropicOAuth.needs_refresh?(valid)
    end

    test "returns true for missing expires" do
      assert AnthropicOAuth.needs_refresh?(%{})
      assert AnthropicOAuth.needs_refresh?(nil)
    end
  end

  describe "AnthropicOAuth.system_prompt_prefix/0" do
    test "returns Claude Code identity" do
      prefix = AnthropicOAuth.system_prompt_prefix()
      assert prefix == "You are Claude Code, Anthropic's official CLI for Claude."
    end
  end
end
