defmodule ClawdEx.Security.ApiKey do
  @moduledoc """
  API Key management using ETS-backed GenServer.

  Each key has:
  - id: unique identifier (UUID)
  - key: the full API key string (e.g. `ck_live_xxx...`)
  - key_hash: SHA-256 hash of the key for secure storage
  - key_prefix: first 12 chars for display (e.g. `ck_live_abc1...`)
  - scope: :admin | :read | :write
  - name: human-readable name
  - created_at: creation timestamp
  - revoked: boolean
  """

  use GenServer

  @table :clawd_api_keys
  @key_prefix "ck_live_"

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate a new API key with the given options.

  Options:
  - :name — human-readable name (required)
  - :scope — :admin | :read | :write (default: :read)

  Returns `{:ok, %{id: id, key: full_key, ...}}` with the full key shown only once.
  """
  def generate_key(opts) when is_list(opts) do
    generate_key(Map.new(opts))
  end

  def generate_key(opts) when is_map(opts) do
    GenServer.call(__MODULE__, {:generate, opts})
  end

  @doc """
  Verify an API key. Returns `{:ok, key_info}` or `{:error, :invalid_key}`.
  """
  def verify_key(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:verify, key})
  end

  @doc """
  List all keys (sanitized — no full key or hash exposed).
  """
  def list_keys do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Revoke a key by its ID. Returns :ok or {:error, :not_found}.
  """
  def revoke_key(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:revoke, id})
  end

  @doc """
  Clear all keys. Useful for testing.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:generate, opts}, _from, state) do
    name = Map.get(opts, :name) || Map.get(opts, "name", "unnamed")
    scope = parse_scope(Map.get(opts, :scope) || Map.get(opts, "scope", "read"))

    id = generate_uuid()
    raw_key = generate_raw_key()
    full_key = @key_prefix <> raw_key
    key_hash = hash_key(full_key)
    key_prefix = String.slice(full_key, 0, 12) <> "..."

    record = %{
      id: id,
      key_hash: key_hash,
      key_prefix: key_prefix,
      scope: scope,
      name: name,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      revoked: false
    }

    :ets.insert(@table, {id, record})

    result = Map.put(record, :key, full_key) |> Map.delete(:key_hash)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:verify, key}, _from, state) do
    key_hash = hash_key(key)

    result =
      :ets.tab2list(@table)
      |> Enum.find(fn {_id, record} ->
        record.key_hash == key_hash && !record.revoked
      end)

    reply =
      case result do
        {_id, record} -> {:ok, Map.delete(record, :key_hash)}
        nil -> {:error, :invalid_key}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    keys =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, record} -> Map.delete(record, :key_hash) end)
      |> Enum.sort_by(& &1.created_at, :desc)

    {:reply, keys, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:revoke, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, record}] ->
        updated = %{record | revoked: true}
        :ets.insert(@table, {id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- Private Helpers ---

  defp generate_raw_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_uuid do
    # Simple UUID v4 without external deps
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<g1::binary-size(8), g2::binary-size(4), g3::binary-size(4), g4::binary-size(4),
        g5::binary-size(12)>> = hex

      "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
    end)
  end

  defp hash_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp parse_scope(scope) when is_atom(scope) and scope in [:admin, :read, :write], do: scope
  defp parse_scope("admin"), do: :admin
  defp parse_scope("write"), do: :write
  defp parse_scope(_), do: :read
end
