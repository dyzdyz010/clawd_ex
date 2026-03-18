defmodule ClawdEx.Memory.Backends.LocalFileTest do
  @moduledoc """
  Tests for the LocalFile memory backend.

  All tests use a temporary directory to avoid interfering
  with real workspace data.
  """
  use ExUnit.Case, async: true

  alias ClawdEx.Memory.Backends.LocalFile

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "localfile_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, "memory"))

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, state} = LocalFile.init(%{workspace: tmp_dir})
    %{state: state, workspace: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "creates memory directory if missing" do
      fresh_dir = Path.join(System.tmp_dir!(), "lf_init_#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(fresh_dir) end)

      assert {:ok, state} = LocalFile.init(%{workspace: fresh_dir})
      assert File.dir?(Path.join(fresh_dir, "memory"))
      assert state.workspace == fresh_dir
    end

    test "uses defaults for missing config keys" do
      fresh_dir = Path.join(System.tmp_dir!(), "lf_defaults_#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(fresh_dir) end)

      {:ok, state} = LocalFile.init(%{workspace: fresh_dir})
      assert state.memory_dir == "memory"
      assert state.memory_file == "MEMORY.md"
    end

    test "respects custom memory_dir and memory_file" do
      fresh_dir = Path.join(System.tmp_dir!(), "lf_custom_#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(fresh_dir) end)

      {:ok, state} = LocalFile.init(%{workspace: fresh_dir, memory_dir: "notes", memory_file: "BRAIN.md"})
      assert state.memory_dir == "notes"
      assert state.memory_file == "BRAIN.md"
      assert File.dir?(Path.join(fresh_dir, "notes"))
    end
  end

  # ---------------------------------------------------------------------------
  # store/3
  # ---------------------------------------------------------------------------

  describe "store/3" do
    test "writes to today's daily file by default", %{state: state, workspace: ws} do
      {:ok, entry} = LocalFile.store(state, "Hello world")

      date = Date.utc_today() |> Date.to_iso8601()
      path = Path.join([ws, "memory", "#{date}.md"])

      assert File.exists?(path)
      assert String.contains?(File.read!(path), "Hello world")
      assert entry.content == "Hello world"
      assert entry.type == :episodic
    end

    test "writes to MEMORY.md when source is specified", %{state: state, workspace: ws} do
      {:ok, _entry} = LocalFile.store(state, "Long-term fact", source: "MEMORY.md")

      path = Path.join(ws, "MEMORY.md")
      assert File.exists?(path)
      assert String.contains?(File.read!(path), "Long-term fact")
    end

    test "stores semantic type with correct emoji", %{state: state, workspace: ws} do
      {:ok, _entry} = LocalFile.store(state, "Semantic insight", type: :semantic)

      date = Date.utc_today() |> Date.to_iso8601()
      content = File.read!(Path.join([ws, "memory", "#{date}.md"]))
      assert String.contains?(content, "💡")
    end

    test "stores procedural type with correct emoji", %{state: state, workspace: ws} do
      {:ok, _entry} = LocalFile.store(state, "Deploy procedure", type: :procedural)

      date = Date.utc_today() |> Date.to_iso8601()
      content = File.read!(Path.join([ws, "memory", "#{date}.md"]))
      assert String.contains?(content, "⚙️")
    end

    test "appends to existing file without overwriting", %{state: state, workspace: ws} do
      {:ok, _} = LocalFile.store(state, "First entry")
      {:ok, _} = LocalFile.store(state, "Second entry")

      date = Date.utc_today() |> Date.to_iso8601()
      content = File.read!(Path.join([ws, "memory", "#{date}.md"]))
      assert String.contains?(content, "First entry")
      assert String.contains?(content, "Second entry")
    end

    test "writes to custom absolute path via source option", %{state: state, workspace: ws} do
      custom = Path.join(ws, "custom_notes.md")
      {:ok, _} = LocalFile.store(state, "Custom path content", source: custom)

      assert File.exists?(custom)
      assert String.contains?(File.read!(custom), "Custom path content")
    end
  end

  # ---------------------------------------------------------------------------
  # search/3
  # ---------------------------------------------------------------------------

  describe "search/3" do
    test "finds matching content across files", %{state: state, workspace: ws} do
      # Seed data
      File.write!(Path.join(ws, "MEMORY.md"), """
      # Long-term Memory
      - User loves Elixir and functional programming
      - User prefers dark mode
      """)

      {:ok, results} = LocalFile.search(state, "Elixir programming")
      assert length(results) > 0
      assert Enum.any?(results, fn r -> String.contains?(r.content, "Elixir") end)
    end

    test "returns empty list when no files exist", %{state: state} do
      {:ok, results} = LocalFile.search(state, "anything")
      assert results == []
    end

    test "returns empty list for non-matching query", %{state: state, workspace: ws} do
      File.write!(Path.join(ws, "MEMORY.md"), "Only about cats and dogs")

      {:ok, results} = LocalFile.search(state, "xyznonexistent", min_score: 0.5)
      assert results == []
    end

    test "respects limit option", %{state: state, workspace: ws} do
      File.write!(Path.join(ws, "MEMORY.md"), """
      # Section 1
      Elixir is great

      # Section 2
      Elixir pattern matching

      # Section 3
      Elixir OTP supervision trees
      """)

      {:ok, results} = LocalFile.search(state, "Elixir", limit: 1)
      assert length(results) <= 1
    end

    test "filters by min_score", %{state: state, workspace: ws} do
      File.write!(Path.join(ws, "MEMORY.md"), "Random content about weather")

      {:ok, results} = LocalFile.search(state, "weather", min_score: 0.0)
      # With min_score: 0.0, should find something
      assert is_list(results)
    end

    test "filters by specific sources", %{state: state, workspace: ws} do
      File.write!(Path.join(ws, "MEMORY.md"), "Main memory about Elixir")
      File.write!(Path.join([ws, "memory", "2024-01-01.md"]), "Daily note about Python")

      {:ok, results} = LocalFile.search(state, "Elixir", sources: ["MEMORY.md"])
      # Should only search MEMORY.md
      refute Enum.any?(results, fn r -> String.contains?(r.content, "Python") end)
    end
  end

  # ---------------------------------------------------------------------------
  # store_messages/3
  # ---------------------------------------------------------------------------

  describe "store_messages/3" do
    test "formats and stores a conversation", %{state: state, workspace: ws} do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      {:ok, entries} = LocalFile.store_messages(state, messages, [])
      assert length(entries) == 1

      date = Date.utc_today() |> Date.to_iso8601()
      content = File.read!(Path.join([ws, "memory", "#{date}.md"]))
      assert String.contains?(content, "User")
      assert String.contains?(content, "Hello")
      assert String.contains?(content, "Assistant")
    end
  end

  # ---------------------------------------------------------------------------
  # delete / delete_by_source
  # ---------------------------------------------------------------------------

  describe "delete/2" do
    test "returns not_supported error", %{state: state} do
      assert {:error, :not_supported} = LocalFile.delete(state, "any_id")
    end
  end

  describe "delete_by_source/2" do
    test "removes the file", %{state: state, workspace: ws} do
      file_path = Path.join([ws, "memory", "deleteme.md"])
      File.write!(file_path, "temporary")

      assert {:ok, 1} = LocalFile.delete_by_source(state, "memory/deleteme.md")
      refute File.exists?(file_path)
    end

    test "returns 0 for non-existent file", %{state: state} do
      assert {:ok, 0} = LocalFile.delete_by_source(state, "memory/nope.md")
    end
  end

  # ---------------------------------------------------------------------------
  # health/1 and name/0
  # ---------------------------------------------------------------------------

  describe "health/1" do
    test "returns :ok", %{state: state} do
      assert :ok = LocalFile.health(state)
    end
  end

  describe "name/0" do
    test "returns :local_file" do
      assert :local_file = LocalFile.name()
    end
  end
end
