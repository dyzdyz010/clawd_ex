defmodule ClawdEx.Plugins.Plugin do
  @moduledoc """
  Plugin behaviour and struct definition.

  Plugins are heavyweight extensions that can:
  - Register additional tools
  - Register additional channels
  - Register additional AI providers
  - Hook into the message lifecycle

  Two runtime types:
  - `:beam` — native Elixir plugin, loaded via Code.ensure_loaded
  - `:node` — Node.js plugin, bridged via JSON-RPC sidecar
  """

  @type plugin_type :: :beam | :node
  @type capability :: :tools | :channels | :providers | :hooks | :skills

  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type channel_spec :: %{
          id: String.t(),
          label: String.t(),
          module: module() | nil
        }

  @type provider_spec :: map()

  @type hook_spec :: %{
          event: String.t(),
          handler: (map(), map() -> any())
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          plugin_type: plugin_type(),
          module: module() | nil,
          enabled: boolean(),
          config: map(),
          path: String.t() | nil,
          capabilities: [capability()],
          status: :loaded | :disabled | :error,
          error: String.t() | nil
        }

  defstruct [
    :id,
    :name,
    :version,
    :description,
    :module,
    :path,
    :error,
    plugin_type: :beam,
    enabled: true,
    config: %{},
    capabilities: [],
    status: :loaded
  ]

  # ============================================================================
  # Behaviour — Elixir plugins implement these callbacks
  # ============================================================================

  @doc "Plugin unique identifier"
  @callback id() :: String.t()

  @doc "Plugin display name"
  @callback name() :: String.t()

  @doc "Plugin version string"
  @callback version() :: String.t()

  @doc "Human-readable description"
  @callback description() :: String.t()

  @doc "Plugin type: :beam (native Elixir) or :node (Node.js bridged)"
  @callback plugin_type() :: plugin_type()

  @doc "List of capabilities this plugin provides"
  @callback capabilities() :: [capability()]

  @doc "Initialize plugin with config. Return {:ok, state} or {:error, reason}"
  @callback init(config :: map()) :: {:ok, state :: any()} | {:error, reason :: any()}

  @doc "Graceful shutdown"
  @callback stop(state :: any()) :: :ok

  @doc "Return list of tool specs this plugin provides"
  @callback tools() :: [tool_spec()]

  @doc "Return list of channel specs this plugin provides"
  @callback channels() :: [channel_spec()]

  @doc "Return list of provider config maps this plugin provides"
  @callback providers() :: [provider_spec()]

  @doc "Return list of hook specs"
  @callback hooks() :: [hook_spec()]

  @doc "Handle a tool call from this plugin"
  @callback handle_tool_call(tool_name :: String.t(), params :: map(), context :: map()) ::
              {:ok, any()} | {:error, any()}

  @doc "Hook called on each inbound message"
  @callback on_message(message :: map(), state :: any()) :: {:ok, state :: any()}

  @optional_callbacks [
    tools: 0,
    channels: 0,
    providers: 0,
    hooks: 0,
    handle_tool_call: 3,
    on_message: 2,
    stop: 1
  ]
end
