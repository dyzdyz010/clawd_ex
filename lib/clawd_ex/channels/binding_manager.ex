defmodule ClawdEx.Channels.BindingManager do
  @moduledoc """
  CRUD operations for channel bindings + session lifecycle management.

  Handles creating/removing bindings, starting bound sessions on boot,
  and ensuring binding sessions are running.
  """

  require Logger

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Channels.ChannelBinding
  alias ClawdEx.Channels.Registry, as: ChannelRegistry
  alias ClawdEx.Sessions.SessionManager

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @doc """
  Create a channel binding for an agent.
  Auto-generates the session_key using the channel module's build_session_key/2.
  Starts a session for the binding immediately.
  """
  def create_binding(agent_id, channel, channel_config) do
    with {:ok, session_key} <- build_session_key(channel, agent_id, channel_config) do
      attrs = %{
        agent_id: agent_id,
        channel: channel,
        channel_config: channel_config,
        session_key: session_key,
        active: true
      }

      case %ChannelBinding{} |> ChannelBinding.changeset(attrs) |> Repo.insert() do
        {:ok, binding} ->
          # Start the session for this binding
          ensure_binding_session(binding)
          {:ok, binding}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Remove (deactivate) a channel binding. Stops the associated session.
  """
  def remove_binding(binding_id) do
    case Repo.get(ChannelBinding, binding_id) do
      nil ->
        {:error, :not_found}

      binding ->
        # Deactivate the binding
        case binding |> ChannelBinding.changeset(%{active: false}) |> Repo.update() do
          {:ok, updated} ->
            # Stop the session
            SessionManager.stop_session(updated.session_key)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  List all bindings for an agent (active and inactive).
  """
  def list_bindings(agent_id) do
    ChannelBinding
    |> where([b], b.agent_id == ^agent_id)
    |> order_by([b], asc: b.id)
    |> Repo.all()
  end

  @doc """
  List all active bindings across all agents.
  """
  def list_active_bindings do
    ChannelBinding
    |> where([b], b.active == true)
    |> Repo.all()
  end

  @doc """
  List active bindings for a specific agent.
  """
  def list_active_bindings(agent_id) do
    ChannelBinding
    |> where([b], b.agent_id == ^agent_id and b.active == true)
    |> Repo.all()
  end

  # ============================================================================
  # Session Lifecycle
  # ============================================================================

  @doc """
  Start sessions for all active bindings. Called during boot.
  """
  def start_all_binding_sessions do
    bindings = list_active_bindings()
    Logger.info("[BindingManager] Starting sessions for #{length(bindings)} active binding(s)")

    Enum.each(bindings, fn binding ->
      ensure_binding_session(binding)
    end)

    length(bindings)
  end

  @doc """
  Ensure a binding's session is running. Starts it if not.
  """
  def ensure_binding_session(%ChannelBinding{active: false}), do: :skip

  def ensure_binding_session(%ChannelBinding{} = binding) do
    case SessionManager.start_session(
           session_key: binding.session_key,
           agent_id: binding.agent_id,
           channel: binding.channel,
           channel_config: binding.channel_config
         ) do
      {:ok, pid} ->
        Logger.info(
          "[BindingManager] Session started: #{binding.session_key} | pid=#{inspect(pid)}"
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "[BindingManager] Failed to start session #{binding.session_key}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ============================================================================
  # Lookup
  # ============================================================================

  @doc """
  Find the agent bound to a specific channel + config combination.
  Used by Telegram to resolve topic defaults via channel_bindings instead of config.
  """
  def find_binding_for_channel(channel, channel_config) do
    ChannelBinding
    |> where([b], b.channel == ^channel and b.active == true)
    |> Repo.all()
    |> Enum.find(fn b ->
      # Compare channel_config maps — the binding's config must be a subset match
      configs_match?(b.channel_config, channel_config)
    end)
  end

  # Check if a binding's config matches the lookup config.
  # The binding config keys must all be present and equal in the lookup config.
  defp configs_match?(binding_config, lookup_config) do
    Enum.all?(binding_config, fn {key, value} ->
      Map.get(lookup_config, key) == value
    end)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_session_key(channel, agent_id, channel_config) do
    # Try channel registry first, then known channel modules as fallback
    module = get_channel_module(channel)

    if module do
      # Ensure the module is loaded (it might not be if the GenServer hasn't started)
      Code.ensure_loaded(module)

      if function_exported?(module, :build_session_key, 2) do
        {:ok, module.build_session_key(agent_id, channel_config)}
      else
        {:ok, generic_session_key(channel, agent_id, channel_config)}
      end
    else
      {:ok, generic_session_key(channel, agent_id, channel_config)}
    end
  end

  defp generic_session_key(channel, agent_id, channel_config) do
    config_hash =
      channel_config
      |> Jason.encode!()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0..7)

    "#{channel}:#{config_hash}:agent:#{agent_id}"
  end

  # Get the channel module — try registry first, then known modules
  defp get_channel_module(channel) do
    case ChannelRegistry.get(channel) do
      %{module: module} -> module
      nil -> known_channel_module(channel)
    end
  rescue
    # Registry not started yet (e.g., during boot/tests)
    _ -> known_channel_module(channel)
  catch
    :exit, _ -> known_channel_module(channel)
  end

  # Hardcoded fallback for known channels (used when registry isn't available)
  defp known_channel_module("telegram"), do: ClawdEx.Channels.Telegram
  defp known_channel_module(_), do: nil
end
