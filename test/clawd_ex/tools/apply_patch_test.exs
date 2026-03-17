defmodule ClawdEx.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.ApplyPatch

  describe "name/0" do
    test "returns apply_patch" do
      assert ApplyPatch.name() == "apply_patch"
    end
  end

  describe "description/0" do
    test "returns a description string" do
      assert is_binary(ApplyPatch.description())
    end
  end

  describe "parameters/0" do
    test "returns parameter schema with patch" do
      params = ApplyPatch.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :patch)
      assert "patch" in params.required
    end
  end

  describe "execute/2" do
    setup do
      # Create a temp directory with a git repo
      tmp_dir = Path.join(System.tmp_dir!(), "apply_patch_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      # Init git repo so git apply works
      System.cmd("git", ["init"], cd: tmp_dir, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      # Create a file and commit it
      File.write!(Path.join(tmp_dir, "hello.txt"), "hello\n")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init"], cd: tmp_dir, stderr_to_stdout: true)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "applies a valid patch", %{tmp_dir: tmp_dir} do
      patch = """
      diff --git a/hello.txt b/hello.txt
      index ce01362..a042389 100644
      --- a/hello.txt
      +++ b/hello.txt
      @@ -1 +1 @@
      -hello
      +hello world
      """

      assert {:ok, %{status: "applied"}} =
               ApplyPatch.execute(%{"patch" => patch}, %{workspace: tmp_dir})

      assert File.read!(Path.join(tmp_dir, "hello.txt")) == "hello world\n"
    end

    test "returns error for invalid patch", %{tmp_dir: tmp_dir} do
      patch = "this is not a valid patch"

      assert {:error, _reason} =
               ApplyPatch.execute(%{"patch" => patch}, %{workspace: tmp_dir})
    end

    test "returns error when patch parameter missing" do
      assert {:error, "patch parameter is required"} = ApplyPatch.execute(%{}, %{})
    end
  end
end
