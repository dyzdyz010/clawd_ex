# Skills System

The Skills system in ClawdEx allows agents to access specialized capabilities through simple text-based skill files. Each skill is defined by a `SKILL.md` file that contains instructions and metadata for extending agent functionality.

## Overview

Skills in ClawdEx work through prompt injection - they are pure text instructions that get loaded into the agent's context when conditions are met. This approach offers several benefits:

- **No executable code required** - Skills are markdown files with instructions
- **Hot-reloadable** - Changes take effect immediately via `Skills.Registry.refresh()`
- **Dependency-aware** - Only loads skills when system requirements are met
- **Hierarchical priority** - Workspace skills override managed skills override bundled skills

## Skills vs Plugins

ClawdEx provides two distinct ways to extend agent capabilities, each suited for different use cases:

| Aspect | Skills | Plugins |
|--------|--------|---------|
| **Nature** | Prompt injection | Executable code |
| **Runtime** | None (text-only) | Node.js / Any runtime |
| **Protocol** | File reading | MCP (Model Context Protocol) |
| **Installation** | clawhub / file copy | npm / clawd_ex plugins |
| **Purpose** | Teach agents to use CLI tools | Provide new tool capabilities |
| **Security** | Read-only text files | Sandboxed execution |
| **Performance** | Instant (in-memory) | Network/process overhead |
| **Flexibility** | Limited to existing tools | Full programmatic control |
| **Dependencies** | System binaries | Runtime environments |
| **Hot Reload** | Immediate | Configuration reload |

### When to Use Skills

Choose skills when you need to:
- Teach agents how to use existing CLI tools
- Provide usage instructions and best practices
- Add conditional logic based on system capabilities
- Share knowledge that doesn't require new code
- Ensure maximum performance and security

**Example**: A `git` skill teaches agents Git commands, branch management, and repository workflows without requiring additional software.

### When to Use Plugins

Choose plugins when you need to:
- Connect to external APIs and services
- Implement complex business logic
- Process data in ways existing tools cannot
- Integrate with proprietary systems
- Provide real-time capabilities

**Example**: A Feishu plugin provides direct API integration for document creation, calendar management, and team collaboration beyond what CLI tools offer.

### Hybrid Approach

Many scenarios benefit from using both:
1. **Plugin** handles API communication and data processing
2. **Skill** provides usage patterns and best practices

This combination offers the flexibility of executable code with the guidance of instructional content.

## Directory Structure & Priority

ClawdEx scans three locations for skills, with higher priority sources overriding lower ones:

```
Priority Level    | Location              | Source    | Description
------------------|-----------------------|-----------|------------------
🏆 Highest        | <workspace>/skills/   | workspace | Project-specific skills
🥈 Medium         | ~/.clawd/skills/      | managed   | User-installed skills  
🥉 Lowest         | priv/skills/          | bundled   | Built-in skills
```

When skills with the same name exist in multiple locations, the higher priority version is used.

## SKILL.md Format

Each skill must contain a `SKILL.md` file with YAML frontmatter and markdown body:

### Basic Structure

```yaml
---
name: example-skill
description: "Brief description of what this skill does and when to use it."
metadata:
  clawd_ex:
    emoji: "🔧"
    requires:
      bins: ["required-binary"]
      anyBins: ["alternative1", "alternative2"] 
      env: ["REQUIRED_ENV_VAR"]
      config: ["required_config_key"]
      os: ["darwin", "linux"]
    install:
      - id: "brew"
        kind: "brew"
        formula: "package-name"
        bins: ["binary-name"]
        label: "Install via Homebrew"
---

# Skill Title

Your skill instructions go here in markdown format.

## When to Use
- Use this skill when...
- Don't use for...

## Examples
```bash
command --example
```
```

### Metadata Fields

#### Core Fields (Required)
- **`name`** - Unique identifier for the skill
- **`description`** - Brief description shown in skill listings

#### ClawdEx Metadata
- **`emoji`** - Display icon for the skill
- **`requires`** - Dependency requirements (see [Gate Mechanism](#gate-mechanism))
- **`install`** - Installation instructions for dependencies

### Gate Mechanism

The gate system automatically checks dependencies and only loads skills that meet all requirements:

| Check Type | Field | Description | Example |
|------------|-------|-------------|---------|
| **Binaries** | `requires.bins` | All listed binaries must exist on PATH | `["git", "curl"]` |
| **Any Binary** | `requires.anyBins` | At least one binary must exist | `["docker", "podman"]` |
| **Environment** | `requires.env` | All env vars must be set | `["API_KEY", "TOKEN"]` |
| **Config** | `requires.config` | All config keys must exist | `["database_url"]` |
| **OS Filter** | `requires.os` | Current OS must be in list | `["darwin", "linux"]` |

#### Gate Check Examples

```yaml
# Requires both git and gh CLI
requires:
  bins: ["git", "gh"]

# Requires either Docker or Podman
requires:
  anyBins: ["docker", "podman"]

# Requires API key and specific OS
requires:
  env: ["GITHUB_TOKEN"]
  os: ["darwin", "linux"]
```

## Creating Custom Skills

### 1. Create Skill Directory

Create a new folder in your workspace skills directory:

```bash
mkdir -p <workspace>/skills/my-skill
```

### 2. Write SKILL.md

Create the skill file with proper frontmatter:

```bash
cat > <workspace>/skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: "Custom skill for my specific use case."
metadata:
  clawd_ex:
    emoji: "⚡"
    requires:
      bins: ["curl"]
---

# My Custom Skill

Instructions for how to use this skill...

## Commands

```bash
curl -X GET https://api.example.com/data
```

EOF
```

### 3. Hot Reload

Refresh the skills registry to load your new skill:

```elixir
# In IEx console
Skills.Registry.refresh()
```

The skill will be immediately available if all gate requirements are met.

## Skill Development Best Practices

### File Organization

```
skills/my-skill/
├── SKILL.md              # Main skill definition
├── references/           # Supporting documentation  
│   ├── api-docs.md
│   └── examples.md
└── scripts/             # Helper scripts (if needed)
    └── setup.sh
```

### Writing Effective Instructions

1. **Be specific** - Clear when to use vs. when not to use
2. **Provide examples** - Include common command patterns
3. **Document setup** - Any required authentication or configuration
4. **Handle errors** - Common failure modes and solutions

### Example Skill Template

```yaml
---
name: my-tool
description: "Tool for X. Use when: (1) doing Y, (2) checking Z. NOT for: manual tasks, complex workflows."
metadata:
  clawd_ex:
    emoji: "🔧"
    requires:
      bins: ["my-tool"]
    install:
      - id: "brew"
        kind: "brew" 
        formula: "my-tool"
        bins: ["my-tool"]
        label: "Install My Tool"
---

# My Tool Skill

Brief description and purpose.

## When to Use

✅ **USE this skill when:**
- Specific use case 1
- Specific use case 2

❌ **DON'T use when:**
- Alternative exists
- Out of scope

## Setup

```bash
# One-time setup
my-tool config setup
```

## Common Patterns

### Basic Usage
```bash
my-tool command --option value
```

### Advanced Usage  
```bash
my-tool complex-command --flag1 --flag2=value
```

## Troubleshooting

- **Problem**: Solution
- **Error message**: What to do
```

## Managing Skills

### Programmatic Access

```elixir
# List available skills
Skills.Registry.list_skills()

# Get specific skill
Skills.Registry.get_skill("github")

# Check skill requirements
Skills.Registry.get_skill_details("docker")

# Refresh from disk
Skills.Registry.refresh()
```

### Enabling/Disabling Skills

```elixir
# Disable a skill temporarily
Skills.Registry.toggle_skill("problematic-skill", false)

# Re-enable
Skills.Registry.toggle_skill("problematic-skill", true)
```

## Integration with Agents

Skills are automatically injected into agent contexts based on:

1. **Gate requirements** - Only eligible skills are included
2. **Enabled state** - Disabled skills are excluded  
3. **Context relevance** - Skills appear in `<available_skills>` section

### Agent Prompt Integration

When skills are available, they appear in the agent prompt as:

```xml
<available_skills>
  <skill>
    <name>github</name>
    <description>GitHub operations via gh CLI...</description>
    <location>/path/to/skill/SKILL.md</location>
  </skill>
  <!-- more skills... -->
</available_skills>
```

Agents can then read specific skill files when needed for detailed instructions.

## Built-in Skills

ClawdEx includes 49 built-in skills covering:

- **Development** - git, github, docker, coding-agent
- **File Management** - file operations, search, organization  
- **Communication** - email, messaging, notifications
- **Automation** - cron jobs, workflows, scripting
- **System** - process management, monitoring, utilities

See `priv/skills/` directory for the full collection.