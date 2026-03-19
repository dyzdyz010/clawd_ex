# Plugin CLI Command Specification

## Overview

The plugin CLI provides a centralized way to manage MCP (Model Context Protocol) servers and OpenClaw plugins through a single configuration file (`~/.clawd/mcp_servers.json`).

## Design Principles

- **Single Source of Truth**: All plugin/MCP configurations are centralized in `~/.clawd/mcp_servers.json`
- **Configuration-Driven**: Avoid hardcoded paths and settings; everything is configurable
- **Unified Interface**: Manage both native OpenClaw plugins and standalone MCP servers

## Commands

### `clawd_ex plugins list`

List all installed plugins with their status and source information.

**Usage:**
```
clawd_ex plugins list [options]
```

**Options:**
- `--format json` - Output in JSON format (default: table)
- `--status running|stopped|error` - Filter by status
- `--source openclaw-plugin|mcp-server|local` - Filter by source type

**Output Format (Table):**
```
Plugins (2 installed)

┌────────────┬──────────┬─────────┬─────────┬────────────────────────────────┐
│ Name       │ ID       │ Status  │ Tools   │ Source                         │
├────────────┼──────────┼─────────┼─────────┼────────────────────────────────┤
│ Feishu     │ feishu   │ running │ 12      │ ~/.clawd/extensions/feishu-... │
│ Custom MCP │ my-mcp   │ stopped │ 3       │ uvx some-server                │
└────────────┴──────────┴─────────┴─────────┴────────────────────────────────┘
```

**Output Format (JSON):**
```json
{
  "plugins": [
    {
      "id": "feishu",
      "name": "Feishu Plugin",
      "enabled": true,
      "status": "running",
      "tools": 12,
      "source": {
        "type": "openclaw-plugin",
        "spec": "@larksuiteoapi/feishu-openclaw-plugin",
        "version": "2026.3.8"
      },
      "path": "~/.clawd/extensions/node_modules/@larksuiteoapi/feishu-openclaw-plugin"
    }
  ],
  "total": 1,
  "enabled": 1,
  "running": 1
}
```

### `clawd_ex plugins install <spec>`

Install a new plugin from npm, local path, or git repository.

**Usage:**
```
clawd_ex plugins install <spec> [options]
```

**Arguments:**
- `<spec>` - Package specifier:
  - npm: `@larksuiteoapi/feishu-openclaw-plugin@1.0.0`
  - local: `./my-plugin` or `/absolute/path/to/plugin`
  - git: `git+https://github.com/user/plugin.git`

**Options:**
- `--id <id>` - Custom server ID (default: auto-generated from name)
- `--name <name>` - Display name override
- `--config <path>` - Config file with environment variables
- `--env KEY=VALUE` - Set environment variable (repeatable)
- `--timeout <ms>` - Tool call timeout in milliseconds (default: 30000)
- `--no-start` - Install but don't start the server

**Install Flow:**

1. **Check Prerequisites:**
   ```bash
   # Check Node.js availability
   node --version || echo "Error: Node.js not found"
   ```

2. **Prepare Extensions Directory:**
   ```bash
   mkdir -p ~/.clawd/extensions
   cd ~/.clawd/extensions
   ```

3. **Install Package:**
   ```bash
   npm install <spec>
   ```

4. **Discover Plugin Entry:**
   - Look for `openclaw.plugin.json` in package root
   - Fallback to `package.json` → `openclaw` field
   - Determine entry point and metadata

5. **Generate MCP Configuration:**
   - Create server config based on plugin type
   - Set up bridge command for OpenClaw plugins
   - Configure environment variables

6. **Update Config File:**
   - Read existing `~/.clawd/mcp_servers.json`
   - Merge new server configuration
   - Write back to file atomically

7. **Validate and Start:**
   - Test server startup
   - Query available tools
   - Report success with tool count

**Example Output:**
```
Installing @larksuiteoapi/feishu-openclaw-plugin@2026.3.8...
✓ Downloaded and extracted package
✓ Discovered plugin entry: lib/index.js
✓ Generated MCP server configuration (ID: feishu)
✓ Updated ~/.clawd/mcp_servers.json
✓ Started server and validated connection
✓ Plugin installed successfully!

Available tools: feishu_doc_read, feishu_doc_write, feishu_bitable_read, ...
Total: 12 tools

Configuration:
  • Server ID: feishu
  • Config file: ~/.clawd/mcp_servers.json
  • Environment: Set FEISHU_APP_ID and FEISHU_APP_SECRET to enable API access

Next steps:
  1. Edit ~/.clawd/mcp_servers.json to configure API credentials
  2. Run 'clawd_ex plugins doctor feishu' to test connection
```

### `clawd_ex plugins uninstall <name>`

Remove a plugin and its configuration.

**Usage:**
```
clawd_ex plugins uninstall <name> [options]
```

**Arguments:**
- `<name>` - Plugin name or ID to uninstall

**Options:**
- `--keep-package` - Keep npm package, only remove server config
- `--force` - Skip confirmation prompt

**Flow:**
1. Stop server if running
2. Remove from `~/.clawd/mcp_servers.json`
3. Optionally remove npm package from `~/.clawd/extensions`
4. Clean up any generated files

### `clawd_ex plugins enable <name>`

Enable a disabled plugin.

**Usage:**
```
clawd_ex plugins enable <name>
```

**Flow:**
1. Update `enabled: true` in config file
2. Start MCP server if not running
3. Notify server manager to refresh

### `clawd_ex plugins disable <name>`

Disable an enabled plugin.

**Usage:**
```
clawd_ex plugins disable <name>
```

**Flow:**
1. Stop MCP server if running
2. Update `enabled: false` in config file
3. Notify server manager to refresh

### `clawd_ex plugins update [name]`

Update one or all plugins to their latest versions.

**Usage:**
```
clawd_ex plugins update [name] [options]
```

**Arguments:**
- `[name]` - Plugin name to update (omit to update all)

**Options:**
- `--dry-run` - Show what would be updated without making changes
- `--check-only` - Only check for available updates

**Flow:**
1. Query current versions from config
2. Check for updates (npm outdated, git tags)
3. Update packages and regenerate configs
4. Restart updated servers

### `clawd_ex plugins info <name>`

Show detailed information about a specific plugin.

**Usage:**
```
clawd_ex plugins info <name> [options]
```

**Arguments:**
- `<name>` - Plugin name or ID

**Options:**
- `--format json` - Output in JSON format

**Output:**
```
Plugin: Feishu
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                Feishu Plugin                                   │
└─────────────────────────────────────────────────────────────────────────────────┘

  ID:           feishu
  Name:         Feishu Plugin
  Description:  Feishu/Lark document and table operations
  Version:      2026.3.8
  Status:       running (PID: 12345)
  Enabled:      ✓
  Source:       openclaw-plugin
  Package:      @larksuiteoapi/feishu-openclaw-plugin
  Location:     ~/.clawd/extensions/node_modules/@larksuiteoapi/feishu-openclaw-plugin
  Installed:    2026-03-19 10:00:00 UTC

Configuration:
  Command:      node ~/.clawd/bridge/mcp-bridge.js --plugin <path>
  Timeout:      30s
  Auto-restart: ✓
  Environment:  FEISHU_APP_ID, FEISHU_APP_SECRET

Available Tools (12):
  • feishu_doc_read         - Read Feishu document content
  • feishu_doc_write        - Write/update Feishu documents
  • feishu_bitable_read     - Query Feishu bitable records
  • feishu_bitable_write    - Create/update bitable records
  • feishu_calendar_read    - Read calendar events
  • ...

Connection Status:
  ✓ Server process running (PID: 12345)
  ✓ MCP connection established
  ✓ Tools responding normally
  ✓ Last tool call: 2s ago
```

### `clawd_ex plugins doctor [name]`

Run health checks on plugin system or specific plugin.

**Usage:**
```
clawd_ex plugins doctor [name] [options]
```

**Arguments:**
- `[name]` - Check specific plugin (omit to check all)

**Options:**
- `--fix` - Attempt to fix detected issues
- `--verbose` - Show detailed diagnostic output

**Checks:**
1. **System Requirements:**
   - Node.js availability and version
   - MCP bridge executable
   - Extensions directory permissions

2. **Configuration Integrity:**
   - Valid JSON syntax in config file
   - Required fields present
   - No duplicate IDs

3. **Plugin Health:**
   - Package integrity and dependencies
   - Server process status
   - MCP connection state
   - Tool availability and response

4. **Environment Setup:**
   - Required environment variables set
   - API credentials validity
   - Network connectivity (if applicable)

**Output:**
```
ClawdEx Plugin System Diagnostics
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                 System Health                                  │
└─────────────────────────────────────────────────────────────────────────────────┘

Prerequisites:
  ✓ Node.js v20.10.0 found
  ✓ MCP bridge available at ~/.clawd/bridge/mcp-bridge.js
  ✓ Extensions directory exists and writable

Configuration:
  ✓ ~/.clawd/mcp_servers.json syntax valid
  ✓ All server IDs unique
  ✓ No orphaned configurations

Plugins (2 total):
  ✓ feishu (Feishu Plugin) - running, 12 tools available
  ✗ my-mcp (Custom MCP) - connection failed: timeout
  
Issues Found:
  1. Plugin 'my-mcp': Server not responding
     • Command: uvx mcp-server-postgres
     • Error: Connection timeout after 30s
     • Fix: Check uvx installation and server dependencies

Recommendations:
  • Update @larksuiteoapi/feishu-openclaw-plugin to v2026.3.9
  • Set FEISHU_APP_SECRET for full functionality
  • Consider increasing timeout for slow-starting servers

Overall Status: 1 plugin healthy, 1 plugin has issues
```

## Error Handling

### Common Error Codes

- `PLUGIN_NOT_FOUND` - Specified plugin name/ID not found
- `PACKAGE_INSTALL_FAILED` - npm install or package download failed
- `INVALID_PLUGIN` - Package doesn't contain valid OpenClaw plugin
- `CONFIG_SYNTAX_ERROR` - Invalid JSON in mcp_servers.json
- `PERMISSION_DENIED` - Cannot write to config file or extensions directory
- `SERVER_START_FAILED` - MCP server failed to start
- `CONNECTION_TIMEOUT` - Server started but MCP connection timed out

### Error Output Format

```json
{
  "error": {
    "code": "PACKAGE_INSTALL_FAILED",
    "message": "Failed to install package @example/plugin",
    "details": {
      "npm_error": "Package not found",
      "command": "npm install @example/plugin",
      "exit_code": 1
    },
    "suggestions": [
      "Check package name spelling",
      "Verify npm registry access",
      "Try with --verbose for more details"
    ]
  }
}
```

## Configuration File Schema

### `~/.clawd/mcp_servers.json` - Single Source of Truth

The configuration file that contains all MCP server and plugin definitions.

```json
{
  "version": 1,
  "servers": [
    {
      "id": "feishu",
      "name": "Feishu Plugin",
      "enabled": true,
      "transport": "stdio",
      "command": "node",
      "args": [
        "~/.clawd/bridge/mcp-bridge.js",
        "--plugin",
        "~/.clawd/extensions/node_modules/@larksuiteoapi/feishu-openclaw-plugin"
      ],
      "env": {
        "FEISHU_APP_ID": "cli_xxx",
        "FEISHU_APP_SECRET": "xxx"
      },
      "timeout_ms": 30000,
      "auto_restart": true,
      "source": {
        "type": "openclaw-plugin",
        "spec": "@larksuiteoapi/feishu-openclaw-plugin",
        "version": "2026.3.8",
        "installed_at": "2026-03-19T10:00:00Z"
      }
    },
    {
      "id": "custom-db",
      "name": "Database Tools",
      "enabled": true,
      "transport": "stdio",
      "command": "uvx",
      "args": [
        "mcp-server-postgres",
        "--connection-string",
        "postgresql://user:pass@localhost/db"
      ],
      "env": {},
      "timeout_ms": 60000,
      "auto_restart": false
    }
  ]
}
```

### Field Descriptions

#### Root Object

- `version` (number): Schema version for future migration support
- `servers` (array): List of MCP server configurations

#### Server Object

**Required Fields:**
- `id` (string): Unique identifier for the server
  - Auto-generated from package name if not specified
  - Used for enable/disable/info commands
  - Must be valid as CLI argument (alphanumeric + hyphens/underscores)

- `name` (string): Human-readable display name
  - Shown in `plugins list` command
  - Defaults to package name or id if not specified

- `enabled` (boolean): Whether the server is enabled
  - `true`: Server will be started and tools made available
  - `false`: Server stopped, tools unavailable

- `transport` (string): Communication transport type
  - Currently only `"stdio"` supported
  - Future: `"sse"`, `"websocket"` may be added

- `command` (string): Executable command to start the server
  - Examples: `"node"`, `"python"`, `"uvx"`, `"./my-binary"`
  - Path resolution: relative to working directory, then `$PATH`

- `args` (array): Command-line arguments
  - Passed to the command as argv
  - Supports tilde expansion (`~/.clawd/...`)
  - Environment variable substitution: `${HOME}`, `${USER}`

**Optional Fields:**
- `env` (object): Environment variables for the server process
  - Merged with system environment (server env takes precedence)
  - Used for API keys, configuration values, feature flags
  - Empty object `{}` means inherit system environment only

- `timeout_ms` (number): Tool call timeout in milliseconds
  - Default: 30000 (30 seconds)
  - Server killed if tool call exceeds this duration
  - Set higher for slow operations (database queries, API calls)

- `auto_restart` (boolean): Restart server on crash
  - Default: `false` for custom servers, `true` for plugins
  - Useful for unstable or development servers

- `source` (object): Installation metadata (set by `install` command)
  - `type`: Installation source type
    - `"openclaw-plugin"`: OpenClaw plugin installed via npm
    - `"mcp-server"`: Standalone MCP server
    - `"local"`: Local development or manual installation
  - `spec`: Original package specifier from install command
  - `version`: Installed version (from package.json or git tag)
  - `installed_at`: ISO 8601 timestamp of installation

### Configuration Examples

#### OpenClaw Plugin (via npm)
```json
{
  "id": "feishu",
  "name": "Feishu/Lark Integration",
  "enabled": true,
  "transport": "stdio",
  "command": "node",
  "args": [
    "~/.clawd/bridge/mcp-bridge.js",
    "--plugin",
    "~/.clawd/extensions/node_modules/@larksuiteoapi/feishu-openclaw-plugin"
  ],
  "env": {
    "FEISHU_APP_ID": "cli_xxx",
    "FEISHU_APP_SECRET": "xxx",
    "FEISHU_BASE_URL": "https://open.feishu.cn"
  },
  "timeout_ms": 30000,
  "auto_restart": true,
  "source": {
    "type": "openclaw-plugin",
    "spec": "@larksuiteoapi/feishu-openclaw-plugin@^2.0.0",
    "version": "2026.3.8",
    "installed_at": "2026-03-19T10:00:00Z"
  }
}
```

#### Standalone MCP Server (Python)
```json
{
  "id": "postgres-db",
  "name": "PostgreSQL Database",
  "enabled": true,
  "transport": "stdio",
  "command": "uvx",
  "args": [
    "mcp-server-postgres",
    "--connection-string",
    "${DATABASE_URL}"
  ],
  "env": {
    "DATABASE_URL": "postgresql://localhost/mydb"
  },
  "timeout_ms": 60000,
  "auto_restart": false
}
```

#### Local Development Server
```json
{
  "id": "my-dev-tools",
  "name": "Development Tools",
  "enabled": true,
  "transport": "stdio", 
  "command": "./target/debug/my-mcp-server",
  "args": ["--config", "dev.toml"],
  "env": {
    "RUST_LOG": "debug",
    "DEV_MODE": "true"
  },
  "timeout_ms": 10000,
  "auto_restart": true,
  "source": {
    "type": "local",
    "spec": "./my-rust-project",
    "version": "dev",
    "installed_at": "2026-03-19T14:30:00Z"
  }
}
```

#### HTTP-based MCP Server (Future)
```json
{
  "id": "remote-api",
  "name": "Remote API Tools",
  "enabled": true,
  "transport": "sse",
  "url": "https://api.example.com/mcp",
  "headers": {
    "Authorization": "Bearer ${API_TOKEN}"
  },
  "env": {
    "API_TOKEN": "xxx"
  },
  "timeout_ms": 45000
}
```