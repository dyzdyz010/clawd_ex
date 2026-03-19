# Model Context Protocol (MCP) Client

ClawdEx implements a comprehensive MCP client architecture for connecting to external tools and services. This document provides technical details for developers building custom MCP servers and understanding the internal architecture.

## MCP Protocol Overview

The Model Context Protocol (MCP) is a standardized way for AI applications to securely connect to external data sources and tools. It provides:

- **Standardized Communication**: JSON-RPC 2.0 over various transports
- **Type Safety**: Well-defined schemas for tools, resources, and prompts
- **Security**: Sandboxed execution with explicit capabilities
- **Extensibility**: Plugin architecture for custom functionality

### ClawdEx as MCP Client

ClawdEx acts as an MCP client that:

1. **Discovers servers** from configuration
2. **Establishes connections** via stdio transport
3. **Negotiates capabilities** during initialization
4. **Invokes tools** on behalf of AI agents
5. **Handles responses** and errors gracefully

### Supported Transport Methods

- **stdio** (Current): JSON-RPC over stdin/stdout
- **SSE** (Planned): Server-Sent Events over HTTP
- **WebSocket** (Future): Bidirectional WebSocket communication

## Architecture

The MCP client implementation follows OTP principles with supervision trees:

```
MCP.Supervisor
├── MCP.ServerManager (DynamicSupervisor)
│   ├── MCP.Connection (GenServer) — per server instance  
│   ├── MCP.Connection (GenServer) — per server instance
│   └── MCP.Connection (GenServer) — per server instance
└── MCP.ToolProxy (GenServer) — dynamic tool registration
```

### Core Modules

#### MCP.Supervisor

Root supervisor managing the entire MCP subsystem:

```elixir
defmodule ClawdEx.MCP.Supervisor do
  use Supervisor
  
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    children = [
      {ClawdEx.MCP.ServerManager, []},
      {ClawdEx.MCP.ToolProxy, []}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

#### MCP.ServerManager

Dynamic supervisor for MCP server connections:

```elixir
defmodule ClawdEx.MCP.ServerManager do
  use DynamicSupervisor
  
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def start_server(server_config) do
    spec = {ClawdEx.MCP.Connection, server_config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
  
  def stop_server(server_id) do
    case find_server_pid(server_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
```

#### MCP.Connection

GenServer managing individual MCP server connections:

```elixir
defmodule ClawdEx.MCP.Connection do
  use GenServer
  
  @type state :: %{
    server_id: String.t(),
    process: port() | pid(),
    capabilities: map(),
    tools: [map()],
    status: :starting | :ready | :error | :stopped
  }
  
  def start_link(server_config) do
    GenServer.start_link(__MODULE__, server_config, 
      name: {:via, Registry, {ClawdEx.MCP.Registry, server_config.id}})
  end
  
  def call_tool(server_id, tool_name, arguments) do
    case Registry.lookup(ClawdEx.MCP.Registry, server_id) do
      [{pid, _}] -> GenServer.call(pid, {:call_tool, tool_name, arguments})
      [] -> {:error, :server_not_found}
    end
  end
end
```

#### MCP.ToolProxy

Aggregates tools from all connected servers:

```elixir
defmodule ClawdEx.MCP.ToolProxy do
  use GenServer
  
  def list_available_tools do
    GenServer.call(__MODULE__, :list_tools)
  end
  
  def call_tool(tool_name, arguments) do
    GenServer.call(__MODULE__, {:call_tool, tool_name, arguments})
  end
  
  # Routes tool calls to appropriate MCP servers
  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    case find_server_for_tool(tool_name, state.tool_registry) do
      nil -> {:reply, {:error, :tool_not_found}, state}
      server_id -> 
        result = MCP.Connection.call_tool(server_id, tool_name, arguments)
        {:reply, result, state}
    end
  end
end
```

## Custom MCP Server Development

### Basic MCP Server Structure

A minimal MCP server must implement the core protocol methods:

```javascript
#!/usr/bin/env node

import { createInterface } from 'readline';

class SimpleMCPServer {
  constructor() {
    this.tools = [
      {
        name: "echo",
        description: "Echo back the provided text",
        inputSchema: {
          type: "object",
          properties: {
            text: { type: "string", description: "Text to echo" }
          },
          required: ["text"]
        }
      }
    ];
  }

  async handleRequest(request) {
    switch (request.method) {
      case 'initialize':
        return {
          capabilities: {
            tools: {},
            resources: {},
            prompts: {}
          },
          serverInfo: {
            name: "simple-server",
            version: "1.0.0"
          }
        };

      case 'tools/list':
        return { tools: this.tools };

      case 'tools/call':
        return await this.handleToolCall(request.params);

      default:
        throw new Error(`Unknown method: ${request.method}`);
    }
  }

  async handleToolCall({ name, arguments: args }) {
    if (name === 'echo') {
      return {
        content: [
          {
            type: "text",
            text: `Echo: ${args.text}`
          }
        ]
      };
    }
    throw new Error(`Unknown tool: ${name}`);
  }
}

// Start the server
const server = new SimpleMCPServer();
const rl = createInterface({ input: process.stdin });

rl.on('line', async (line) => {
  try {
    const request = JSON.parse(line);
    const response = await server.handleRequest(request);
    console.log(JSON.stringify({
      jsonrpc: "2.0",
      id: request.id,
      result: response
    }));
  } catch (error) {
    console.log(JSON.stringify({
      jsonrpc: "2.0", 
      id: request.id,
      error: {
        code: -32603,
        message: error.message
      }
    }));
  }
});
```

### Advanced Server Features

#### Resource Handling

```javascript
// Add to your MCP server class
async handleRequest(request) {
  switch (request.method) {
    case 'resources/list':
      return { 
        resources: [
          {
            uri: "file:///data/example.txt",
            name: "Example File", 
            description: "Sample text file",
            mimeType: "text/plain"
          }
        ]
      };
      
    case 'resources/read':
      return await this.readResource(request.params.uri);
      
    // ... other methods
  }
}

async readResource(uri) {
  // Implement resource reading logic
  const content = await fs.readFile(uri.replace('file://', ''), 'utf-8');
  return {
    contents: [
      {
        uri: uri,
        mimeType: "text/plain",
        text: content
      }
    ]
  };
}
```

#### Prompt Templates

```javascript
async handleRequest(request) {
  switch (request.method) {
    case 'prompts/list':
      return {
        prompts: [
          {
            name: "analyze_code",
            description: "Analyze code for issues",
            arguments: [
              {
                name: "language",
                description: "Programming language",
                required: true
              },
              {
                name: "code",
                description: "Code to analyze", 
                required: true
              }
            ]
          }
        ]
      };
      
    case 'prompts/get':
      return await this.getPrompt(request.params);
      
    // ... other methods
  }
}
```

### Registering to ClawdEx

Add your custom server to the MCP configuration:

```json
{
  "my-custom-server": {
    "command": "node",
    "args": ["/path/to/your/server.js"],
    "env": {
      "API_KEY": "your-secret-key"
    }
  }
}
```

### Testing Your MCP Server

#### Manual Testing

```bash
# Test your server directly
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | node your-server.js

# Expected response:
# {"jsonrpc":"2.0","id":1,"result":{"capabilities":{...},"serverInfo":{...}}}
```

#### Integration Testing

```bash
# Add to ClawdEx and test
clawd_ex plugins doctor

# Check server appears in tools list
clawd_ex plugins info my-custom-server

# Test tool invocation in conversation
# "Use the echo tool to repeat 'hello world'"
```

## Configuration

### Elixir Application Config

```elixir
# config/config.exs
config :clawd_ex, :mcp,
  servers_config_path: "~/.clawd/mcp_servers.json",
  default_timeout: 30_000,
  max_retries: 3,
  enable_hot_reload: true

# config/runtime.exs  
config :clawd_ex, :mcp,
  servers_config_path: System.get_env("MCP_SERVERS_CONFIG", "~/.clawd/mcp_servers.json")
```

### Runtime JSON Configuration

The runtime configuration at `~/.clawd/mcp_servers.json` supports:

```json
{
  "server_name": {
    "command": "executable",
    "args": ["arg1", "arg2"],
    "env": {"KEY": "value"},
    "cwd": "/working/directory",
    "timeout": 30000,
    "retries": 3,
    "enabled": true,
    "capabilities": {
      "resources": true,
      "prompts": true,
      "tools": true
    }
  }
}
```

### Environment Variables

- `MCP_SERVERS_CONFIG`: Path to servers configuration file
- `MCP_DEFAULT_TIMEOUT`: Default timeout for tool calls (ms)
- `MCP_MAX_RETRIES`: Maximum retry attempts for failed calls
- `MCP_DEBUG`: Enable debug logging for MCP operations

## Error Handling

The MCP client implements comprehensive error handling:

### Connection Errors

```elixir
# Server startup failures
{:error, :server_start_failed} -> restart with backoff
{:error, :invalid_config} -> log and skip server
{:error, :timeout} -> retry with exponential backoff

# Runtime errors  
{:error, :connection_lost} -> attempt reconnection
{:error, :protocol_error} -> reset connection
{:error, :server_crashed} -> restart server process
```

### Tool Call Errors

```elixir
# MCP protocol errors
{:error, :tool_not_found} -> return user-friendly message
{:error, :invalid_arguments} -> validate and retry
{:error, :timeout} -> return partial results if available

# Server errors
{:error, :server_unavailable} -> try alternative server
{:error, :rate_limited} -> implement backoff
{:error, :permission_denied} -> log security event
```

### Monitoring and Observability

```elixir
# Metrics tracked
:mcp_tool_calls_total
:mcp_tool_call_duration_seconds
:mcp_connection_errors_total
:mcp_server_restarts_total

# Health checks
def health_check do
  servers = MCP.ServerManager.list_servers()
  Enum.map(servers, fn server ->
    %{
      name: server.name,
      status: MCP.Connection.get_status(server.id),
      tools: length(MCP.Connection.list_tools(server.id)),
      uptime: MCP.Connection.get_uptime(server.id)
    }
  end)
end
```

## Performance Considerations

### Connection Pooling

For high-volume deployments, consider connection pooling:

```elixir
# Pool configuration
config :clawd_ex, :mcp,
  connection_pool_size: 10,
  connection_pool_max_overflow: 5

# Pool implementation
def call_tool_with_pool(tool_name, arguments) do
  :poolboy.transaction(:mcp_pool, fn pid ->
    MCP.Connection.call_tool(pid, tool_name, arguments)
  end)
end
```

### Caching

Implement caching for expensive tool calls:

```elixir
defmodule ClawdEx.MCP.Cache do
  use GenServer
  
  def get_cached_result(tool_name, arguments) do
    cache_key = :crypto.hash(:md5, "#{tool_name}:#{inspect(arguments)}")
    GenServer.call(__MODULE__, {:get, cache_key})
  end
  
  def cache_result(tool_name, arguments, result, ttl \\ 300_000) do
    cache_key = :crypto.hash(:md5, "#{tool_name}:#{inspect(arguments)}")
    GenServer.cast(__MODULE__, {:put, cache_key, result, ttl})
  end
end
```

### Async Tool Calls

For long-running tools, implement async execution:

```elixir
def call_tool_async(tool_name, arguments, callback_pid) do
  Task.start(fn ->
    result = MCP.Connection.call_tool(server_id, tool_name, arguments)
    send(callback_pid, {:tool_result, tool_name, result})
  end)
end
```

This architecture provides a robust foundation for extending ClawdEx with custom tools while maintaining type safety, error resilience, and performance.