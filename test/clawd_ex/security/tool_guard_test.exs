defmodule ClawdEx.Security.ToolGuardTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Security.ToolGuard

  # ============================================================================
  # tool_allowed_for_agent?/2
  # ============================================================================

  describe "tool_allowed_for_agent?/2" do
    test "allows all tools when agent has no permission config" do
      agent = %{name: "test", allowed_tools: [], denied_tools: []}
      assert ToolGuard.tool_allowed_for_agent?("read", agent)
      assert ToolGuard.tool_allowed_for_agent?("exec", agent)
      assert ToolGuard.tool_allowed_for_agent?("gateway", agent)
    end

    test "allows all tools when agent has wildcard allow" do
      agent = %{name: "test", allowed_tools: ["*"], denied_tools: []}
      assert ToolGuard.tool_allowed_for_agent?("read", agent)
      assert ToolGuard.tool_allowed_for_agent?("exec", agent)
    end

    test "filters tools by allow list" do
      agent = %{name: "test", allowed_tools: ["read", "write"], denied_tools: []}
      assert ToolGuard.tool_allowed_for_agent?("read", agent)
      assert ToolGuard.tool_allowed_for_agent?("write", agent)
      refute ToolGuard.tool_allowed_for_agent?("exec", agent)
      refute ToolGuard.tool_allowed_for_agent?("gateway", agent)
    end

    test "deny takes priority over allow" do
      agent = %{name: "test", allowed_tools: ["*"], denied_tools: ["gateway", "exec"]}
      assert ToolGuard.tool_allowed_for_agent?("read", agent)
      assert ToolGuard.tool_allowed_for_agent?("write", agent)
      refute ToolGuard.tool_allowed_for_agent?("gateway", agent)
      refute ToolGuard.tool_allowed_for_agent?("exec", agent)
    end

    test "deny takes priority over explicit allow" do
      agent = %{name: "test", allowed_tools: ["read", "exec"], denied_tools: ["exec"]}
      assert ToolGuard.tool_allowed_for_agent?("read", agent)
      refute ToolGuard.tool_allowed_for_agent?("exec", agent)
    end

    test "wildcard deny blocks everything" do
      agent = %{name: "test", allowed_tools: ["*"], denied_tools: ["*"]}
      refute ToolGuard.tool_allowed_for_agent?("read", agent)
      refute ToolGuard.tool_allowed_for_agent?("exec", agent)
    end

    test "works with string-keyed maps" do
      agent = %{"name" => "test", "allowed_tools" => ["read"], "denied_tools" => ["exec"]}
      assert ToolGuard.tool_allowed_for_agent?("read", agent)
      refute ToolGuard.tool_allowed_for_agent?("exec", agent)
      refute ToolGuard.tool_allowed_for_agent?("write", agent)
    end
  end

  # ============================================================================
  # check_permission/3 — agent-level integration
  # ============================================================================

  describe "check_permission/3 with agent context" do
    test "allows tool when agent has no restrictions" do
      context = %{agent: %{name: "open-agent", allowed_tools: [], denied_tools: []}}
      assert :ok = ToolGuard.check_permission("read", %{}, context)
    end

    test "denies tool when agent deny list blocks it" do
      context = %{agent: %{name: "limited", allowed_tools: ["*"], denied_tools: ["exec"]}}
      assert {:error, {:tool_denied, msg}} = ToolGuard.check_permission("exec", %{}, context)
      assert msg =~ "not permitted for agent"
    end

    test "allows tool when agent allow list includes it" do
      context = %{agent: %{name: "reader", allowed_tools: ["read", "write"], denied_tools: []}}
      assert :ok = ToolGuard.check_permission("read", %{}, context)
    end

    test "denies tool not in agent allow list" do
      context = %{agent: %{name: "reader", allowed_tools: ["read"], denied_tools: []}}
      assert {:error, {:tool_denied, _}} = ToolGuard.check_permission("exec", %{}, context)
    end

    test "passes when no agent in context" do
      assert :ok = ToolGuard.check_permission("read", %{}, %{})
    end
  end

  # ============================================================================
  # check_permission/3 — command blocklist (existing behavior)
  # ============================================================================

  describe "check_permission/3 command blocklist" do
    test "blocks dangerous rm -rf /" do
      assert {:error, {:command_blocked, _}} =
               ToolGuard.check_permission("exec", %{"command" => "rm -rf / "}, %{})
    end

    test "allows normal exec" do
      assert :ok = ToolGuard.check_permission("exec", %{"command" => "ls -la"}, %{})
    end
  end
end
