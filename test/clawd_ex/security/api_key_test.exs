defmodule ClawdEx.Security.ApiKeyTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Security.ApiKey

  setup do
    # Clear existing keys between tests
    # The GenServer is started by the application supervisor
    if GenServer.whereis(ApiKey) do
      ApiKey.clear()
    else
      start_supervised!(ApiKey)
    end

    :ok
  end

  describe "generate_key/1" do
    test "generates a key with ck_live_ prefix" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "test-key", scope: "read"})

      assert String.starts_with?(key_info.key, "ck_live_")
      assert key_info.name == "test-key"
      assert key_info.scope == :read
      assert key_info.id != nil
      assert key_info.key_prefix != nil
      assert key_info.revoked == false
    end

    test "generates a key with default read scope" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "default-scope"})
      assert key_info.scope == :read
    end

    test "generates a key with admin scope" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "admin-key", scope: "admin"})
      assert key_info.scope == :admin
    end

    test "generates a key with write scope" do
      {:ok, key_info} = ApiKey.generate_key(%{name: "write-key", scope: "write"})
      assert key_info.scope == :write
    end

    test "accepts keyword list options" do
      {:ok, key_info} = ApiKey.generate_key(name: "kw-key", scope: "admin")
      assert key_info.name == "kw-key"
      assert key_info.scope == :admin
    end

    test "generates unique keys" do
      {:ok, key1} = ApiKey.generate_key(%{name: "key1"})
      {:ok, key2} = ApiKey.generate_key(%{name: "key2"})

      assert key1.key != key2.key
      assert key1.id != key2.id
    end
  end

  describe "verify_key/1" do
    test "verifies a valid key" do
      {:ok, generated} = ApiKey.generate_key(%{name: "verify-test", scope: "write"})

      {:ok, verified} = ApiKey.verify_key(generated.key)
      assert verified.id == generated.id
      assert verified.name == "verify-test"
      assert verified.scope == :write
    end

    test "rejects an invalid key" do
      assert {:error, :invalid_key} = ApiKey.verify_key("ck_live_invalid_key_here")
    end

    test "rejects a revoked key" do
      {:ok, generated} = ApiKey.generate_key(%{name: "revoke-test"})
      :ok = ApiKey.revoke_key(generated.id)

      assert {:error, :invalid_key} = ApiKey.verify_key(generated.key)
    end
  end

  describe "list_keys/0" do
    test "lists all keys without key_hash" do
      {:ok, _} = ApiKey.generate_key(%{name: "list-key-1"})
      {:ok, _} = ApiKey.generate_key(%{name: "list-key-2"})

      keys = ApiKey.list_keys()
      assert length(keys) == 2

      for key <- keys do
        refute Map.has_key?(key, :key_hash)
        refute Map.has_key?(key, :key)
        assert Map.has_key?(key, :key_prefix)
        assert Map.has_key?(key, :name)
      end
    end

    test "returns empty list when no keys" do
      assert ApiKey.list_keys() == []
    end
  end

  describe "revoke_key/1" do
    test "revokes an existing key" do
      {:ok, generated} = ApiKey.generate_key(%{name: "revoke-me"})
      assert :ok = ApiKey.revoke_key(generated.id)

      keys = ApiKey.list_keys()
      revoked = Enum.find(keys, &(&1.id == generated.id))
      assert revoked.revoked == true
    end

    test "returns error for non-existent key" do
      assert {:error, :not_found} = ApiKey.revoke_key("non-existent-id")
    end
  end
end
