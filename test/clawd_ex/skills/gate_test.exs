defmodule ClawdEx.Skills.GateTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Skills.Gate
  alias ClawdEx.Skills.Skill

  defp make_skill(metadata \\ %{}) do
    %Skill{
      name: "test",
      description: "test",
      location: "/test/SKILL.md",
      content: "test",
      metadata: metadata
    }
  end

  describe "eligible?/1" do
    test "skill with no metadata is eligible" do
      assert Gate.eligible?(make_skill())
    end

    test "skill with empty requires is eligible" do
      assert Gate.eligible?(make_skill(%{"openclaw" => %{"requires" => %{}}}))
    end

    test "skill requiring existing binary is eligible" do
      # "ls" should exist on any unix system
      skill = make_skill(%{"openclaw" => %{"requires" => %{"bins" => ["ls"]}}})
      assert Gate.eligible?(skill)
    end

    test "skill requiring nonexistent binary is not eligible" do
      skill = make_skill(%{"openclaw" => %{"requires" => %{"bins" => ["nonexistent_binary_xyz"]}}})
      refute Gate.eligible?(skill)
    end

    test "anyBins passes if at least one exists" do
      skill = make_skill(%{"openclaw" => %{"requires" => %{"anyBins" => ["nonexistent_xyz", "ls"]}}})
      assert Gate.eligible?(skill)
    end

    test "anyBins fails if none exist" do
      skill = make_skill(%{"openclaw" => %{"requires" => %{"anyBins" => ["nope1_xyz", "nope2_xyz"]}}})
      refute Gate.eligible?(skill)
    end

    test "env check passes when var is set" do
      System.put_env("CLAWD_TEST_GATE_VAR", "1")
      skill = make_skill(%{"openclaw" => %{"requires" => %{"env" => ["CLAWD_TEST_GATE_VAR"]}}})
      assert Gate.eligible?(skill)
    after
      System.delete_env("CLAWD_TEST_GATE_VAR")
    end

    test "env check fails when var is not set" do
      skill = make_skill(%{"openclaw" => %{"requires" => %{"env" => ["CLAWD_NONEXISTENT_VAR_XYZ"]}}})
      refute Gate.eligible?(skill)
    end

    test "os filter passes on current os" do
      current = case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        {:win32, _} -> "win32"
      end

      skill = make_skill(%{"openclaw" => %{"os" => [current]}})
      assert Gate.eligible?(skill)
    end

    test "os filter fails on wrong os" do
      skill = make_skill(%{"openclaw" => %{"os" => ["win32_fake_os"]}})
      refute Gate.eligible?(skill)
    end
  end

  describe "filter_eligible/1" do
    test "filters out ineligible skills" do
      good = make_skill(%{"openclaw" => %{"requires" => %{"bins" => ["ls"]}}})
      bad = make_skill(%{"openclaw" => %{"requires" => %{"bins" => ["nonexistent_binary_xyz"]}}})

      result = Gate.filter_eligible([good, bad])
      assert length(result) == 1
      assert hd(result) == good
    end
  end
end
