defmodule ClawdEx.Skills.LoaderTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Skills.Loader
  alias ClawdEx.Skills.Skill

  @fixtures_dir Path.expand("../../fixtures/skills", __DIR__)

  describe "parse_frontmatter/1" do
    test "parses valid frontmatter" do
      content = """
      ---
      name: test-skill
      description: A test skill
      ---
      # Body
      """

      assert {:ok, %{"name" => "test-skill", "description" => "A test skill"}, _body} =
               Loader.parse_frontmatter(content)
    end

    test "returns error for missing frontmatter" do
      assert {:error, :no_frontmatter} = Loader.parse_frontmatter("# Just markdown")
    end

    test "parses frontmatter with JSON metadata" do
      content = """
      ---
      name: test
      description: desc
      metadata: {"openclaw": {"requires": {"bins": ["curl"]}}}
      ---
      body
      """

      assert {:ok, fm, _} = Loader.parse_frontmatter(content)
      assert fm["name"] == "test"
      # YAML parses inline JSON as a map
      assert is_map(fm["metadata"])
    end

    test "parses frontmatter with YAML map metadata" do
      content = """
      ---
      name: test
      description: desc
      metadata:
        openclaw:
          requires:
            bins:
              - curl
      ---
      body
      """

      assert {:ok, fm, _} = Loader.parse_frontmatter(content)
      assert fm["metadata"]["openclaw"]["requires"]["bins"] == ["curl"]
    end
  end

  describe "parse_skill_file/2" do
    test "parses weather skill fixture" do
      path = Path.join(@fixtures_dir, "weather/SKILL.md")
      assert {:ok, %Skill{name: "weather"}} = Loader.parse_skill_file(path)
    end

    test "parses github skill fixture" do
      path = Path.join(@fixtures_dir, "github/SKILL.md")
      assert {:ok, %Skill{name: "github"} = skill} = Loader.parse_skill_file(path)
      assert skill.description =~ "GitHub"
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Loader.parse_skill_file("/nonexistent/SKILL.md")
    end

    test "returns error for missing name field" do
      content = """
      ---
      description: no name
      ---
      body
      """

      path = Path.join(System.tmp_dir!(), "test_skill_no_name/SKILL.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      assert {:error, :missing_required_fields} = Loader.parse_skill_file(path)
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "test_skill_no_name"))
    end
  end

  describe "load_all/1" do
    test "loads skills from a custom directory" do
      skills = Loader.load_all(extra_dirs: [@fixtures_dir], workspace: System.tmp_dir!())
      names = Enum.map(skills, & &1.name)
      assert "weather" in names
      assert "github" in names
      assert "nonexistent-tool" in names
    end

    test "workspace skills override bundled skills" do
      # Create temp workspace with a skill that has same name as fixture
      workspace = Path.join(System.tmp_dir!(), "test_ws_priority_#{:rand.uniform(100_000)}")
      skill_dir = Path.join(workspace, "skills/weather")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: weather
      description: Workspace weather override
      ---
      # Override
      """)

      skills =
        Loader.load_all(
          extra_dirs: [@fixtures_dir],
          workspace: workspace
        )

      weather = Enum.find(skills, &(&1.name == "weather"))
      assert weather.description == "Workspace weather override"
      assert weather.source == :workspace
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "test_ws_priority_*"))
    end
  end
end
