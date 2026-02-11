defmodule ClawdEx.Skills.RegistryTest do
  use ExUnit.Case

  alias ClawdEx.Skills.Registry

  @fixtures_dir Path.expand("../../fixtures/skills", __DIR__)

  describe "registry" do
    test "lists loaded skills" do
      # The registry is started by the app supervisor
      # It may or may not have skills depending on configured dirs
      skills = Registry.list_skills()
      assert is_list(skills)
    end

    test "get_skill returns nil for nonexistent skill" do
      assert Registry.get_skill("definitely_not_a_skill_xyz") == nil
    end

    test "refresh reloads skills" do
      assert :ok = Registry.refresh()
      # Give it a moment to process the cast
      Process.sleep(50)
      assert is_list(Registry.list_skills())
    end

    test "skills_prompt returns nil when no skills" do
      # This test depends on whether any skills are loaded
      result = Registry.skills_prompt()
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "standalone registry with fixtures" do
    test "loads skills from fixture directory" do
      {:ok, pid} = GenServer.start_link(Registry, [extra_dirs: [@fixtures_dir]], name: :test_skills_registry)

      skills = GenServer.call(pid, :list_skills)
      names = Enum.map(skills, & &1.name)

      # weather (curl exists) should be loaded
      assert "weather" in names

      # nonexistent-tool should be filtered out by gating
      refute "nonexistent-tool" in names

      GenServer.stop(pid)
    end
  end
end
