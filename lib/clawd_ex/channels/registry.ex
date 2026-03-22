defmodule ClawdEx.Channels.Registry do
  @moduledoc """
  Dynamic Channel Registry.

  Replaces hardcoded channel routing in ChannelDispatcher.
  Channels register themselves at startup, and plugin-provided
  channels register via Plugins.Manager.

  Each channel entry has:
  - `id` — unique channel identifier (e.g. "telegram", "discord", "feishu")
  - `module` — the module implementing ClawdEx.Channels.Channel behaviour
  - `label` — human-readable name
  - `source` — :builtin | :plugin
  - `plugin_id` — which plugin provided this channel (nil for builtins)
  """

  use GenServer
  require Logger

  @type channel_entry :: %{
          id: String.t(),
          module: module(),
          label: String.t(),
          source: :builtin | :plugin,
          plugin_id: String.t() | nil
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a channel"
  @spec register(String.t(), module(), keyword()) :: :ok
  def register(channel_id, module, opts \\ []) do
    GenServer.call(__MODULE__, {:register, channel_id, module, opts})
  end

  @doc "Unregister a channel"
  @spec unregister(String.t()) :: :ok
  def unregister(channel_id) do
    GenServer.call(__MODULE__, {:unregister, channel_id})
  end

  @doc "Get a channel entry by id"
  @spec get(String.t()) :: channel_entry() | nil
  def get(channel_id) do
    GenServer.call(__MODULE__, {:get, channel_id})
  end

  @doc "List all registered channels"
  @spec list() :: [channel_entry()]
  def list do
    GenServer.call(__MODULE__, :list)
  catch
    :exit, _ -> []
  end

  @doc """
  Send a message through the channel registry.
  Looks up the channel by id and delegates to its module.
  """
  @spec send_message(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, any()} | {:error, term()}
  def send_message(channel_id, chat_id, content, opts \\ []) do
    case get(channel_id) do
      nil ->
        {:error, {:unknown_channel, channel_id}}

      %{module: module} ->
        module.send_message(chat_id, content, opts)
    end
  end

  @doc "Check if a channel is registered and ready"
  @spec ready?(String.t()) :: boolean()
  def ready?(channel_id) do
    case get(channel_id) do
      nil -> false
      %{module: module} -> module.ready?()
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{channels: %{}}}
  end

  @impl true
  def handle_call({:register, channel_id, module, opts}, _from, state) do
    entry = %{
      id: channel_id,
      module: module,
      label: Keyword.get(opts, :label, channel_id),
      source: Keyword.get(opts, :source, :builtin),
      plugin_id: Keyword.get(opts, :plugin_id)
    }

    Logger.info("Channel registered: #{channel_id} (#{entry.source})")
    {:reply, :ok, put_in(state, [:channels, channel_id], entry)}
  end

  @impl true
  def handle_call({:unregister, channel_id}, _from, state) do
    Logger.info("Channel unregistered: #{channel_id}")
    {:reply, :ok, update_in(state, [:channels], &Map.delete(&1, channel_id))}
  end

  @impl true
  def handle_call({:get, channel_id}, _from, state) do
    {:reply, Map.get(state.channels, channel_id), state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    channels = state.channels |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, channels, state}
  end
end
