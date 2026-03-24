defmodule ClawdEx.Tools.SandboxIntegrationTest do
  @moduledoc """
  Integration tests: verify that read/write/edit tools respect sandbox_mode.
  """
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.{Read, Write, Edit}

  @workspace System.tmp_dir!() |> Path.join("clawd_sandbox_test_#{:rand.uniform(100_000)}")
  @inside_file Path.join(@workspace, "allowed.txt")
  @outside_file Path.join(System.tmp_dir!(), "outside_sandbox_#{:rand.uniform(100_000)}.txt")

  setup_all do
    File.mkdir_p!(@workspace)
    File.write!(@inside_file, "hello world")
    File.write!(@outside_file, "secret data")

    on_exit(fn ->
      File.rm_rf!(@workspace)
      File.rm(@outside_file)
    end)

    :ok
  end

  # ── Read tool ──

  describe "Read tool sandbox" do
    test "unrestricted allows reading any file" do
      context = %{workspace: @workspace, sandbox_mode: "unrestricted"}
      assert {:ok, "secret data"} = Read.execute(%{"path" => @outside_file}, context)
    end

    test "workspace mode allows reading inside workspace" do
      context = %{workspace: @workspace, sandbox_mode: "workspace"}
      assert {:ok, "hello world"} = Read.execute(%{"path" => @inside_file}, context)
    end

    test "workspace mode blocks reading outside workspace" do
      context = %{workspace: @workspace, sandbox_mode: "workspace"}
      assert {:error, msg} = Read.execute(%{"path" => @outside_file}, context)
      assert msg =~ "Access denied"
    end

    test "strict mode blocks reading outside workspace" do
      context = %{workspace: @workspace, sandbox_mode: "strict"}
      assert {:error, msg} = Read.execute(%{"path" => @outside_file}, context)
      assert msg =~ "Access denied"
    end

    test "strict mode allows reading inside workspace" do
      context = %{workspace: @workspace, sandbox_mode: "strict"}
      assert {:ok, "hello world"} = Read.execute(%{"path" => @inside_file}, context)
    end

    test "nil sandbox_mode defaults to unrestricted" do
      context = %{workspace: @workspace}
      assert {:ok, _} = Read.execute(%{"path" => @outside_file}, context)
    end
  end

  # ── Write tool ──

  describe "Write tool sandbox" do
    test "unrestricted allows writing anywhere" do
      target = Path.join(System.tmp_dir!(), "write_sandbox_test_#{:rand.uniform(100_000)}.txt")
      context = %{workspace: @workspace, sandbox_mode: "unrestricted"}

      assert {:ok, _} = Write.execute(%{"path" => target, "content" => "test"}, context)
      File.rm(target)
    end

    test "workspace mode allows writing inside workspace" do
      target = Path.join(@workspace, "new_file.txt")
      context = %{workspace: @workspace, sandbox_mode: "workspace"}

      assert {:ok, _} = Write.execute(%{"path" => target, "content" => "test"}, context)
      assert File.read!(target) == "test"
      File.rm(target)
    end

    test "workspace mode blocks writing outside workspace" do
      target = Path.join(System.tmp_dir!(), "write_blocked_#{:rand.uniform(100_000)}.txt")
      context = %{workspace: @workspace, sandbox_mode: "workspace"}

      assert {:error, msg} = Write.execute(%{"path" => target, "content" => "test"}, context)
      assert msg =~ "Access denied"
      refute File.exists?(target)
    end
  end

  # ── Edit tool ──

  describe "Edit tool sandbox" do
    test "unrestricted allows editing any file" do
      target = Path.join(System.tmp_dir!(), "edit_sandbox_test_#{:rand.uniform(100_000)}.txt")
      File.write!(target, "old text")
      context = %{workspace: @workspace, sandbox_mode: "unrestricted"}

      assert {:ok, _} = Edit.execute(
        %{"path" => target, "old_string" => "old text", "new_string" => "new text"},
        context
      )

      assert File.read!(target) == "new text"
      File.rm(target)
    end

    test "workspace mode allows editing inside workspace" do
      target = Path.join(@workspace, "editable.txt")
      File.write!(target, "old text")
      context = %{workspace: @workspace, sandbox_mode: "workspace"}

      assert {:ok, _} = Edit.execute(
        %{"path" => target, "old_string" => "old text", "new_string" => "new text"},
        context
      )

      assert File.read!(target) == "new text"
      File.rm(target)
    end

    test "workspace mode blocks editing outside workspace" do
      target = Path.join(System.tmp_dir!(), "edit_blocked_#{:rand.uniform(100_000)}.txt")
      File.write!(target, "old text")
      context = %{workspace: @workspace, sandbox_mode: "workspace"}

      assert {:error, msg} = Edit.execute(
        %{"path" => target, "old_string" => "old text", "new_string" => "new text"},
        context
      )

      assert msg =~ "Access denied"
      assert File.read!(target) == "old text"
      File.rm(target)
    end
  end
end
