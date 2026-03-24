defmodule ClawdEx.ACP.Registry do
  @moduledoc """
  GenServer that manages registered ACP runtime backends.

  Tracks which backend modules are available, their health status,
  and maps agent IDs to the appropriate backend.
  """

  use GenServer
  require Logger

  @agent_backend_map %{
    "claude" => "cli",
    "codex" => "cli",
    "gemini" => "cli",
    "pi" => "cli"
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a backend module under the given ID."
  @spec register_backend(String.t(), module(), keyword()) :: :ok | {:error, term()}
  def register_backend(id, module, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register, id, module, opts})
  end

  @doc "Unregister a backend by ID."
  @spec unregister_backend(String.t(), keyword()) :: :ok | {:error, term()}
  def unregister_backend(id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:unregister, id})
  end

  @doc "Look up the backend module for a given agent ID."
  @spec get_backend(String.t(), keyword()) :: {:ok, module()} | {:error, :not_found}
  def get_backend(agent_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_backend, agent_id})
  end

  @doc "List all registered backends."
  @spec list_backends(keyword()) :: map()
  def list_backends(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_backends)
  end

  @doc "Run health checks on all registered backends."
  @spec health_check(keyword()) :: {:ok, map()}
  def health_check(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :health_check, 30_000)
  end

  @doc "Return the default agent → backend mapping."
  @spec agent_backend_map() :: map()
  def agent_backend_map, do: @agent_backend_map

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{backends: %{}}}
  end

  @impl true
  def handle_call({:register, id, module, _opts}, _from, state) do
    entry = %{module: module, healthy: true, registered_at: System.system_time(:second)}
    new_backends = Map.put(state.backends, id, entry)
    Logger.info("[ACP.Registry] Registered backend: #{id} → #{inspect(module)}")
    {:reply, :ok, %{state | backends: new_backends}}
  end

  def handle_call({:unregister, id}, _from, state) do
    if Map.has_key?(state.backends, id) do
      new_backends = Map.delete(state.backends, id)
      Logger.info("[ACP.Registry] Unregistered backend: #{id}")
      {:reply, :ok, %{state | backends: new_backends}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_backend, agent_id}, _from, state) do
    # First resolve agent_id → backend_id via the mapping
    backend_id = Map.get(@agent_backend_map, agent_id, agent_id)

    case Map.get(state.backends, backend_id) do
      %{module: module, healthy: true} ->
        {:reply, {:ok, module}, state}

      %{healthy: false} ->
        {:reply, {:error, :unhealthy}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_backends, _from, state) do
    {:reply, state.backends, state}
  end

  def handle_call(:health_check, _from, state) do
    results =
      Enum.reduce(state.backends, %{}, fn {id, entry}, acc ->
        healthy =
          case function_exported?(entry.module, :doctor, 0) do
            true ->
              case entry.module.doctor() do
                {:ok, _} -> true
                _ -> false
              end

            false ->
              # If module doesn't implement doctor/0, assume healthy
              true
          end

        Map.put(acc, id, healthy)
      end)

    # Update health status in state
    new_backends =
      Enum.reduce(results, state.backends, fn {id, healthy}, backends ->
        case Map.get(backends, id) do
          nil -> backends
          entry -> Map.put(backends, id, %{entry | healthy: healthy})
        end
      end)

    {:reply, {:ok, results}, %{state | backends: new_backends}}
  end
end
