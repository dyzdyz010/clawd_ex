defmodule ClawdEx.Security.GroupWhitelistTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Security.GroupWhitelist
  alias ClawdEx.Agents.Agent

  describe "check/2" do
    test "allows all groups when allowed_groups is empty" do
      agent = %Agent{allowed_groups: []}
      assert :allow == GroupWhitelist.check(agent, "12345")
      assert :allow == GroupWhitelist.check(agent, "-100987654")
    end

    test "allows all groups when allowed_groups is nil" do
      agent = %Agent{allowed_groups: nil}
      assert :allow == GroupWhitelist.check(agent, "12345")
    end

    test "allows whitelisted group" do
      agent = %Agent{allowed_groups: ["-100111", "-100222", "-100333"]}
      assert :allow == GroupWhitelist.check(agent, "-100222")
    end

    test "denies non-whitelisted group" do
      agent = %Agent{allowed_groups: ["-100111", "-100222"]}
      assert :deny == GroupWhitelist.check(agent, "-100999")
    end

    test "handles string/integer comparison correctly" do
      agent = %Agent{allowed_groups: ["12345"]}
      # String group_id should match
      assert :allow == GroupWhitelist.check(agent, "12345")
      # Integer group_id should also match (via to_string)
      assert :allow == GroupWhitelist.check(agent, 12345)
    end

    test "handles nil agent gracefully" do
      assert :allow == GroupWhitelist.check(nil, "12345")
    end
  end
end
