defmodule ClawdEx.Memory.AgentMemoryTest do
  @moduledoc """
  Tests for AgentMemory - the agent-facing memory API.

  Uses a local_file backend with a temp workspace so no external
  services are needed.
  """
  use ExUnit.Case, async: true

  alias ClawdEx.Memory.AgentMemory

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "agent_memory_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, "memory"))

    # Seed a MEMORY.md for recall tests
    File.write!(Path.join(tmp_dir, "MEMORY.md"), """
    # Agent Memory

    ## Preferences
    - User likes Elixir and Phoenix
    - Prefers dark mode
    - Timezone is Asia/Shanghai
    """)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "init_with_backend/2" do
    test "initializes local_file backend", %{tmp_dir: tmp_dir} do
      assert {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})
      assert memory.name == :local_file
    end

    test "returns error for unknown backend" do
      assert {:error, {:unknown_backend, :nonexistent}} = AgentMemory.init_with_backend(:nonexistent)
    end
  end

  describe "recall/3" do
    test "returns relevant context string", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      context = AgentMemory.recall(memory, "Elixir")
      assert is_binary(context)
      # Should find content about Elixir from MEMORY.md
      assert String.contains?(context, "Elixir")
    end

    test "returns empty string when nothing matches", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      context = AgentMemory.recall(memory, "xyznonexistent123", min_score: 0.9)
      assert context == ""
    end
  end

  describe "memorize/4" do
    test "stores a conversation turn", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      assert :ok = AgentMemory.memorize(memory, "What is OTP?", "OTP is a set of libraries...")
    end

    test "stores with tool_calls option", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      result =
        AgentMemory.memorize(memory, "Search for X", "Found results",
          tool_calls: [%{name: "web_search"}]
        )

      assert result == :ok
    end
  end

  describe "store_insight/3" do
    test "stores semantic memory", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      assert {:ok, entry} = AgentMemory.store_insight(memory, "User's birthday is Jan 1")
      assert entry.type == :semantic
      assert entry.content == "User's birthday is Jan 1"
    end
  end

  describe "store_procedure/3" do
    test "stores procedural memory", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      assert {:ok, entry} = AgentMemory.store_procedure(memory, "To deploy: mix release && scp ...")
      assert entry.type == :procedural
    end
  end

  describe "info/1" do
    test "returns backend info map", %{tmp_dir: tmp_dir} do
      {:ok, memory} = AgentMemory.init_with_backend(:local_file, %{workspace: tmp_dir})

      info = AgentMemory.info(memory)
      assert info.backend == :local_file
      assert info.health == :ok
    end
  end
end
