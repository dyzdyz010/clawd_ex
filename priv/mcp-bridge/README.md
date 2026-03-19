# ClawdEx MCP Bridge

A generic adapter that loads any OpenClaw plugin and exposes its registered tools as an [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) server over stdio.

## Overview

OpenClaw plugins are JavaScript/TypeScript modules that register tools via `register(api)`. This bridge:

1. Loads a plugin module
2. Provides a mock OpenClaw API to capture tool registrations
3. Starts an MCP server on stdio (JSON-RPC 2.0, one message per line)
4. Routes `tools/list` and `tools/call` to the captured tools

## Usage

```bash
node bridge.js --plugin <path-or-npm-spec> [--config <json-path>] [--extensions-dir <dir>]
```

### Arguments

| Flag | Required | Description |
|------|----------|-------------|
| `--plugin` | Yes | Plugin path or npm specifier. Can be absolute, relative, or a bare name resolved from `--extensions-dir`. |
| `--config` | No | Path to a JSON config file. Passed to the plugin as `config` and `pluginConfig`. |
| `--extensions-dir` | No | Directory to search for plugins by name. Defaults to `~/.openclaw/extensions`. |

### Examples

```bash
# Load a local plugin by path
node bridge.js --plugin ./my-plugin.js

# Load from OpenClaw extensions directory
node bridge.js --plugin feishu-openclaw-plugin

# Load with config
node bridge.js --plugin ~/.openclaw/extensions/feishu-openclaw-plugin \
  --config ./feishu-config.json
```

## MCP Protocol

The bridge communicates via stdio using JSON-RPC 2.0 (one JSON object per line).

### Supported Methods

| Method | Description |
|--------|-------------|
| `initialize` | Returns server capabilities and info |
| `notifications/initialized` | Acknowledged (no response) |
| `tools/list` | Returns all registered tools with schemas |
| `tools/call` | Executes a tool and returns results |

### Message Flow

```
→ Client: {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
← Server: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",...}}

→ Client: {"jsonrpc":"2.0","method":"notifications/initialized"}

→ Client: {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← Server: {"jsonrpc":"2.0","id":2,"result":{"tools":[...]}}

→ Client: {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}
← Server: {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hi"}]}}
```

## Architecture

```
┌─────────────┐    stdio     ┌──────────────┐    register(api)    ┌──────────────┐
│  ClawdEx     │◄───────────►│  MCP Bridge   │◄──────────────────►│  OC Plugin    │
│  (Elixir)    │  JSON-RPC   │  (Node.js)    │   fake API         │  (JS/TS)      │
└─────────────┘              └──────────────┘                     └──────────────┘
```

The bridge creates a "fake" OpenClaw Plugin API that only cares about `registerTool()`. All other registration methods (`registerChannel`, `registerProvider`, etc.) are no-ops. When a plugin calls `api.registerTool(toolDef)`, the bridge captures the tool definition and makes it available via MCP.

## Config File Format

The config JSON is loaded and passed to the plugin. The bridge looks for `config` and `pluginConfig` keys:

```json
{
  "config": { "someGlobalSetting": true },
  "pluginConfig": { "apiKey": "...", "tenantId": "..." }
}
```

If neither key exists, the entire JSON object is used as both `config` and `pluginConfig`.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CLAWD_WORKSPACE` | Override workspace directory (default: `~/.openclaw/workspace`) |
| `CLAWD_AGENT_DIR` | Override agent directory (default: `~/.openclaw`) |

## Testing

```bash
bash test-bridge.sh
```

This runs the bridge with a test plugin (`test-plugin.js`) and validates responses for:
- Server initialization
- Tool listing
- Tool execution (echo, add)
- Error handling (failing tool, missing tool, unknown method)

## No External Dependencies

The bridge uses only Node.js built-in modules (`readline`, `path`, `fs`, `os`, `url`). Plugins may have their own `node_modules` — ensure they are installed in the plugin directory before running.

## Integration with ClawdEx

ClawdEx (Elixir) starts the bridge as a child process via `Port.open/2`:

```elixir
port = Port.open(
  {:spawn_executable, node_path},
  [:binary, :exit_status, {:args, ["bridge.js", "--plugin", plugin_path]},
   {:cd, bridge_dir}]
)
```

Messages are exchanged line-by-line over the port's stdin/stdout.
