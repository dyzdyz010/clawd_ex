defmodule ClawdEx.AI.OAuth do
  @moduledoc """
  OAuth credential management for AI providers.
  
  Supports:
  - Anthropic Claude (Claude Code OAuth)
  - Token storage and automatic refresh
  """

  use GenServer
  require Logger

  @refresh_margin_ms 5 * 60 * 1000  # Refresh 5 minutes before expiry

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get API key for a provider. Handles OAuth token refresh automatically.
  Returns the access token for OAuth, or the API key for regular auth.
  """
  @spec get_api_key(atom()) :: {:ok, String.t()} | {:error, term()}
  def get_api_key(provider) do
    GenServer.call(__MODULE__, {:get_api_key, provider}, 30_000)
  end

  @doc """
  Check if API key is an OAuth token.
  """
  @spec oauth_token?(String.t()) :: boolean()
  def oauth_token?(api_key) when is_binary(api_key) do
    String.contains?(api_key, "sk-ant-oat")
  end
  def oauth_token?(_), do: false

  @doc """
  Store OAuth credentials for a provider.
  """
  @spec store_credentials(atom(), map()) :: :ok
  def store_credentials(provider, credentials) do
    GenServer.call(__MODULE__, {:store_credentials, provider, credentials})
  end

  @doc """
  Load credentials from Claude CLI config file.
  """
  @spec load_from_claude_cli() :: {:ok, map()} | {:error, term()}
  def load_from_claude_cli do
    GenServer.call(__MODULE__, :load_from_claude_cli)
  end

  @doc """
  Get current credentials (for debugging/status).
  """
  @spec get_credentials(atom()) :: {:ok, map()} | {:error, :not_found}
  def get_credentials(provider) do
    GenServer.call(__MODULE__, {:get_credentials, provider})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      credentials: %{},
      credentials_path: resolve_credentials_path()
    }

    # Try to load credentials from file
    state = load_credentials_from_file(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:get_api_key, provider}, _from, state) do
    case get_or_refresh_token(provider, state) do
      {:ok, api_key, new_state} ->
        {:reply, {:ok, api_key}, new_state}

      {:error, reason} ->
        # Fall back to environment variable or config
        case get_fallback_api_key(provider) do
          nil -> {:reply, {:error, reason}, state}
          key -> {:reply, {:ok, key}, state}
        end
    end
  end

  @impl true
  def handle_call({:store_credentials, provider, credentials}, _from, state) do
    new_credentials = Map.put(state.credentials, provider, credentials)
    new_state = %{state | credentials: new_credentials}
    save_credentials_to_file(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:load_from_claude_cli, _from, state) do
    case load_claude_cli_credentials() do
      {:ok, creds} ->
        new_credentials = Map.put(state.credentials, :anthropic, creds)
        new_state = %{state | credentials: new_credentials}
        save_credentials_to_file(new_state)
        {:reply, {:ok, creds}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_credentials, provider}, _from, state) do
    case Map.get(state.credentials, provider) do
      nil -> {:reply, {:error, :not_found}, state}
      creds -> {:reply, {:ok, creds}, state}
    end
  end

  # ============================================================================
  # Token Management
  # ============================================================================

  defp get_or_refresh_token(provider, state) do
    case Map.get(state.credentials, provider) do
      nil ->
        {:error, :no_credentials}

      %{type: "api_key", key: key} ->
        {:ok, key, state}

      %{type: "oauth", access: access, expires: expires} = creds ->
        if needs_refresh?(expires) do
          refresh_token(provider, creds, state)
        else
          {:ok, access, state}
        end

      %{"type" => "oauth", "access" => access, "expires" => expires} = creds ->
        if needs_refresh?(expires) do
          refresh_token(provider, atomize_keys(creds), state)
        else
          {:ok, access, state}
        end

      _ ->
        {:error, :invalid_credentials}
    end
  end

  defp needs_refresh?(expires) when is_number(expires) do
    now = System.system_time(:millisecond)
    now >= (expires - @refresh_margin_ms)
  end
  defp needs_refresh?(_), do: true

  defp refresh_token(:anthropic, creds, state) do
    case ClawdEx.AI.OAuth.Anthropic.refresh_token(creds.refresh) do
      {:ok, new_creds} ->
        Logger.info("Refreshed Anthropic OAuth token, expires: #{DateTime.from_unix!(new_creds.expires, :millisecond)}")
        
        new_credentials = Map.put(state.credentials, :anthropic, new_creds)
        new_state = %{state | credentials: new_credentials}
        save_credentials_to_file(new_state)
        
        # Also update Claude CLI credentials file if it exists
        write_claude_cli_credentials(new_creds)
        
        {:ok, new_creds.access, new_state}

      {:error, reason} ->
        Logger.error("Failed to refresh Anthropic OAuth token: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp refresh_token(provider, _creds, _state) do
    {:error, {:unsupported_provider, provider}}
  end

  # ============================================================================
  # Claude CLI Integration
  # ============================================================================

  defp load_claude_cli_credentials do
    path = Path.expand("~/.claude/.credentials.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"claudeAiOauth" => oauth}} ->
            creds = %{
              type: "oauth",
              provider: :anthropic,
              access: oauth["accessToken"],
              refresh: oauth["refreshToken"],
              expires: oauth["expiresAt"]
            }
            {:ok, creds}

          {:ok, _} ->
            {:error, :no_oauth_credentials}

          {:error, reason} ->
            {:error, {:json_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp write_claude_cli_credentials(creds) do
    path = Path.expand("~/.claude/.credentials.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            updated = Map.put(data, "claudeAiOauth", %{
              "accessToken" => creds.access,
              "refreshToken" => creds.refresh,
              "expiresAt" => creds.expires
            })

            case Jason.encode(updated, pretty: true) do
              {:ok, json} ->
                File.write(path, json)

              _ ->
                :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Credential Storage
  # ============================================================================

  defp resolve_credentials_path do
    app_dir = Application.get_env(:clawd_ex, :data_dir, "~/.clawd_ex")
    Path.expand(Path.join(app_dir, "oauth_credentials.json"))
  end

  defp load_credentials_from_file(state) do
    path = state.credentials_path

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            credentials = 
              data
              |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_keys(v)} end)
              |> Enum.into(%{})
            
            %{state | credentials: credentials}

          _ ->
            # Try loading from Claude CLI as fallback
            try_load_from_claude_cli(state)
        end

      _ ->
        # Try loading from Claude CLI as fallback
        try_load_from_claude_cli(state)
    end
  end

  defp try_load_from_claude_cli(state) do
    case load_claude_cli_credentials() do
      {:ok, creds} ->
        Logger.info("Loaded Anthropic credentials from Claude CLI")
        %{state | credentials: %{anthropic: creds}}

      {:error, _} ->
        state
    end
  end

  defp save_credentials_to_file(state) do
    path = state.credentials_path
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    data = 
      state.credentials
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), stringify_keys(v)} end)
      |> Enum.into(%{})

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        # Set file permissions to 600 (owner read/write only)
        File.chmod!(path, 0o600)

      {:error, reason} ->
        Logger.error("Failed to save credentials: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Fallback
  # ============================================================================

  defp get_fallback_api_key(:anthropic) do
    Application.get_env(:clawd_ex, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  defp get_fallback_api_key(:openai) do
    Application.get_env(:clawd_ex, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  defp get_fallback_api_key(:gemini) do
    Application.get_env(:clawd_ex, :gemini_api_key) ||
      System.get_env("GEMINI_API_KEY")
  end

  defp get_fallback_api_key(_), do: nil

  # ============================================================================
  # Helpers
  # ============================================================================

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end
  defp atomize_keys(other), do: other

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
  defp stringify_keys(other), do: other
end
