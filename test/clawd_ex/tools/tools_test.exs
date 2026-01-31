defmodule ClawdEx.Tools.ToolsTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.{Registry, Read, Write, Edit, Exec, AgentsList}

  describe "Registry" do
    test "lists available tools" do
      tools = Registry.list_tools()
      assert is_list(tools)

      tool_names = Enum.map(tools, & &1.name)
      assert "read" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
      assert "exec" in tool_names
    end

    test "respects allow list" do
      tools = Registry.list_tools(allow: ["read", "write"])
      tool_names = Enum.map(tools, & &1.name)

      assert "read" in tool_names
      assert "write" in tool_names
      refute "exec" in tool_names
    end

    test "respects deny list" do
      tools = Registry.list_tools(deny: ["exec"])
      tool_names = Enum.map(tools, & &1.name)

      assert "read" in tool_names
      refute "exec" in tool_names
    end

    test "deny takes precedence over allow" do
      tools = Registry.list_tools(allow: ["*"], deny: ["exec"])
      tool_names = Enum.map(tools, & &1.name)

      refute "exec" in tool_names
    end

    test "returns error for unknown tool" do
      assert {:error, :tool_not_found} = Registry.execute("nonexistent", %{}, %{})
    end
  end

  describe "Read tool" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "test_read_#{System.unique_integer()}.txt")
      File.write!(test_file, "line 1\nline 2\nline 3\nline 4\nline 5")

      on_exit(fn -> File.rm(test_file) end)

      %{test_file: test_file}
    end

    test "reads entire file", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{path: test_file}, %{})
      assert content == "line 1\nline 2\nline 3\nline 4\nline 5"
    end

    test "reads with offset", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{path: test_file, offset: 3}, %{})
      assert content == "line 3\nline 4\nline 5"
    end

    test "reads with limit", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{path: test_file, limit: 2}, %{})
      assert content == "line 1\nline 2"
    end

    test "reads with offset and limit", %{test_file: test_file} do
      assert {:ok, content} = Read.execute(%{path: test_file, offset: 2, limit: 2}, %{})
      assert content == "line 2\nline 3"
    end

    test "returns error for nonexistent file" do
      assert {:error, message} = Read.execute(%{path: "/nonexistent/file.txt"}, %{})
      assert message =~ "not found"
    end
  end

  describe "Write tool" do
    test "writes content to file" do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "test_write_#{System.unique_integer()}.txt")

      on_exit(fn -> File.rm(test_file) end)

      assert {:ok, _} = Write.execute(%{path: test_file, content: "Hello World"}, %{})
      assert File.read!(test_file) == "Hello World"
    end

    test "creates parent directories" do
      tmp_dir = System.tmp_dir!()
      nested_path = Path.join([tmp_dir, "nested_#{System.unique_integer()}", "deep", "file.txt"])

      on_exit(fn -> File.rm_rf(Path.dirname(Path.dirname(nested_path))) end)

      assert {:ok, _} = Write.execute(%{path: nested_path, content: "content"}, %{})
      assert File.read!(nested_path) == "content"
    end
  end

  describe "Edit tool" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "test_edit_#{System.unique_integer()}.txt")
      File.write!(test_file, "Hello World\nThis is a test")

      on_exit(fn -> File.rm(test_file) end)

      %{test_file: test_file}
    end

    test "replaces text", %{test_file: test_file} do
      assert {:ok, _} =
               Edit.execute(
                 %{
                   path: test_file,
                   old_string: "World",
                   new_string: "Elixir"
                 },
                 %{}
               )

      assert File.read!(test_file) == "Hello Elixir\nThis is a test"
    end

    test "returns error when text not found", %{test_file: test_file} do
      assert {:error, message} =
               Edit.execute(
                 %{
                   path: test_file,
                   old_string: "Nonexistent",
                   new_string: "New"
                 },
                 %{}
               )

      assert message =~ "not found"
    end
  end

  describe "Exec tool" do
    test "executes simple command" do
      assert {:ok, output} = Exec.execute(%{command: "echo hello"}, %{})
      assert String.trim(output) == "hello"
    end

    test "captures exit code" do
      assert {:error, message} = Exec.execute(%{command: "exit 1"}, %{})
      assert message =~ "exited with code 1"
    end

    test "respects timeout" do
      assert {:error, message} =
               Exec.execute(
                 %{
                   command: "sleep 10",
                   timeout: 1
                 },
                 %{}
               )

      assert message =~ "timed out"
    end

    test "runs in specified workdir" do
      tmp_dir = System.tmp_dir!()
      assert {:ok, output} = Exec.execute(%{command: "pwd", workdir: tmp_dir}, %{})
      assert String.trim(output) == tmp_dir
    end
  end
end
