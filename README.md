# ClawdEx 🦀

**The Elixir-Powered AI Agent Framework**

> Build intelligent, fault-tolerant AI assistants with the power of Elixir/OTP.

[![Elixir](https://img.shields.io/badge/Elixir-1.15+-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8+-orange.svg)](https://www.phoenixframework.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## ✨ Why ClawdEx?

| Feature | ClawdEx | Traditional Frameworks |
|---------|---------|----------------------|
| **Concurrency** | OTP GenServers, millions of lightweight processes | Thread pools, limited scaling |
| **Fault Tolerance** | Supervisors auto-restart crashed agents | Manual error handling |
| **Real-time UI** | Phoenix LiveView, instant updates | REST polling, WebSocket complexity |
| **Hot Code Reload** | Update without downtime | Restart required |
| **Memory** | Hybrid BM25 + pgvector search | Basic keyword search |

---

## 🎯 Key Features

### 🤖 Intelligent Agent System
- **21+ Built-in Tools** - File I/O, shell execution, web search, browser automation
- **Streaming Responses** - Real-time token streaming with code block protection
- **Smart Memory** - Hybrid BM25 + vector search, Chinese language support
- **Auto Compaction** - AI-powered conversation summarization

### 🌐 Multi-Channel Support
- **Telegram** - Full bot integration with Telegex
- **Discord** - Slash commands with Nostrum
- **WebChat** - Beautiful Phoenix LiveView interface

### 🧩 Plugin System V2
- **Dual Runtime** - Native Elixir plugins (.beam) + Node.js bridge (JSON-RPC)
- **OpenClaw Compatible** - Existing Node.js plugins work without modification
- **Hot Reload** - Install/uninstall plugins without restart
- **CLI Management** - `clawd plugins install/config/enable/doctor`
- **Rich Ecosystem** - Access to both Elixir/OTP and npm ecosystems

### 📊 Management Dashboard
8 LiveView pages for complete control:

| Page | Features |
|------|----------|
| **Dashboard** | Stats, health checks, recent activity |
| **Chat** | Real-time streaming, tool execution history |
| **Sessions** | Filter, search, archive, delete |
| **Agents** | CRUD with model selection |
| **Cron Jobs** | Create, edit, run history, execution modes |
| **Logs** | Level filtering, auto-refresh |
| **Settings** | Environment, AI providers, system info |

### ⏰ Cron Execution System
Real AI-powered scheduled tasks:

```
┌─────────────────────────────────────────────────┐
│  system_event mode                              │
│  └─ Inject message into existing session        │
│  └─ Agent responds to original channel          │
├─────────────────────────────────────────────────┤
│  agent_turn mode                                │
│  └─ Create isolated session                     │
│  └─ Execute with AI                             │
│  └─ Deliver results to target channel           │
│  └─ Auto cleanup                                │
└─────────────────────────────────────────────────┘
```

### 🔧 CLI Tools
```bash
./clawd_ex status          # Application overview
./clawd_ex health -v       # 7-point health check
./clawd_ex configure       # Interactive setup wizard
```

### 🏥 Health Monitoring
Real-time monitoring of 7 subsystems:
- Database (connection, latency, size)
- Memory (total, processes, system)
- Process count and limits
- AI Provider status
- Browser availability
- Filesystem access
- Network connectivity

---

## 🚀 Quick Start

### Prerequisites
- Elixir 1.15+ / Erlang/OTP 26+
- PostgreSQL 14+ with pgvector
- Chrome/Chromium (optional, for browser tool)

### Installation

```bash
# Clone
git clone https://github.com/dyzdyz010/clawd_ex.git
cd clawd_ex

# Setup
mix deps.get
mix ecto.setup

# Configure AI provider (at least one)
export ANTHROPIC_API_KEY="sk-..."
# or
export OPENAI_API_KEY="sk-..."

# Run
iex -S mix phx.server
```

Open http://localhost:4000 🎉

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix Gateway                          │
├─────────────────────────────────────────────────────────────┤
│  Channels     │ Telegram │ Discord │ WebChat (LiveView)    │
├─────────────────────────────────────────────────────────────┤
│  LiveView     │ Dashboard │ Chat │ Sessions │ Agents │ ... │
├─────────────────────────────────────────────────────────────┤
│  Session Layer (DynamicSupervisor)                          │
│  └── SessionWorker (GenServer) - Async message handling     │
│  └── Compaction - AI-powered summarization                  │
├─────────────────────────────────────────────────────────────┤
│  Agent Loop (GenStateMachine)                               │
│  └── idle → preparing → inferring → executing_tools         │
│  └── Tool iterations limit: 50/run                          │
├─────────────────────────────────────────────────────────────┤
│  Tools System (21+ tools)                                   │
│  └── File │ Exec │ Web │ Browser │ Memory │ Sessions │ ...  │
├─────────────────────────────────────────────────────────────┤
│  AI Providers │ Anthropic │ OpenAI │ Gemini │ OpenRouter    │
│  └── OAuth token management │ Auto-retry (3x exponential)   │
├─────────────────────────────────────────────────────────────┤
│  Memory │ pgvector (HNSW) + BM25 Hybrid Search              │
├─────────────────────────────────────────────────────────────┤
│  Browser │ Chrome DevTools Protocol (CDP)                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 📦 Tool System

| Category | Tools | Description |
|----------|-------|-------------|
| **File** | `read`, `write`, `edit` | File operations |
| **Exec** | `exec`, `process` | Shell commands, process management |
| **Memory** | `memory_search`, `memory_get` | Semantic search & retrieval |
| **Web** | `web_search`, `web_fetch` | Brave search, content extraction |
| **Browser** | `browser` | CDP automation (navigate, click, type, screenshot) |
| **Sessions** | `sessions_*` | List, history, send, spawn subagents |
| **Automation** | `cron`, `gateway`, `message` | Scheduling, self-management, multi-channel |
| **Nodes** | `nodes` | Remote device control |
| **Canvas** | `canvas` | A2UI display |

---

## 🧩 Skills System

ClawdEx extends agent capabilities through a powerful Skills system. Skills are text-based instruction files that get injected into agent contexts when their requirements are met.

### Key Features

- **49 Built-in Skills** - GitHub, Docker, file operations, web tools, and more
- **Hot Reloadable** - Changes take effect via `Skills.Registry.refresh()`
- **Dependency Aware** - Only loads when system requirements are satisfied
- **Hierarchical Priority** - Workspace > managed > bundled skill precedence

### Directory Structure

```
priv/skills/          → bundled (built-in, lowest priority)
~/.clawd/skills/      → managed (user-installed, medium priority) 
<workspace>/skills/   → workspace (project-specific, highest priority)
```

### Creating Custom Skills

1. **Create skill directory**: `mkdir <workspace>/skills/my-skill`
2. **Write SKILL.md** with YAML frontmatter and markdown instructions
3. **Hot reload**: `Skills.Registry.refresh()`

Example `SKILL.md`:
```yaml
---
name: my-tool
description: "Tool description and usage guidelines."
metadata:
  clawd_ex:
    emoji: "🔧"
    requires:
      bins: ["required-binary"]
      env: ["API_KEY"]
---

# My Tool Skill
Instructions for using this tool...
```

See **[docs/skills.md](docs/skills.md)** for complete documentation.

---

## 🔐 OAuth Support

Compatible with Claude Code CLI credentials:

```elixir
# Auto-load from Claude CLI
ClawdEx.AI.OAuth.load_from_claude_cli()

# Or manual storage
ClawdEx.AI.OAuth.store_credentials(:anthropic, %{
  access: "sk-ant-oat-...",
  refresh: "...",
  expires: 1234567890
})
```

---

## 📈 Project Status

| Metric | Value |
|--------|-------|
| **Completion** | ~42% (76/181 features) |
| **Tests** | 392 passing |
| **LiveView Pages** | 8 |
| **CLI Commands** | 3 |
| **Tools** | 22/24 |
| **Channels** | 3 (Telegram, Discord, WebChat) |

### Roadmap

- [x] **P0** - Core Experience (CLI, Health, Cron UI, Logs, Settings)
- [ ] **P1** - TUI, WhatsApp/Signal, Sandbox mode
- [ ] **P2** - More AI providers, Plugin system, Skills

---

## 🤝 Contributing

Contributions welcome! Please read our contributing guidelines.

```bash
# Run tests
mix test

# Format code
mix format

# Check types
mix dialyzer
```

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

---

## 🙏 Acknowledgments

- Inspired by [OpenClaw](https://github.com/openclaw/openclaw)
- Built with [Phoenix Framework](https://www.phoenixframework.org/)
- AI powered by [Anthropic Claude](https://anthropic.com/)

---

<p align="center">
  <b>Built with ❤️ and Elixir</b>
</p>
