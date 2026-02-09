defmodule ClawdEx.Memory.ManagerTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Memory.Backends.LocalFile

  @moduletag :memory

  # 直接测试后端，不启动 Manager（避免与 application 中启动的冲突）
  setup do
    # 创建临时工作区
    tmp_dir = Path.join(System.tmp_dir!(), "clawd_memory_test_#{:rand.uniform(100000)}")
    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "memory"))

    # 写入测试记忆文件
    File.write!(Path.join(tmp_dir, "MEMORY.md"), """
    # Long-term Memory

    ## User Preferences
    - User prefers concise responses
    - User likes Elixir and functional programming
    - Timezone: UTC+8

    ## Important Dates
    - Project started: 2024-01-15
    - First release: 2024-02-01
    """)

    File.write!(Path.join(tmp_dir, "memory/2024-02-09.md"), """
    # 2024-02-09

    ## Morning
    - Implemented unified memory interface
    - Added MemOS backend support

    ## Afternoon
    - Fixed Telegram polling issue
    - All tests passing
    """)

    # 直接初始化后端
    {:ok, backend_state} = LocalFile.init(%{workspace: tmp_dir})

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{backend: backend_state, workspace: tmp_dir}
  end

  describe "LocalFile.search/3" do
    test "finds relevant memories by keyword", %{backend: backend} do
      {:ok, results} = LocalFile.search(backend, "Elixir programming", limit: 5)

      assert length(results) > 0
      assert Enum.any?(results, fn r -> String.contains?(r.content, "Elixir") end)
    end

    test "returns empty list when no matches", %{backend: backend} do
      {:ok, results} = LocalFile.search(backend, "xyznonexistent123", limit: 5, min_score: 0.5)

      assert results == []
    end

    test "respects limit option", %{backend: backend} do
      {:ok, results} = LocalFile.search(backend, "memory", limit: 1)

      assert length(results) <= 1
    end
  end

  describe "LocalFile.store/3" do
    test "stores memory to local file", %{backend: backend, workspace: workspace} do
      {:ok, entry} = LocalFile.store(backend, "Test memory content", type: :semantic)

      assert entry.content == "Test memory content"
      assert entry.type == :semantic

      # 验证文件已创建
      date = Date.utc_today() |> Date.to_iso8601()
      file_path = Path.join([workspace, "memory", "#{date}.md"])
      assert File.exists?(file_path)

      content = File.read!(file_path)
      assert String.contains?(content, "Test memory content")
    end
  end

  describe "LocalFile.store_messages/3" do
    test "stores conversation messages", %{backend: backend} do
      messages = [
        %{role: "user", content: "What is Elixir?"},
        %{role: "assistant", content: "Elixir is a functional programming language."}
      ]

      {:ok, entries} = LocalFile.store_messages(backend, messages, [])

      assert length(entries) > 0
    end
  end

  describe "LocalFile.health/1" do
    test "returns ok for healthy backend", %{backend: backend} do
      assert LocalFile.health(backend) == :ok
    end
  end

  describe "LocalFile.name/0" do
    test "returns backend name" do
      assert LocalFile.name() == :local_file
    end
  end
end
