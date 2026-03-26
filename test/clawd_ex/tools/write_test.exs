defmodule ClawdEx.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Write

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "execute/2 - write file" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "write_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "writes content to a new file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "new.txt")

      assert {:ok, msg} = Write.execute(%{"path" => file, "content" => "Hello World"}, @context)
      assert msg =~ "Successfully wrote"
      assert msg =~ "11 bytes"
      assert File.read!(file) == "Hello World"
    end

    test "works with atom key params", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "atom_keys.txt")

      assert {:ok, _} = Write.execute(%{path: file, content: "atom keys"}, @context)
      assert File.read!(file) == "atom keys"
    end

    test "overwrites existing file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "existing.txt")
      File.write!(file, "old content")

      assert {:ok, _} = Write.execute(%{"path" => file, "content" => "new content"}, @context)
      assert File.read!(file) == "new content"
    end

    test "writes empty content", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "empty.txt")

      assert {:ok, msg} = Write.execute(%{"path" => file, "content" => ""}, @context)
      assert msg =~ "0 bytes"
      assert File.read!(file) == ""
    end

    test "writes multiline content", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "multi.txt")
      content = "line 1\nline 2\nline 3"

      assert {:ok, _} = Write.execute(%{"path" => file, "content" => content}, @context)
      assert File.read!(file) == content
    end

    test "writes UTF-8 content", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "utf8.txt")
      content = "你好世界 🌍 café"

      assert {:ok, _} = Write.execute(%{"path" => file, "content" => content}, @context)
      assert File.read!(file) == content
    end
  end

  describe "execute/2 - create parent directories" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "write_nested_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "creates nested parent directories automatically", %{tmp_dir: tmp_dir} do
      nested_file = Path.join([tmp_dir, "a", "b", "c", "deep.txt"])

      assert {:ok, _} = Write.execute(%{"path" => nested_file, "content" => "deep"}, @context)
      assert File.read!(nested_file) == "deep"
    end
  end

  describe "execute/2 - relative path resolution" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "write_rel_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "resolves relative path against workspace context", %{tmp_dir: tmp_dir} do
      ctx = %{workspace: tmp_dir}

      assert {:ok, _} = Write.execute(%{"path" => "relative.txt", "content" => "relative"}, ctx)
      assert File.read!(Path.join(tmp_dir, "relative.txt")) == "relative"
    end
  end
end
