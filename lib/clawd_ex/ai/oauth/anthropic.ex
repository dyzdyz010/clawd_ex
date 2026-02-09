defmodule ClawdEx.AI.OAuth.Anthropic do
  @moduledoc """
  Anthropic OAuth implementation for Claude Code tokens.

  Handles:
  - OAuth token refresh
  - PKCE-based login flow (future)

  OAuth flow uses:
  - Authorization URL: https://claude.ai/oauth/authorize
  - Token URL: https://console.anthropic.com/v1/oauth/token
  - Client ID: 9d1c250a-e61b-44d9-88ed-5944d1962f5e
  """

  require Logger

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @token_url "https://console.anthropic.com/v1/oauth/token"
  @authorize_url "https://claude.ai/oauth/authorize"
  @redirect_uri "https://console.anthropic.com/oauth/code/callback"
  @scopes "org:create_api_key user:profile user:inference"

  # Refresh tokens 5 minutes before expiry
  @expiry_buffer_ms 5 * 60 * 1000

  @doc """
  Refresh an OAuth token using the refresh token.

  Returns:
  - `{:ok, credentials}` with new access token, refresh token, and expiry
  - `{:error, reason}` on failure
  """
  @spec refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_token(refresh_token) do
    body = %{
      grant_type: "refresh_token",
      client_id: @client_id,
      refresh_token: refresh_token
    }

    headers = [
      {"content-type", "application/json"}
    ]

    case Req.post(@token_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        expires_in = response["expires_in"] || 3600
        expires_at = System.system_time(:millisecond) + expires_in * 1000 - @expiry_buffer_ms

        credentials = %{
          type: "oauth",
          provider: :anthropic,
          access: response["access_token"],
          refresh: response["refresh_token"],
          expires: expires_at
        }

        {:ok, credentials}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic OAuth refresh failed: status=#{status}, body=#{inspect(body)}")
        {:error, {:refresh_failed, status, body}}

      {:error, reason} ->
        Logger.error("Anthropic OAuth refresh request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Generate PKCE challenge for OAuth login.
  """
  @spec generate_pkce() :: {verifier :: String.t(), challenge :: String.t()}
  def generate_pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  @doc """
  Build the authorization URL for OAuth login.
  """
  @spec build_auth_url(String.t()) :: String.t()
  def build_auth_url(challenge) do
    params = %{
      "code" => "true",
      "client_id" => @client_id,
      "response_type" => "code",
      "redirect_uri" => @redirect_uri,
      "scope" => @scopes,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => generate_state()
    }

    "#{@authorize_url}?#{URI.encode_query(params)}"
  end

  @doc """
  Exchange authorization code for tokens.

  The auth_code should be in format "code#state" as returned by the OAuth flow.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code(auth_code, verifier) do
    [code, state] = String.split(auth_code, "#", parts: 2)

    body = %{
      grant_type: "authorization_code",
      client_id: @client_id,
      code: code,
      state: state,
      redirect_uri: @redirect_uri,
      code_verifier: verifier
    }

    headers = [
      {"content-type", "application/json"}
    ]

    case Req.post(@token_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        expires_in = response["expires_in"] || 3600
        expires_at = System.system_time(:millisecond) + expires_in * 1000 - @expiry_buffer_ms

        credentials = %{
          type: "oauth",
          provider: :anthropic,
          access: response["access_token"],
          refresh: response["refresh_token"],
          expires: expires_at
        }

        {:ok, credentials}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic OAuth code exchange failed: status=#{status}")
        {:error, {:exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Check if credentials need refresh.
  """
  @spec needs_refresh?(map()) :: boolean()
  def needs_refresh?(%{expires: expires}) when is_number(expires) do
    now = System.system_time(:millisecond)
    now >= expires
  end

  def needs_refresh?(_), do: true

  @doc """
  Get the required headers for OAuth API calls.
  Mimics Claude Code CLI headers.
  """
  @spec api_headers(String.t()) :: [{String.t(), String.t()}]
  def api_headers(access_token) do
    [
      {"authorization", "Bearer #{access_token}"},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-dangerous-direct-browser-access", "true"},
      {"anthropic-beta",
       "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14"},
      {"user-agent", "claude-cli/2.1.2 (external, cli)"},
      {"x-app", "cli"},
      {"accept", "application/json"}
    ]
  end

  # Claude Code canonical tool names (PascalCase)
  # Also includes mappings for ClawdEx tools that have different names
  @claude_code_tools ~w(Read Write Edit Bash Grep Glob AskUserQuestion EnterPlanMode ExitPlanMode KillShell NotebookEdit Skill Task TaskOutput TodoWrite WebFetch WebSearch Browser Canvas Process MemorySearch MemoryGet SessionStatus SessionsHistory SessionsList SessionsSend SessionsSpawn AgentsList Cron Gateway Message Nodes Image Tts Compact)

  # Custom tool name mappings (ClawdEx name -> Claude Code name)
  @tool_name_mappings %{
    "exec" => "Bash",
    "read" => "Read",
    "write" => "Write",
    "edit" => "Edit",
    "web_fetch" => "WebFetch",
    "web_search" => "WebSearch",
    "browser" => "Browser",
    "canvas" => "Canvas",
    "process" => "Process",
    "memory_search" => "MemorySearch",
    "memory_get" => "MemoryGet",
    "session_status" => "SessionStatus",
    "sessions_history" => "SessionsHistory",
    "sessions_list" => "SessionsList",
    "sessions_send" => "SessionsSend",
    "sessions_spawn" => "SessionsSpawn",
    "agents_list" => "AgentsList",
    "cron" => "Cron",
    "gateway" => "Gateway",
    "message" => "Message",
    "nodes" => "Nodes",
    "image" => "Image",
    "tts" => "Tts",
    "compact" => "Compact"
  }

  @doc """
  Get the required system prompt prefix for OAuth API calls.
  Claude Code OAuth requires this exact identity string.
  """
  @spec system_prompt_prefix() :: String.t()
  def system_prompt_prefix do
    "You are Claude Code, Anthropic's official CLI for Claude."
  end

  @doc """
  Convert tool name to Claude Code canonical casing (PascalCase).
  First checks custom mappings (e.g., exec -> Bash), then looks for case-insensitive match.
  """
  @spec to_claude_code_name(String.t()) :: String.t()
  def to_claude_code_name(name) do
    name_str = to_string(name)
    lower_name = String.downcase(name_str)

    # First check custom mappings (e.g., exec -> Bash)
    case Map.get(@tool_name_mappings, lower_name) do
      nil ->
        # Fall back to case-insensitive matching against known tools
        Enum.find(@claude_code_tools, name_str, fn cc_name ->
          String.downcase(cc_name) == lower_name
        end)

      mapped_name ->
        mapped_name
    end
  end

  @doc """
  Convert all tool names in a list to Claude Code casing.
  """
  @spec convert_tools_for_oauth([map()]) :: [map()]
  def convert_tools_for_oauth(tools) do
    Enum.map(tools, fn tool ->
      name = tool[:name] || tool["name"]
      converted_name = to_claude_code_name(name)

      tool
      |> Map.put(:name, converted_name)
      |> Map.put("name", converted_name)
    end)
  end

  @doc """
  Build system prompt with required OAuth prefix.
  """
  @spec build_system_prompt(String.t() | nil) :: list()
  def build_system_prompt(user_prompt) do
    prefix_block = %{
      "type" => "text",
      "text" => system_prompt_prefix(),
      "cache_control" => %{"type" => "ephemeral"}
    }

    if user_prompt && user_prompt != "" do
      user_block = %{
        "type" => "text",
        "text" => user_prompt,
        "cache_control" => %{"type" => "ephemeral"}
      }

      [prefix_block, user_block]
    else
      [prefix_block]
    end
  end

  # Private helpers

  defp generate_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
