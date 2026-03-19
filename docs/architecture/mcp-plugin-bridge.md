# MCP Client + Plugin Bridge Architecture

> **Status:** Design Draft  
> **Author:** Architect Agent  
> **Date:** 2026-03-19  
> **Depends on:** Tools.Registry, Plugins.Manager, Application supervision tree

---

## 1. Overview

ClawdEx needs to support external tools provided by MCP (Model Context Protocol) servers — both standalone MCP servers and OpenClaw-format plugins wrapped via a Node.js bridge. This document defines the architecture for:

1. **MCP Client** — generic, protocol-level MCP integration (stdio + SSE transports)
2. **Plugin Bridge** — a Node.js process that wraps OpenClaw plugins as MCP servers
3. **Tool integration** — dynamic registration of MCP-sourced tools into the existing `Tools.Registry`

### Design Principles

- **Single source of truth:** All MCP server configuration lives in one place (`~/.clawd/mcp_servers.json`), loaded at startup, hot-reloadable at runtime.
- **High-level abstraction:** The MCP Client is generic — it speaks MCP protocol and knows nothing about specific plugins.
- **Dynamic registration:** Tools from MCP servers are registered at runtime. No compile-time changes needed.

---

## 2. Architecture Diagram

```
Agent Loop
  │
  ▼
Tools.Registry ─────────────────────────────────────────────┐
  │                                                          │
  ├── [built-in tools]  (compile-time @tool_modules)         │
  │     Read, Write, Exec, WebSearch, ...                    │
  │                                                          │
  ├── [plugin tools]    (runtime, via Plugins.Manager)       │
  │     Elixir plugins implementing Tool behaviour           │
  │                                                          │
  └── [MCP tools]       (runtime, via MCP.ToolProxy)  ◄──────┘
        feishu_doc, feishu_bitable, custom_tool, ...

MCP.Supervisor (one_for_one)
  ├── MCP.ServerManager (DynamicSupervisor)
  │     ├── MCP.Connection "feishu"    (GenServer, stdio transport)
  │     ├── MCP.Connection "github"    (GenServer, SSE transport)
  │     └── MCP.Connection "custom"    (GenServer, stdio transport)
  │
  └── MCP.ToolProxy (GenServer)
        • Aggregates tools from all active connections
        • Converts to ClawdEx tool_spec format
        • Routes tool calls to correct connection
```

---

## 3. Module Design

### 3.1 `ClawdEx.MCP.Protocol` — Pure Functions

**Purpose:** JSON-RPC 2.0 encoding/decoding and MCP message type definitions.

**Key principle:** No state. No GenServer. Pure functions only.

```elixir
defmodule ClawdEx.MCP.Protocol do
  @moduledoc """
  MCP Protocol — JSON-RPC 2.0 encoding/decoding for MCP communication.
  Pure functions, no state.
  """

  # ── Types ──────────────────────────────────────────────────────────────

  @type json_rpc_request :: %{
          jsonrpc: String.t(),
          id: integer(),
          method: String.t(),
          params: map()
        }

  @type json_rpc_response :: %{
          jsonrpc: String.t(),
          id: integer(),
          result: map() | nil,
          error: json_rpc_error() | nil
        }

  @type json_rpc_notification :: %{
          jsonrpc: String.t(),
          method: String.t(),
          params: map()
        }

  @type json_rpc_error :: %{
          code: integer(),
          message: String.t(),
          data: any()
        }

  @type mcp_tool_definition :: %{
          name: String.t(),
          description: String.t(),
          inputSchema: map()
        }

  @type mcp_tool_result :: %{
          content: [%{type: String.t(), text: String.t()}],
          isError: boolean()
        }

  # ── Encoding ───────────────────────────────────────────────────────────

  @spec encode_request(integer(), String.t(), map()) :: binary()
  def encode_request(id, method, params \\ %{})

  @spec encode_notification(String.t(), map()) :: binary()
  def encode_notification(method, params \\ %{})

  @spec encode_response(integer(), map()) :: binary()
  def encode_response(id, result)

  # ── Decoding ───────────────────────────────────────────────────────────

  @spec decode(binary()) ::
          {:request, json_rpc_request()}
          | {:response, json_rpc_response()}
          | {:notification, json_rpc_notification()}
          | {:error, term()}
  def decode(data)

  # ── MCP Message Builders ───────────────────────────────────────────────

  @spec initialize_request(integer(), map()) :: binary()
  def initialize_request(id, client_info \\ %{})
  # → method: "initialize", params: %{protocolVersion: "2024-11-05", capabilities: ..., clientInfo: ...}

  @spec initialized_notification() :: binary()
  def initialized_notification()
  # → method: "notifications/initialized"

  @spec tools_list_request(integer()) :: binary()
  def tools_list_request(id)
  # → method: "tools/list"

  @spec tools_call_request(integer(), String.t(), map()) :: binary()
  def tools_call_request(id, tool_name, arguments)
  # → method: "tools/call", params: %{name: tool_name, arguments: arguments}

  @spec ping_request(integer()) :: binary()
  def ping_request(id)
  # → method: "ping"
end
```

**MCP methods supported (Phase 1):**

| Method | Direction | Purpose |
|--------|-----------|---------|
| `initialize` | Client → Server | Handshake, capability negotiation |
| `notifications/initialized` | Client → Server | Handshake complete signal |
| `tools/list` | Client → Server | Discover available tools |
| `tools/call` | Client → Server | Execute a tool |
| `ping` | Client → Server | Health check |
| `notifications/tools/list_changed` | Server → Client | Tool list was updated |

---

### 3.2 `ClawdEx.MCP.Connection` — Per-Server GenServer

**Purpose:** Manages the lifecycle of a single MCP server connection.

**One instance per MCP server.** Handles transport (stdio Port or HTTP/SSE), protocol handshake, tool discovery, tool execution, and reconnection.

```elixir
defmodule ClawdEx.MCP.Connection do
  @moduledoc """
  MCP Connection — GenServer managing a single MCP server.
  One process per configured server. Handles stdio or SSE transport.
  """
  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────

  @type transport :: :stdio | :sse

  @type state :: %{
          server_id: String.t(),
          config: server_config(),
          transport: transport(),
          status: :connecting | :ready | :error | :stopped,
          port: port() | nil,
          request_id: integer(),
          pending_requests: %{integer() => {pid(), reference()}},
          tools: [Protocol.mcp_tool_definition()],
          buffer: binary(),
          retry_count: integer(),
          last_error: term() | nil
        }

  # ── Client API ─────────────────────────────────────────────────────────

  @doc "Start a connection for the given server config"
  @spec start_link(server_config()) :: GenServer.on_start()
  def start_link(config)

  @doc "Get current status"
  @spec status(GenServer.server()) :: state()
  def status(server)

  @doc "List tools discovered from this server"
  @spec list_tools(GenServer.server()) :: {:ok, [Protocol.mcp_tool_definition()]} | {:error, term()}
  def list_tools(server)

  @doc "Call a tool on this server"
  @spec call_tool(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, Protocol.mcp_tool_result()} | {:error, term()}
  def call_tool(server, tool_name, arguments, timeout \\ 30_000)

  @doc "Gracefully stop the connection"
  @spec stop(GenServer.server()) :: :ok
  def stop(server)

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(config)
  # 1. Determine transport from config (stdio if command present, sse if url present)
  # 2. Open stdio Port or start HTTP client
  # 3. Send initialize request
  # 4. Schedule timeout for handshake

  @impl true
  def handle_info({port, {:data, data}}, state)
  # stdio data handler:
  # 1. Append to buffer
  # 2. Try to extract complete JSON-RPC messages (newline-delimited)
  # 3. Dispatch each message

  @impl true
  def handle_info(:reconnect, state)
  # Exponential backoff reconnection

  @impl true
  def handle_call({:call_tool, name, args, timeout}, from, state)
  # 1. Generate request ID
  # 2. Encode tools/call request
  # 3. Send via transport
  # 4. Store in pending_requests with caller ref
  # 5. Schedule timeout

  # ── Internal ───────────────────────────────────────────────────────────

  # State machine transitions:
  #   :connecting  →  :ready     (on successful initialize response)
  #   :connecting  →  :error     (on timeout or error)
  #   :ready       →  :error     (on port crash or protocol error)
  #   :error       →  :connecting (on reconnect attempt)
  #   any          →  :stopped    (on explicit stop)
end
```

**Stdio transport details:**
- Uses Erlang Port with `[:binary, :exit_status, {:line, 1_048_576}]`
- Messages are newline-delimited JSON
- Port environment variables set from `config.env`
- Working directory set from `config.cwd` (defaults to home dir)

**SSE transport details (Phase 2):**
- HTTP GET to server URL with `Accept: text/event-stream`
- Server-Sent Events parsed for JSON-RPC messages
- POST for sending requests
- Automatic reconnection on disconnect

**Process naming:**
```elixir
{:via, Registry, {ClawdEx.MCP.ConnectionRegistry, server_id}}
```

---

### 3.3 `ClawdEx.MCP.ServerManager` — DynamicSupervisor

**Purpose:** Manages the lifecycle of all MCP Connection processes. Starts/stops connections based on configuration.

```elixir
defmodule ClawdEx.MCP.ServerManager do
  @moduledoc """
  MCP Server Manager — DynamicSupervisor for MCP Connection processes.
  Reads config, starts enabled servers, supports hot add/remove.
  """
  use DynamicSupervisor

  require Logger

  # ── Client API ─────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ [])

  @doc "List all managed servers with their status"
  @spec list_servers() :: [%{id: String.t(), status: atom(), tool_count: integer()}]
  def list_servers()

  @doc "Get a specific server's connection process"
  @spec get_connection(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_connection(server_id)

  @doc "Add and start a new MCP server at runtime"
  @spec add_server(server_config()) :: {:ok, pid()} | {:error, term()}
  def add_server(config)

  @doc "Remove and stop an MCP server"
  @spec remove_server(String.t()) :: :ok | {:error, :not_found}
  def remove_server(server_id)

  @doc "Reload all servers from config file"
  @spec reload() :: :ok
  def reload()

  # ── DynamicSupervisor Callbacks ────────────────────────────────────────

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  # ── Internal ───────────────────────────────────────────────────────────

  # Config loading order:
  # 1. Read ~/.clawd/mcp_servers.json (single source of truth)
  # 2. Filter to enabled: true only
  # 3. Start a Connection child for each
  #
  # Hot reload:
  # 1. Read new config
  # 2. Diff against running servers
  # 3. Stop removed, start added, restart changed
  # 4. Notify ToolProxy to refresh
end
```

---

### 3.4 `ClawdEx.MCP.ToolProxy` — Dynamic Tool Bridge

**Purpose:** The critical integration point. Aggregates tools from all MCP connections, converts them to ClawdEx format, and routes tool calls.

```elixir
defmodule ClawdEx.MCP.ToolProxy do
  @moduledoc """
  MCP Tool Proxy — bridges MCP tools into the ClawdEx tool system.

  Aggregates tools from all active MCP connections, converts to ClawdEx
  tool_spec format, and routes tool execution to the correct connection.
  """
  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────

  @type mcp_tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          server_id: String.t()
        }

  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type state :: %{
          tools: %{String.t() => mcp_tool()},
          refresh_timer: reference() | nil
        }

  # ── Client API ─────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ [])

  @doc "Get all MCP tools as ClawdEx tool_specs"
  @spec list_tools() :: [tool_spec()]
  def list_tools()

  @doc "Execute an MCP tool by name"
  @spec execute(String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute(tool_name, params, context)

  @doc "Check if a tool name is an MCP tool"
  @spec mcp_tool?(String.t()) :: boolean()
  def mcp_tool?(tool_name)

  @doc "Force refresh tool list from all connections"
  @spec refresh() :: :ok
  def refresh()

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts)
  # 1. Subscribe to connection status changes via PubSub
  # 2. Schedule initial tool discovery (after connections are ready)

  @impl true
  def handle_info(:refresh_tools, state)
  # 1. Get all active connections from ServerManager
  # 2. For each: call Connection.list_tools/1
  # 3. Namespace tools: "server_id:tool_name" → or use server prefix
  # 4. Store aggregated tool map

  @impl true
  def handle_info({:connection_ready, server_id}, state)
  # A new connection became ready → refresh its tools

  @impl true
  def handle_info({:connection_down, server_id}, state)
  # A connection went down → remove its tools from the map

  @impl true
  def handle_call({:execute, tool_name, params, context}, _from, state)
  # 1. Look up tool_name in tools map → get server_id
  # 2. Get connection pid from ServerManager
  # 3. Call Connection.call_tool/4
  # 4. Convert MCP result to ClawdEx format

  # ── Tool Name Strategy ─────────────────────────────────────────────────

  # MCP tools are namespaced to avoid collisions with built-in tools.
  # Strategy: use the MCP tool name directly if unique across all servers.
  # If collision: prefix with "server_id." (e.g., "feishu.doc_read").
  #
  # The proxy maintains a collision map and handles resolution transparently.
  # From the agent's perspective, tools have clean names.
end
```

**Tool name resolution strategy:**

1. Collect tools from all servers
2. If a tool name is globally unique → use as-is (e.g., `feishu_doc`)
3. If two servers expose the same name → prefix with server_id (e.g., `feishu.read`, `github.read`)
4. Built-in tools always win — if an MCP tool collides with a built-in, prefix it

---

### 3.5 `ClawdEx.MCP.Supervisor` — Top-Level Supervisor

```elixir
defmodule ClawdEx.MCP.Supervisor do
  @moduledoc """
  Top-level supervisor for the MCP subsystem.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Connection process registry
      {Registry, keys: :unique, name: ClawdEx.MCP.ConnectionRegistry},
      # Connection lifecycle manager
      ClawdEx.MCP.ServerManager,
      # Tool aggregation and routing
      ClawdEx.MCP.ToolProxy
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

---

## 4. Configuration — Single Source of Truth

### 4.1 Config File: `~/.clawd/mcp_servers.json`

This is the **only** place MCP server configuration lives. Not in `config.exs`, not in the database, not scattered across files.

```json
{
  "servers": [
    {
      "id": "feishu",
      "command": "node",
      "args": ["~/.clawd/bridge/mcp-bridge.js", "--plugin", "@larksuiteoapi/feishu-openclaw-plugin"],
      "env": {
        "FEISHU_APP_ID": "cli_xxx",
        "FEISHU_APP_SECRET": "xxx"
      },
      "enabled": true
    },
    {
      "id": "github",
      "url": "http://localhost:3100/sse",
      "enabled": true
    },
    {
      "id": "custom-tool",
      "command": "uvx",
      "args": ["some-mcp-server"],
      "env": {},
      "enabled": false
    }
  ]
}
```

### 4.2 Elixir Types

```elixir
@type server_config :: %{
  id: String.t(),
  # stdio transport
  command: String.t() | nil,
  args: [String.t()],
  env: %{String.t() => String.t()},
  cwd: String.t() | nil,
  # SSE transport (alternative to command)
  url: String.t() | nil,
  # Common
  enabled: boolean(),
  # Optional metadata
  description: String.t() | nil,
  timeout_ms: pos_integer() | nil       # default: 30_000
}
```

**Transport detection rule:**
- If `command` is present → stdio transport
- If `url` is present → SSE transport
- Both present → error at validation time

### 4.3 Config Loading

```elixir
defmodule ClawdEx.MCP.Config do
  @moduledoc """
  Loads and validates MCP server configuration from ~/.clawd/mcp_servers.json.
  """

  @config_path "~/.clawd/mcp_servers.json"

  @spec load() :: {:ok, [server_config()]} | {:error, term()}
  def load()
  # 1. Expand ~ in path
  # 2. Read and decode JSON
  # 3. Validate each entry
  # 4. Filter enabled: true

  @spec validate(map()) :: {:ok, server_config()} | {:error, term()}
  def validate(raw)
  # - id: required, non-empty string
  # - command or url: exactly one must be present
  # - args: list of strings (default [])
  # - env: map of string → string (default %{})
  # - enabled: boolean (default true)

  @spec config_path() :: String.t()
  def config_path()

  @spec write(server_config()) :: :ok | {:error, term()}
  def write(config)
  # Read existing, merge/replace by id, write back

  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(server_id)
  # Read existing, remove by id, write back
end
```

### 4.4 Application Config Integration

The application config (`config.exs`) can **optionally** set a default config path or inline servers for development:

```elixir
# config/config.exs — optional override
config :clawd_ex, :mcp,
  config_path: "~/.clawd/mcp_servers.json",   # default
  auto_start: true                              # start servers on boot
```

But the **servers themselves** are always in the JSON file. The Elixir config only controls meta-behavior.

---

## 5. Tools.Registry Integration

### 5.1 Current State

The existing `ClawdEx.Tools.Registry` has:

- **Compile-time:** `@tool_modules` list → `@tools` map (name → module)
- **Runtime:** `find_plugin_tool/1` fallback to `Plugins.Manager.get_tools()`
- **Execute:** looks up `@tools` (built-in) → then tries `find_plugin_tool` (plugins)

### 5.2 Required Changes

**File:** `lib/clawd_ex/tools/registry.ex`

The changes are minimal — add MCP as a third tool source in the lookup chain:

```elixir
# ── In list_tools/1 ──────────────────────────────────────────────────

def list_tools(opts \\ []) do
  allowed = Keyword.get(opts, :allow, ["*"])
  denied = Keyword.get(opts, :deny, [])

  builtin = ...  # unchanged

  plugin_tools = ...  # unchanged

  # NEW: MCP tools
  mcp_tools =
    try do
      ClawdEx.MCP.ToolProxy.list_tools()
      |> Enum.filter(&tool_allowed?(&1.name, allowed, denied))
    rescue
      _ -> []
    end

  builtin ++ plugin_tools ++ mcp_tools
end
```

```elixir
# ── In execute/3 ─────────────────────────────────────────────────────

def execute(tool_name, params, context) do
  canonical = resolve_tool_name(tool_name)
  module = Map.get(@tools, canonical) || find_plugin_tool(canonical)

  case module do
    nil ->
      # NEW: Try MCP tools as final fallback
      if ClawdEx.MCP.ToolProxy.mcp_tool?(canonical) do
        case ClawdEx.Security.ToolGuard.check_permission(canonical, params, context) do
          :ok -> ClawdEx.MCP.ToolProxy.execute(canonical, params, context)
          {:error, reason} -> {:error, reason}
        end
      else
        Logger.warning("Tool not found: #{tool_name}")
        {:error, :tool_not_found}
      end

    mod ->
      # ... existing code unchanged ...
  end
end
```

**Lookup priority (unchanged principle, extended):**
1. Built-in tools (`@tools` compile-time map)
2. Plugin tools (runtime, via `Plugins.Manager`)
3. MCP tools (runtime, via `MCP.ToolProxy`) ← **NEW**

---

## 6. Existing Code — Required Changes

### 6.1 `lib/clawd_ex/tools/registry.ex`

| Section | Change | Effort |
|---------|--------|--------|
| `list_tools/1` | Add MCP tools from `ToolProxy.list_tools()` as third source | Small |
| `execute/3` | Add MCP fallback after plugin tool lookup | Small |
| `resolve_tool_name/1` | No change needed — MCP tools use their own names | None |
| `get_tool_spec/1` | Optional: add MCP tool lookup for completeness | Small |

**Risk:** Low. Only adds fallback paths, never modifies existing built-in or plugin behavior.

### 6.2 `lib/clawd_ex/plugins/manager.ex`

| Section | Change | Effort |
|---------|--------|--------|
| No direct changes needed | MCP is a parallel system, not layered on top of Plugins.Manager | None |

**Rationale:** The existing `Plugins.Manager` handles Elixir-native plugins. MCP servers are a separate concept — they communicate via protocol, not Elixir modules. The two systems are peers under `Tools.Registry`, not parent-child.

**Future consideration:** When a user runs `clawd_ex plugins install <npm-spec>`, the CLI writes to `mcp_servers.json` and notifies `MCP.ServerManager`. `Plugins.Manager` is not involved in this flow.

### 6.3 `lib/clawd_ex/application.ex`

| Section | Change | Effort |
|---------|--------|--------|
| `children` list | Add `ClawdEx.MCP.Supervisor` | Small |

Insert after `ClawdEx.Plugins.Supervisor`:

```elixir
children = [
  ...
  # Plugins subsystem (Manager)
  ClawdEx.Plugins.Supervisor,
  # MCP subsystem (ServerManager + ToolProxy)    ← NEW
  ClawdEx.MCP.Supervisor,
  ...
]
```

**Ordering matters:** MCP.Supervisor starts after Plugins.Supervisor but before SessionManager and channels. This ensures MCP tools are available before any agent sessions start.

### 6.4 `lib/clawd_ex/agent/loop/tool_executor.ex`

| Section | Change | Effort |
|---------|--------|--------|
| `execute_tool/2` | No change needed — delegates to `Registry.execute/3` | None |
| `load_tools/1` | No change needed — delegates to `Registry.list_tools/1` | None |

**Why no changes:** The ToolExecutor already delegates everything to `Tools.Registry`. Since Registry handles the MCP integration, ToolExecutor is transparent to the change.

### 6.5 `lib/clawd_ex/security/tool_guard.ex`

| Section | Change | Effort |
|---------|--------|--------|
| `check_permission/3` | Works as-is for MCP tools | None |
| `check_command_blocklist/2` | Only applies to `"exec"` tool — N/A for MCP | None |

**MCP-specific security (future):** May want to add a `check_mcp_tool/2` that validates which MCP tools are allowed per-agent. For now, the existing allow/deny lists in agent config cover this.

---

## 7. Node.js Bridge

### 7.1 Purpose

The Bridge is a Node.js process that:
1. Loads an OpenClaw-format plugin (npm package)
2. Mocks the OpenClaw plugin registration API
3. Exposes the plugin's tools as an MCP server over stdio

From ClawdEx's perspective, the Bridge is just another MCP server. The Bridge's internals are opaque.

### 7.2 Protocol

```
ClawdEx (MCP Client)  ←── stdio (JSON-RPC 2.0) ──→  mcp-bridge.js (MCP Server)
                                                           │
                                                           ▼
                                                     OpenClaw Plugin
                                                     (npm package)
```

### 7.3 Bridge CLI Interface

```bash
# Start bridge for a specific plugin
node ~/.clawd/bridge/mcp-bridge.js \
  --plugin @larksuiteoapi/feishu-openclaw-plugin \
  --config ~/.clawd/extensions/feishu-openclaw-plugin/config.json

# Optional flags
  --plugin <npm-spec-or-path>    # Required: plugin to load
  --config <path>                # Optional: plugin-specific config
  --verbose                      # Optional: debug logging to stderr
```

### 7.4 Bridge Behavior

**Startup sequence:**
1. Load the plugin module
2. Mock `registerTool()` — collect all tool registrations
3. Mock `registerSkill()` — collect skill metadata (if relevant)
4. Wait for `initialize` request from ClawdEx
5. Respond with server capabilities

**Tool discovery (`tools/list`):**
- Return all tools collected from the plugin's `registerTool()` calls
- Map OpenClaw tool format to MCP tool format:

```javascript
// OpenClaw format (input)
{
  name: "feishu_doc",
  description: "Read/write Feishu documents",
  parameters: {
    type: "object",
    properties: { ... },
    required: [...]
  },
  execute: async (params, context) => { ... }
}

// MCP format (output)
{
  name: "feishu_doc",
  description: "Read/write Feishu documents",
  inputSchema: {
    type: "object",
    properties: { ... },
    required: [...]
  }
}
```

**Tool execution (`tools/call`):**
- Route to the plugin's original `execute` function
- Convert result to MCP content format:

```javascript
// Success
{ content: [{ type: "text", text: JSON.stringify(result) }], isError: false }

// Error
{ content: [{ type: "text", text: error.message }], isError: true }
```

### 7.5 Bridge File Location

```
~/.clawd/
  bridge/
    mcp-bridge.js          # The bridge runtime
    package.json           # Bridge dependencies
    node_modules/          # Bridge's own deps
  extensions/
    feishu-openclaw-plugin/  # Installed plugin
      node_modules/
      package.json
    another-plugin/
      ...
```

---

## 8. Plugin Installation Flow

### 8.1 CLI Command

```bash
clawd_ex plugins install @larksuiteoapi/feishu-openclaw-plugin
```

### 8.2 Steps

```
1. Resolve npm spec
   └── npm install @larksuiteoapi/feishu-openclaw-plugin
       → installed to ~/.clawd/extensions/feishu-openclaw-plugin/

2. Read plugin metadata
   └── Parse package.json and/or openclaw.plugin.json
       → Extract: name, version, description, tool count

3. Update config (single source of truth)
   └── Read ~/.clawd/mcp_servers.json
       Append or update entry:
       {
         "id": "feishu-openclaw-plugin",
         "command": "node",
         "args": ["~/.clawd/bridge/mcp-bridge.js", "--plugin", "~/.clawd/extensions/feishu-openclaw-plugin"],
         "env": {},
         "enabled": true
       }
       Write back to ~/.clawd/mcp_servers.json

4. Hot reload (if running)
   └── Notify MCP.ServerManager.reload()
       → Diffs config, starts new Connection
       → ToolProxy picks up new tools

5. Verify
   └── List tools from the new server
       → Print discovered tools to CLI output
```

### 8.3 Plugin Uninstall

```bash
clawd_ex plugins uninstall feishu-openclaw-plugin
```

Steps:
1. Remove from `~/.clawd/mcp_servers.json`
2. `MCP.ServerManager.remove_server("feishu-openclaw-plugin")`
3. `rm -rf ~/.clawd/extensions/feishu-openclaw-plugin/`

### 8.4 Plugin List

```bash
clawd_ex plugins list
```

Reads `mcp_servers.json`, shows:
- Server ID
- Enabled/disabled
- Status (connected/disconnected)
- Tool count

---

## 9. Key Elixir Types and Interfaces

### 9.1 Server Config

```elixir
@type server_config :: %{
  required(:id) => String.t(),
  optional(:command) => String.t(),
  optional(:args) => [String.t()],
  optional(:env) => %{String.t() => String.t()},
  optional(:cwd) => String.t(),
  optional(:url) => String.t(),
  optional(:enabled) => boolean(),
  optional(:description) => String.t(),
  optional(:timeout_ms) => pos_integer()
}
```

### 9.2 MCP Tool (internal representation)

```elixir
@type mcp_tool :: %{
  name: String.t(),
  description: String.t(),
  input_schema: map(),
  server_id: String.t()
}
```

### 9.3 Tool Spec (ClawdEx-compatible, for Registry)

```elixir
@type tool_spec :: %{
  name: String.t(),
  description: String.t(),
  parameters: map()
}
```

### 9.4 Connection Status

```elixir
@type connection_status :: %{
  server_id: String.t(),
  status: :connecting | :ready | :error | :stopped,
  transport: :stdio | :sse,
  tool_count: non_neg_integer(),
  uptime_ms: non_neg_integer() | nil,
  last_error: String.t() | nil
}
```

### 9.5 Tool Execution Result (from MCP)

```elixir
@type mcp_content :: %{
  type: String.t(),     # "text" | "image" | "resource"
  text: String.t() | nil,
  data: String.t() | nil,
  mimeType: String.t() | nil
}

@type mcp_tool_result :: %{
  content: [mcp_content()],
  isError: boolean()
}
```

---

## 10. PubSub Events

MCP subsystem communicates state changes via `Phoenix.PubSub`:

| Topic | Event | Payload |
|-------|-------|---------|
| `"mcp:connections"` | `:connection_ready` | `%{server_id: String.t()}` |
| `"mcp:connections"` | `:connection_down` | `%{server_id: String.t(), reason: term()}` |
| `"mcp:connections"` | `:connection_error` | `%{server_id: String.t(), error: term()}` |
| `"mcp:tools"` | `:tools_changed` | `%{server_id: String.t(), added: [String.t()], removed: [String.t()]}` |
| `"mcp:tools"` | `:tools_refreshed` | `%{total_count: integer()}` |

**ToolProxy subscribes to** `"mcp:connections"` to auto-refresh when connections come up/down.

---

## 11. Error Handling

### 11.1 Connection Failures

- **Server won't start:** Log error, set status to `:error`, retry with exponential backoff (1s, 2s, 4s, 8s, max 60s)
- **Handshake timeout:** 10s default. On timeout → close port, retry
- **Port crash (exit_status != 0):** Capture exit code, log, retry
- **Protocol error:** Log malformed message, continue (don't crash connection)

### 11.2 Tool Call Failures

- **Timeout:** Default 30s per tool call. Return `{:error, :timeout}`
- **Server error (JSON-RPC error):** Convert to `{:error, {:mcp_error, code, message}}`
- **Connection not ready:** Return `{:error, :server_not_ready}`
- **Connection down mid-call:** Return `{:error, :connection_lost}`

### 11.3 Config Failures

- **Config file missing:** Start with empty server list, log info
- **Config file malformed:** Log error, start with empty server list
- **Individual server config invalid:** Skip that server, log warning, start others

---

## 12. Implementation Plan

### Phase 1: Core MCP Client (Week 1)

1. `ClawdEx.MCP.Protocol` — JSON-RPC 2.0 encoding/decoding
2. `ClawdEx.MCP.Connection` — stdio transport only
3. `ClawdEx.MCP.Config` — JSON config file loading
4. `ClawdEx.MCP.ServerManager` — basic start/stop
5. `ClawdEx.MCP.ToolProxy` — tool aggregation + execution routing
6. `ClawdEx.MCP.Supervisor` — wire it all together
7. Integration: `Tools.Registry` changes
8. Integration: `Application` supervision tree

### Phase 2: Node.js Bridge (Week 2)

1. `mcp-bridge.js` — OpenClaw plugin → MCP server adapter
2. Plugin installation CLI: `clawd_ex plugins install/uninstall/list`
3. End-to-end test: install a plugin, see tools appear

### Phase 3: Production Hardening (Week 3)

1. SSE transport support
2. Reconnection with exponential backoff
3. Tool name collision handling
4. Health check integration
5. PubSub event broadcasting
6. Metrics / logging / error reporting

---

## 13. Testing Strategy

```
test/
  clawd_ex/
    mcp/
      protocol_test.exs        # Pure function tests, no GenServer
      connection_test.exs       # GenServer tests with mock port
      server_manager_test.exs   # DynamicSupervisor tests
      tool_proxy_test.exs       # Tool aggregation + routing tests
      config_test.exs           # Config loading + validation
      integration_test.exs      # Full stack: config → connection → tool call
```

**Mock MCP Server:** Write a simple Elixir script that acts as a stdio MCP server for testing. Responds to `initialize`, `tools/list`, `tools/call` with canned responses.

```elixir
# test/support/mock_mcp_server.exs
# Reads JSON-RPC from stdin, responds on stdout
# Used by Connection tests
```

---

## Appendix A: MCP Protocol Reference

Based on [MCP Specification 2024-11-05](https://spec.modelcontextprotocol.io/).

### Initialize Handshake

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {
      "name": "ClawdEx",
      "version": "0.1.0"
    }
  }
}

// Server → Client
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": { "listChanged": true }
    },
    "serverInfo": {
      "name": "feishu-bridge",
      "version": "1.0.0"
    }
  }
}

// Client → Server (notification, no id)
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```

### Tools List

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}

// Server → Client
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "feishu_doc",
        "description": "Read and write Feishu documents",
        "inputSchema": {
          "type": "object",
          "properties": {
            "action": { "type": "string", "enum": ["read", "write"] },
            "doc_token": { "type": "string" }
          },
          "required": ["action"]
        }
      }
    ]
  }
}
```

### Tools Call

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "feishu_doc",
    "arguments": {
      "action": "read",
      "doc_token": "doxcnXXXXX"
    }
  }
}

// Server → Client (success)
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      { "type": "text", "text": "# Document Title\n\nContent here..." }
    ],
    "isError": false
  }
}

// Server → Client (error)
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      { "type": "text", "text": "Permission denied: missing doc:read scope" }
    ],
    "isError": true
  }
}
```

---

## Appendix B: File/Directory Layout

```
clawd_ex/
  lib/clawd_ex/
    mcp/                          # NEW — entire directory
      supervisor.ex               # Top-level MCP supervisor
      server_manager.ex           # DynamicSupervisor for connections
      connection.ex               # Per-server GenServer
      protocol.ex                 # JSON-RPC 2.0 + MCP messages
      tool_proxy.ex               # Tool aggregation + routing
      config.ex                   # Config file loading

    tools/
      registry.ex                 # MODIFIED — add MCP tool source

    application.ex                # MODIFIED — add MCP.Supervisor to children

  test/clawd_ex/mcp/              # NEW — MCP tests
    protocol_test.exs
    connection_test.exs
    server_manager_test.exs
    tool_proxy_test.exs
    config_test.exs

~/.clawd/
  mcp_servers.json                # Single source of truth for MCP config
  bridge/
    mcp-bridge.js                 # Node.js bridge runtime
    package.json
  extensions/
    <plugin-name>/                # Installed plugins
```
