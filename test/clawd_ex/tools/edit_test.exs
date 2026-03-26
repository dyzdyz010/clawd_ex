defmodule ClawdEx.Tools.EditTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Edit

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "execute/2 - text replacement" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "edit_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      test_file = Path.join(tmp_dir, "edit_me.txt")
      File.write!(test_file, "Hello World\nThis is a test\nGoodbye World")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, test_file: test_file}
    end

    test "replaces exact text match", %{test_file: test_file} do
      params = %{"path" => test_file, "old_string" => "Hello World", "new_string" => "Hello Elixir"}

      assert {:ok, msg} = Edit.execute(params, @context)
      assert msg =~ "Successfully replaced"
      assert File.read!(test_file) == "Hello Elixir\nThis is a test\nGoodbye World"
    end

    test "works with atom key params", %{test_file: test_file} do
      params = %{path: test_file, old_string: "Hello World", new_string: "Hi"}

      assert {:ok, _} = Edit.execute(params, @context)
      assert File.read!(test_file) =~ "Hi"
    end

    test "works with oldText/newText aliases", %{test_file: test_file} do
      params = %{"path" => test_file, "oldText" => "Hello World", "newText" => "Hey"}

      assert {:ok, _} = Edit.execute(params, @context)
      assert File.read!(test_file) =~ "Hey"
    end

    test "replaces multiline text", %{test_file: test_file} do
      old = "Hello World\nThis is a test"
      new = "Replaced block"
      params = %{"path" => test_file, "old_string" => old, "new_string" => new}

      assert {:ok, _} = Edit.execute(params, @context)
      assert File.read!(test_file) == "Replaced block\nGoodbye World"
    end

    test "replaces only first occurrence (not global)", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "dups.txt")
      File.write!(file, "foo bar foo baz foo")

      params = %{"path" => file, "old_string" => "foo", "new_string" => "FOO"}

      assert {:ok, _} = Edit.execute(params, @context)
      assert File.read!(file) == "FOO bar foo baz foo"
    end

    test "replaces text with empty string (deletion)", %{test_file: test_file} do
      params = %{"path" => test_file, "old_string" => "This is a test\n", "new_string" => ""}

      assert {:ok, _} = Edit.execute(params, @context)
      assert File.read!(test_file) == "Hello World\nGoodbye World"
    end

    test "whitespace-sensitive matching", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "spaces.txt")
      File.write!(file, "  indented\n  code")

      # Must match exact whitespace
      params = %{"path" => file, "old_string" => "  indented", "new_string" => "    double_indented"}
      assert {:ok, _} = Edit.execute(params, @context)
      assert File.read!(file) == "    double_indented\n  code"
    end
  end

  describe "execute/2 - error cases" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "edit_err_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      test_file = Path.join(tmp_dir, "target.txt")
      File.write!(test_file, "existing content")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, test_file: test_file}
    end

    test "returns error when old_string not found in file", %{test_file: test_file} do
      params = %{"path" => test_file, "old_string" => "nonexistent text", "new_string" => "new"}

      assert {:error, msg} = Edit.execute(params, @context)
      assert msg =~ "not found"
    end

    test "returns error for nonexistent file" do
      params = %{
        "path" => "/nonexistent/path/file_#{System.unique_integer()}.txt",
        "old_string" => "old",
        "new_string" => "new"
      }

      assert {:error, msg} = Edit.execute(params, @context)
      assert msg =~ "not found"
    end
  end

  describe "execute/2 - relative path resolution" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "edit_rel_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "rel.txt"), "old text")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "resolves relative path against workspace", %{tmp_dir: tmp_dir} do
      ctx = %{workspace: tmp_dir}
      params = %{"path" => "rel.txt", "old_string" => "old text", "new_string" => "new text"}

      assert {:ok, _} = Edit.execute(params, ctx)
      assert File.read!(Path.join(tmp_dir, "rel.txt")) == "new text"
    end
  end
end
