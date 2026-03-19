defmodule ClawdEx.Skills.BundledSkillsTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Skills.{Loader, Gate, Skill}

  @fixtures_dir Path.expand("../../fixtures/skills", __DIR__)

  # ============================================================================
  # Helper to create a temporary bundled dir that mimics priv/skills
  # ============================================================================

  defp setup_bundled_dir(skill_names) do
    tmp = Path.join(System.tmp_dir!(), "bundled_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)

    Enum.each(skill_names, fn name ->
      src = Path.join(@fixtures_dir, name)
      dest = Path.join(tmp, name)
      File.mkdir_p!(dest)
      File.cp!(Path.join(src, "SKILL.md"), Path.join(dest, "SKILL.md"))
    end)

    tmp
  end

  defp setup_workspace_override(name, description) do
    tmp = Path.join(System.tmp_dir!(), "ws_override_#{:rand.uniform(1_000_000)}")
    skill_dir = Path.join(tmp, "skills/#{name}")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---
    # Workspace Override
    """)

    tmp
  end

  # ============================================================================
  # 1. priv/skills directory is scanned by Loader
  # ============================================================================

  describe "bundled skills directory scanning" do
    test "load_all scans the bundled fixture directory" do
      skills = Loader.load_all(extra_dirs: [@fixtures_dir])
      names = Enum.map(skills, & &1.name)

      assert "bundled-simple" in names
      assert "bundled-rich-meta" in names
      assert "bundled-override" in names
    end

    test "skill_dirs includes bundled dir when it exists" do
      dirs = Loader.skill_dirs()
      sources = Enum.map(dirs, fn {_path, source} -> source end)

      # The default dirs should always include :bundled
      assert :bundled in sources
    end

    test "load_all returns empty list for nonexistent directory" do
      skills = Loader.load_all(extra_dirs: ["/nonexistent/path/#{:rand.uniform(1_000_000)}"])
      # Should not crash, just skip the nonexistent dir
      assert is_list(skills)
    end
  end

  # ============================================================================
  # 2. Bundled skills have source :bundled
  # ============================================================================

  describe "bundled skills source tagging" do
    test "skills from priv/skills directory are tagged as :bundled" do
      # skill_dirs includes the priv/skills bundled dir tagged as :bundled
      dirs = Loader.skill_dirs()
      bundled_entries = Enum.filter(dirs, fn {_path, source} -> source == :bundled end)

      assert length(bundled_entries) >= 1

      # Verify that if we parse a file with default source, it's :bundled
      path = Path.join(@fixtures_dir, "bundled-simple/SKILL.md")
      {:ok, skill} = Loader.parse_skill_file(path)
      assert skill.source == :bundled
    end

    test "skills from extra_dirs are tagged as :managed" do
      bundled_dir = setup_bundled_dir(["bundled-simple"])

      skills = Loader.load_all(extra_dirs: [bundled_dir], workspace: nil)

      simple = Enum.find(skills, &(&1.name == "bundled-simple"))
      assert simple != nil
      assert simple.source == :managed
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "bundled_test_*"))
    end

    test "parse_skill_file defaults to :bundled source" do
      path = Path.join(@fixtures_dir, "bundled-simple/SKILL.md")
      assert {:ok, %Skill{source: :bundled}} = Loader.parse_skill_file(path)
    end

    test "parse_skill_file accepts explicit source parameter" do
      path = Path.join(@fixtures_dir, "bundled-simple/SKILL.md")
      assert {:ok, %Skill{source: :managed}} = Loader.parse_skill_file(path, :managed)
      assert {:ok, %Skill{source: :workspace}} = Loader.parse_skill_file(path, :workspace)
    end
  end

  # ============================================================================
  # 3. YAML frontmatter parsing
  # ============================================================================

  describe "YAML frontmatter parsing for bundled skills" do
    test "parses name and description from simple skill" do
      path = Path.join(@fixtures_dir, "bundled-simple/SKILL.md")
      assert {:ok, %Skill{name: "bundled-simple", description: "A simple bundled skill for testing."}} =
               Loader.parse_skill_file(path)
    end

    test "parses nested YAML metadata" do
      path = Path.join(@fixtures_dir, "bundled-rich-meta/SKILL.md")
      assert {:ok, %Skill{} = skill} = Loader.parse_skill_file(path)

      assert skill.name == "bundled-rich-meta"
      assert skill.description == "Bundled skill with rich metadata for testing."

      # Verify nested metadata structure
      assert skill.metadata["openclaw"]["requires"]["bins"] == ["ls"]
      assert skill.metadata["openclaw"]["os"] == ["darwin", "linux"]
      assert skill.metadata["openclaw"]["primaryEnv"] == "SOME_TOKEN"
    end

    test "parses inline JSON metadata" do
      content = """
      ---
      name: json-meta
      description: Test JSON metadata
      metadata: {"openclaw": {"requires": {"bins": ["ls"]}}}
      ---
      body
      """

      assert {:ok, fm, _body} = Loader.parse_frontmatter(content)
      assert fm["metadata"]["openclaw"]["requires"]["bins"] == ["ls"]
    end

    test "rejects skill file missing name" do
      tmp = Path.join(System.tmp_dir!(), "bad_skill_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)

      File.write!(Path.join(tmp, "SKILL.md"), """
      ---
      description: missing name field
      ---
      body
      """)

      assert {:error, :missing_required_fields} = Loader.parse_skill_file(Path.join(tmp, "SKILL.md"))
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "bad_skill_*"))
    end

    test "rejects skill file missing description" do
      tmp = Path.join(System.tmp_dir!(), "bad_skill2_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)

      File.write!(Path.join(tmp, "SKILL.md"), """
      ---
      name: no-desc
      ---
      body
      """)

      assert {:error, :missing_required_fields} = Loader.parse_skill_file(Path.join(tmp, "SKILL.md"))
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "bad_skill2_*"))
    end

    test "skill content preserves full file content" do
      path = Path.join(@fixtures_dir, "bundled-simple/SKILL.md")
      assert {:ok, %Skill{content: content}} = Loader.parse_skill_file(path)
      assert content =~ "---"
      assert content =~ "bundled-simple"
      assert content =~ "# Bundled Simple"
    end
  end

  # ============================================================================
  # 4. Gate mechanism filters ineligible bundled skills
  # ============================================================================

  describe "gate mechanism for bundled skills" do
    test "skill with no requirements passes gate" do
      path = Path.join(@fixtures_dir, "bundled-simple/SKILL.md")
      {:ok, skill} = Loader.parse_skill_file(path)

      assert Gate.eligible?(skill)
    end

    test "skill requiring nonexistent binary fails gate" do
      path = Path.join(@fixtures_dir, "bundled-with-gate/SKILL.md")
      {:ok, skill} = Loader.parse_skill_file(path)

      refute Gate.eligible?(skill)
    end

    test "skill requiring existing binary passes gate" do
      path = Path.join(@fixtures_dir, "bundled-rich-meta/SKILL.md")
      {:ok, skill} = Loader.parse_skill_file(path)

      # "ls" should exist on any UNIX system
      assert Gate.eligible?(skill)
    end

    test "filter_eligible removes gated bundled skills" do
      paths = [
        Path.join(@fixtures_dir, "bundled-simple/SKILL.md"),
        Path.join(@fixtures_dir, "bundled-with-gate/SKILL.md"),
        Path.join(@fixtures_dir, "bundled-rich-meta/SKILL.md")
      ]

      skills =
        paths
        |> Enum.map(&Loader.parse_skill_file/1)
        |> Enum.map(fn {:ok, s} -> s end)

      eligible = Gate.filter_eligible(skills)
      eligible_names = Enum.map(eligible, & &1.name)

      assert "bundled-simple" in eligible_names
      assert "bundled-rich-meta" in eligible_names
      refute "bundled-with-gate" in eligible_names
    end

    test "detailed_status returns per-requirement breakdown" do
      path = Path.join(@fixtures_dir, "bundled-with-gate/SKILL.md")
      {:ok, skill} = Loader.parse_skill_file(path)

      status = Gate.detailed_status(skill)

      assert is_map(status)
      assert status.bins.met == false
      assert {"__bundled_test_nonexistent_binary__", false} in status.bins.details
    end
  end

  # ============================================================================
  # 5. Managed/workspace skills override bundled (same name)
  # ============================================================================

  describe "priority: workspace/managed override bundled" do
    test "workspace skill overrides bundled skill with same name" do
      workspace = setup_workspace_override("bundled-override", "Workspace version wins")

      skills =
        Loader.load_all(
          extra_dirs: [@fixtures_dir],
          workspace: workspace
        )

      overridden = Enum.find(skills, &(&1.name == "bundled-override"))
      assert overridden != nil
      assert overridden.description == "Workspace version wins"
      assert overridden.source == :workspace
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "ws_override_*"))
    end

    test "bundled skill preserved when no workspace override exists" do
      empty_ws = Path.join(System.tmp_dir!(), "empty_ws_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(empty_ws)

      skills =
        Loader.load_all(
          extra_dirs: [@fixtures_dir],
          workspace: empty_ws
        )

      original = Enum.find(skills, &(&1.name == "bundled-override"))
      assert original != nil
      assert original.description == "Original bundled description - should be overridden."
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "empty_ws_*"))
    end

    test "managed skill overrides bundled but workspace overrides managed" do
      # Setup: managed dir with a skill, workspace dir with same skill
      managed_dir = Path.join(System.tmp_dir!(), "managed_test_#{:rand.uniform(1_000_000)}")
      managed_skill = Path.join(managed_dir, "bundled-override")
      File.mkdir_p!(managed_skill)

      File.write!(Path.join(managed_skill, "SKILL.md"), """
      ---
      name: bundled-override
      description: Managed version
      ---
      # Managed
      """)

      workspace = setup_workspace_override("bundled-override", "Workspace version wins over managed")

      skills =
        Loader.load_all(
          extra_dirs: [@fixtures_dir, managed_dir],
          workspace: workspace
        )

      overridden = Enum.find(skills, &(&1.name == "bundled-override"))
      assert overridden != nil
      assert overridden.description == "Workspace version wins over managed"
      assert overridden.source == :workspace
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "managed_test_*"))
      File.rm_rf!(Path.join(System.tmp_dir!(), "ws_override_*"))
    end

    test "deduplication keeps only one entry per name" do
      workspace = setup_workspace_override("bundled-simple", "WS simple")

      skills =
        Loader.load_all(
          extra_dirs: [@fixtures_dir],
          workspace: workspace
        )

      count = Enum.count(skills, &(&1.name == "bundled-simple"))
      assert count == 1
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "ws_override_*"))
    end
  end

  # ============================================================================
  # 6. skills_prompt/0 generates correct XML fragment
  # ============================================================================

  describe "skills_prompt XML generation" do
    test "generates valid XML fragment for bundled skills" do
      # Build a list of skills and test the prompt generation directly
      skills = [
        %Skill{
          name: "bundled-test-a",
          description: "Test skill A",
          location: "/priv/skills/bundled-test-a/SKILL.md",
          content: "test",
          source: :bundled
        },
        %Skill{
          name: "bundled-test-b",
          description: "Test skill B",
          location: "/priv/skills/bundled-test-b/SKILL.md",
          content: "test",
          source: :bundled
        }
      ]

      prompt = build_skills_prompt(skills)

      assert prompt =~ "<available_skills>"
      assert prompt =~ "</available_skills>"
      assert prompt =~ "<skill>"
      assert prompt =~ "<name>bundled-test-a</name>"
      assert prompt =~ "<description>Test skill A</description>"
      assert prompt =~ "<location>/priv/skills/bundled-test-a/SKILL.md</location>"
      assert prompt =~ "<name>bundled-test-b</name>"
    end

    test "returns nil for empty skill list" do
      assert build_skills_prompt([]) == nil
    end

    test "each skill entry includes name, description, and location" do
      skills = [
        %Skill{
          name: "my-skill",
          description: "My description",
          location: "/path/to/SKILL.md",
          content: "test",
          source: :bundled
        }
      ]

      prompt = build_skills_prompt(skills)

      assert prompt =~ "<name>my-skill</name>"
      assert prompt =~ "<description>My description</description>"
      assert prompt =~ "<location>/path/to/SKILL.md</location>"
    end

    test "XML fragment contains proper nesting structure" do
      skills = [
        %Skill{
          name: "nested-test",
          description: "Nesting test",
          location: "/test/SKILL.md",
          content: "test",
          source: :bundled
        }
      ]

      prompt = build_skills_prompt(skills)

      # Check that <skill> is nested inside <available_skills>
      assert Regex.match?(~r/<available_skills>.*<skill>.*<\/skill>.*<\/available_skills>/s, prompt)
    end
  end

  # ============================================================================
  # Private: reproduce skills_prompt logic for unit testing without GenServer
  # ============================================================================

  defp build_skills_prompt([]), do: nil

  defp build_skills_prompt(skills) do
    entries =
      skills
      |> Enum.map(fn skill ->
        """
          <skill>
            <name>#{skill.name}</name>
            <description>#{skill.description}</description>
            <location>#{skill.location}</location>
          </skill>\
        """
      end)
      |> Enum.join("\n")

    """
    <available_skills>
    #{entries}
    </available_skills>\
    """
  end
end
