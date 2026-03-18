defmodule ClawdEx.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Read

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "name/0, description/0, parameters/0" do
    test "returns tool metadata" do
      assert Read.name() == "read"
      assert is_binary(Read.description())
      assert %{type: "object", properties: %{path: _}, required: ["path"]} = Read.parameters()
    end
  end

  describe "execute/2 - read file" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "read_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      test_file = Path.join(tmp_dir, "sample.txt")
      File.write!(test_file, "line 1\nline 2\nline 3\nline 4\nline 5")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, test_file: test_file}
    end

    test "reads entire file with absolute path", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{"path" => test_file}, @context)
      assert content == "line 1\nline 2\nline 3\nline 4\nline 5"
    end

    test "reads file with atom key params", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{path: test_file}, @context)
      assert content == "line 1\nline 2\nline 3\nline 4\nline 5"
    end

    test "resolves relative path against workspace", %{tmp_dir: tmp_dir} do
      ctx = %{workspace: tmp_dir}
      assert {:ok, content} = Read.execute(%{"path" => "sample.txt"}, ctx)
      assert content == "line 1\nline 2\nline 3\nline 4\nline 5"
    end

    test "reads empty file", %{tmp_dir: tmp_dir} do
      empty_file = Path.join(tmp_dir, "empty.txt")
      File.write!(empty_file, "")

      assert {:ok, ""} = Read.execute(%{"path" => empty_file}, @context)
    end
  end

  describe "execute/2 - file not found" do
    test "returns error for nonexistent file" do
      assert {:error, msg} = Read.execute(%{"path" => "/nonexistent/file_#{System.unique_integer()}.txt"}, @context)
      assert msg =~ "not found"
    end
  end

  describe "execute/2 - offset and limit" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "read_off_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      test_file = Path.join(tmp_dir, "lines.txt")
      content = Enum.map_join(1..10, "\n", fn i -> "line #{i}" end)
      File.write!(test_file, content)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{test_file: test_file}
    end

    test "offset skips lines (1-indexed)", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{"path" => test_file, "offset" => 3}, @context)
      lines = String.split(content, "\n")
      assert hd(lines) == "line 3"
    end

    test "limit caps number of lines returned", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{"path" => test_file, "limit" => 3}, @context)
      lines = String.split(content, "\n")
      assert length(lines) == 3
      assert lines == ["line 1", "line 2", "line 3"]
    end

    test "offset + limit together", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{"path" => test_file, "offset" => 4, "limit" => 2}, @context)
      assert content == "line 4\nline 5"
    end

    test "offset beyond file length returns empty", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{"path" => test_file, "offset" => 100}, @context)
      assert content == ""
    end

    test "defaults: offset=1, limit=2000", %{test_file: test_file} do
      # Without offset/limit, all 10 lines are returned
      assert {:ok, content} = Read.execute(%{"path" => test_file}, @context)
      lines = String.split(content, "\n")
      assert length(lines) == 10
    end
  end

  describe "execute/2 - large file truncation" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "read_big_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      big_file = Path.join(tmp_dir, "big.txt")

      # Create a file where selected content exceeds 50KB
      # Each line ~100 bytes, 600 lines ≈ 60KB > 50KB limit
      big_content = Enum.map_join(1..600, "\n", fn i ->
        "line #{String.pad_leading(Integer.to_string(i), 5, "0")} #{String.duplicate("x", 90)}"
      end)
      File.write!(big_file, big_content)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{big_file: big_file}
    end

    test "truncates output at 50KB and appends notice", %{big_file: big_file} do
      assert {:ok, content} = Read.execute(%{"path" => big_file}, @context)
      assert String.ends_with?(content, "[Output truncated at 50KB]")
      # The content before truncation marker should be <= 50KB + marker length
      assert byte_size(content) <= 50_000 + 100
    end
  end

  describe "execute/2 - directory" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "read_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "a.txt"), "a")
      File.write!(Path.join(tmp_dir, "b.txt"), "b")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "lists directory contents when path is a directory", %{tmp_dir: tmp_dir} do
      assert {:ok, content} = Read.execute(%{"path" => tmp_dir}, @context)
      assert content =~ "Directory listing"
      assert content =~ "a.txt"
      assert content =~ "b.txt"
    end
  end
end
