defmodule ClawdEx.Plugins.Plugin do
  @moduledoc """
  Plugin behaviour and struct definition.

  Plugins are heavyweight extensions that can:
  - Register additional tools
  - Register additional AI providers
  - Hook into the message lifecycle
  """

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          module: module(),
          enabled: boolean(),
          config: map()
        }

  defstruct [:name, :version, :description, :module, enabled: true, config: %{}]

  @doc "Plugin name (unique identifier)"
  @callback name() :: String.t()

  @doc "Plugin version string"
  @callback version() :: String.t()

  @doc "Human-readable description"
  @callback description() :: String.t()

  @doc "Initialize plugin with config. Return {:ok, state} or {:error, reason}"
  @callback init(config :: map()) :: {:ok, state :: any()} | {:error, reason :: any()}

  @doc "Return list of tool modules this plugin provides"
  @callback tools() :: [module()]

  @doc "Return list of provider config maps this plugin provides"
  @callback providers() :: [map()]

  @doc "Hook called on each inbound message"
  @callback on_message(message :: map(), state :: any()) :: {:ok, state :: any()}

  @optional_callbacks [tools: 0, providers: 0, on_message: 2]
end
