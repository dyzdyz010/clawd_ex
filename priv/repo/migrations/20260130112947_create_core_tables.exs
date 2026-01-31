defmodule ClawdEx.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # Agents 表
    create table(:agents) do
      add :name, :string, null: false
      add :workspace_path, :string
      add :default_model, :string, default: "anthropic/claude-sonnet-4"
      add :system_prompt, :text
      add :config, :map, default: %{}
      add :active, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agents, [:name])

    # Sessions 表
    create table(:sessions) do
      add :session_key, :string, null: false
      add :channel, :string, null: false
      add :channel_id, :string
      add :state, :string, default: "active"
      add :model_override, :string
      add :token_count, :integer, default: 0
      add :message_count, :integer, default: 0
      add :metadata, :map, default: %{}
      add :last_activity_at, :utc_datetime

      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sessions, [:session_key])
    create index(:sessions, [:agent_id])
    create index(:sessions, [:channel, :channel_id])

    # Messages 表
    create table(:messages) do
      add :role, :string, null: false
      add :content, :text
      add :tool_calls, {:array, :map}, default: []
      add :tool_call_id, :string
      add :model, :string
      add :tokens_in, :integer
      add :tokens_out, :integer
      add :metadata, :map, default: %{}

      add :session_id, references(:sessions, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:session_id])

    # Memory Chunks 表 (带 pgvector)
    create table(:memory_chunks) do
      add :content, :text, null: false
      add :source_file, :string, null: false
      add :source_type, :string, null: false
      add :start_line, :integer
      add :end_line, :integer
      # OpenAI text-embedding-3-small 维度
      add :embedding, :vector, size: 1536
      add :embedding_model, :string
      add :metadata, :map, default: %{}

      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:memory_chunks, [:agent_id])
    create index(:memory_chunks, [:source_file])

    # 创建 HNSW 向量索引 (用于快速相似度搜索)
    execute """
            CREATE INDEX memory_chunks_embedding_idx ON memory_chunks
            USING hnsw (embedding vector_cosine_ops)
            WITH (m = 16, ef_construction = 64)
            """,
            "DROP INDEX memory_chunks_embedding_idx"
  end
end
