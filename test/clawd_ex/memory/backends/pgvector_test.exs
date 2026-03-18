defmodule ClawdEx.Memory.Backends.PgVectorTest do
  @moduledoc """
  Tests for the PgVector memory backend.

  Requires a running PostgreSQL database with the pgvector extension.
  Since `search` and `store` both call the Embeddings API (external),
  we test the DB layer directly: init, health, delete, and chunk CRUD.
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Memory.Backends.PgVector
  alias ClawdEx.Memory.Chunk
  alias ClawdEx.Agents.Agent

  setup do
    # Create a test agent (memory_chunks.agent_id is NOT NULL)
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "pgvector_test_#{:erlang.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, state} = PgVector.init(%{repo: ClawdEx.Repo})
    %{state: state, agent_id: agent.id}
  end

  defp chunk_attrs(agent_id, overrides) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        content: "Test content",
        source_file: "test_source",
        source_type: "episodic",
        start_line: 1,
        end_line: 1,
        embedding: nil,
        embedding_model: "test",
        metadata: %{},
        agent_id: agent_id,
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "initializes with default config" do
      {:ok, state} = PgVector.init(%{})
      assert state.repo == ClawdEx.Repo
      assert is_binary(state.embedding_model)
    end

    test "accepts custom repo and model" do
      {:ok, state} = PgVector.init(%{repo: ClawdEx.Repo, embedding_model: "custom-model"})
      assert state.embedding_model == "custom-model"
    end
  end

  # ---------------------------------------------------------------------------
  # name/0
  # ---------------------------------------------------------------------------

  describe "name/0" do
    test "returns :pgvector" do
      assert :pgvector = PgVector.name()
    end
  end

  # ---------------------------------------------------------------------------
  # health/1
  # ---------------------------------------------------------------------------

  describe "health/1" do
    test "returns :ok when DB is reachable", %{state: state} do
      assert :ok = PgVector.health(state)
    end
  end

  # ---------------------------------------------------------------------------
  # store/3 - DB layer (bypassing embeddings)
  # ---------------------------------------------------------------------------

  describe "store/3 (DB layer)" do
    test "inserts a chunk record directly", %{agent_id: agent_id} do
      attrs = chunk_attrs(agent_id, %{content: "Test pgvector content"})

      assert {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))
      assert chunk.content == "Test pgvector content"
      assert chunk.source_type == "episodic"

      # Verify roundtrip
      loaded = Repo.get!(Chunk, chunk.id)
      assert loaded.content == "Test pgvector content"
    end

    test "stores with semantic type", %{agent_id: agent_id} do
      attrs = chunk_attrs(agent_id, %{content: "Semantic fact", source_type: "semantic"})

      {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))
      assert chunk.source_type == "semantic"
    end
  end

  # ---------------------------------------------------------------------------
  # delete/2
  # ---------------------------------------------------------------------------

  describe "delete/2" do
    test "deletes a chunk by pgvector_ID format", %{state: state, agent_id: agent_id} do
      attrs = chunk_attrs(agent_id, %{content: "To be deleted"})
      {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))

      assert :ok = PgVector.delete(state, "pgvector_#{chunk.id}")
      assert Repo.get(Chunk, chunk.id) == nil
    end

    test "deletes by raw integer ID", %{state: state, agent_id: agent_id} do
      attrs = chunk_attrs(agent_id, %{content: "Delete by int"})
      {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))

      assert :ok = PgVector.delete(state, chunk.id)
      assert Repo.get(Chunk, chunk.id) == nil
    end

    test "returns error for non-existent chunk", %{state: state} do
      assert {:error, :not_found} = PgVector.delete(state, "pgvector_999999999")
    end
  end

  # ---------------------------------------------------------------------------
  # delete_by_source/2
  # ---------------------------------------------------------------------------

  describe "delete_by_source/2" do
    test "deletes all chunks with matching source_file", %{state: state, agent_id: agent_id} do
      source = "delete_source_#{:erlang.unique_integer([:positive])}"

      for i <- 1..3 do
        attrs = chunk_attrs(agent_id, %{content: "Chunk #{i}", source_file: source})
        Repo.insert!(Chunk.changeset(%Chunk{}, attrs))
      end

      assert {:ok, 3} = PgVector.delete_by_source(state, source)

      # Verify they're gone
      count = from(c in Chunk, where: c.source_file == ^source) |> Repo.aggregate(:count)
      assert count == 0
    end

    test "returns 0 when no matching source", %{state: state} do
      assert {:ok, 0} = PgVector.delete_by_source(state, "nonexistent_source_#{:rand.uniform(999_999)}")
    end
  end

  # ---------------------------------------------------------------------------
  # store_messages/3 (DB layer - direct chunk insertion)
  # ---------------------------------------------------------------------------

  describe "store_messages/3 (DB layer)" do
    test "can store formatted messages as a chunk", %{agent_id: agent_id} do
      messages = [
        %{role: "user", content: "What is Elixir?"},
        %{role: "assistant", content: "A functional language built on Erlang VM."}
      ]

      content =
        messages
        |> Enum.map(fn msg -> "[#{msg.role}] #{msg.content}" end)
        |> Enum.join("\n\n")

      attrs = chunk_attrs(agent_id, %{content: content, source_file: "conversation"})
      {:ok, chunk} = Repo.insert(Chunk.changeset(%Chunk{}, attrs))

      assert String.contains?(chunk.content, "What is Elixir?")
      assert String.contains?(chunk.content, "functional language")
    end
  end
end
