defmodule ClawdEx.Config.HotReloadTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Config.HotReload

  describe "put/2 and get/1" do
    test "sets and gets a reloadable key" do
      original = HotReload.get(:max_tool_iterations)

      try do
        assert :ok = HotReload.put(:max_tool_iterations, 500)
        assert 500 = HotReload.get(:max_tool_iterations)
      after
        if original do
          Application.put_env(:clawd_ex, :max_tool_iterations, original)
        end
      end
    end

    test "rejects non-reloadable keys" do
      assert {:error, _} = HotReload.put(:repo, "bad")
      assert {:error, _} = HotReload.put(:secret_key_base, "bad")
    end
  end

  describe "list/0" do
    test "returns all reloadable keys with values" do
      items = HotReload.list()
      keys = Enum.map(items, &elem(&1, 0))
      assert :default_model in keys
      assert :max_tool_iterations in keys
      assert :gateway_token in keys
      assert :exec_approval in keys
    end
  end

  describe "reload/0" do
    test "completes without error" do
      assert {:ok, results} = HotReload.reload()
      assert is_list(results)
      assert length(results) == length(HotReload.reloadable_keys())
    end
  end

  describe "reloadable_keys/0" do
    test "returns a non-empty list of atoms" do
      keys = HotReload.reloadable_keys()
      assert is_list(keys)
      assert length(keys) > 0
      assert Enum.all?(keys, &is_atom/1)
    end
  end
end
