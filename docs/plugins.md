# Plugins System

ClawdEx extends its capabilities through the Model Context Protocol (MCP), enabling seamless integration of external tools and plugins. The system supports two main plugin architectures: native MCP servers and community plugins through the Bridge adapter.

## Overview

- **MCP Client**: ClawdEx acts as an MCP client, connecting to various MCP servers
- **Bridge Adapter**: Converts community plugins to MCP format for compatibility  
- **Unified Interface**: All plugins appear as available tools in agent conversations
- **Hot Reload**: Runtime plugin management without restart

## Quick Start

### Installing Community Plugins

```bash
# Install a community plugin (e.g., Feishu plugin)
clawd_ex plugins install @larksuiteoapi/feishu-openclaw-plugin

# Configure API credentials
# Edit ~/.clawd/mcp_servers.json, add required environment variables:
# env.FEISHU_APP_ID and env.FEISHU_APP_SECRET

# List installed plugins
clawd_ex plugins list

# View plugin details and available tools
clawd_ex plugins info feishu
```

### Using Standard MCP Servers

```bash
# Add any MCP server by editing the configuration
# Edit ~/.clawd/mcp_servers.json
```

Example configuration for common MCP servers:

```json
{
  "postgres": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-postgres"],
    "env": {
      "POSTGRES_CONNECTION_STRING": "postgresql://user:pass@localhost/db"
    }
  },
  "filesystem": {
    "command": "npx", 
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/directory"],
    "env": {}
  },
  "brave-search": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-brave-search"],
    "env": {
      "BRAVE_API_KEY": "your-api-key-here"
    }
  },
  "git": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-git", "--repository", "/path/to/repo"],
    "env": {}
  }
}
```

## Configuration

### Main Configuration File

ClawdEx uses a single configuration file: `~/.clawd/mcp_servers.json`

**File Structure:**
```json
{
  "server-name": {
    "command": "executable-command",
    "args": ["arg1", "arg2"],
    "env": {
      "ENV_VAR": "value"
    },
    "enabled": true
  }
}
```

**Field Descriptions:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `command` | string | Yes | Executable command or path |
| `args` | array | Yes | Command-line arguments |
| `env` | object | No | Environment variables |
| `enabled` | boolean | No | Enable/disable server (default: true) |

### Configuration Example

```json
{
  "feishu": {
    "command": "node",
    "args": [
      "/Users/user/.clawd/node_modules/.bin/clawd-mcp-bridge",
      "--plugin", "@larksuiteoapi/feishu-openclaw-plugin"
    ],
    "env": {
      "FEISHU_APP_ID": "cli_abc123def456",
      "FEISHU_APP_SECRET": "your-app-secret-here"
    },
    "enabled": true
  },
  "github": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-github"],
    "env": {
      "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_your-token-here"
    }
  }
}
```

## Plugin Management

### Installation Commands

```bash
# Install from npm registry
clawd_ex plugins install @scope/package-name

# Install from local path  
clawd_ex plugins install ./path/to/plugin

# Install specific version
clawd_ex plugins install package-name@1.2.3

# Install from Git repository
clawd_ex plugins install git+https://github.com/user/repo.git
```

### Management Commands

```bash
# List all plugins
clawd_ex plugins list

# Show plugin information and tools
clawd_ex plugins info <plugin-name>

# Enable/disable plugins
clawd_ex plugins enable <plugin-name>
clawd_ex plugins disable <plugin-name>

# Update plugins
clawd_ex plugins update <plugin-name>
clawd_ex plugins update-all

# Remove plugins  
clawd_ex plugins uninstall <plugin-name>

# Reload configuration
clawd_ex plugins reload
```

### Plugin Status

```bash
# Check plugin status
clawd_ex plugins status

# Example output:
# ┌─────────────┬─────────┬──────────┬────────────────┬────────────────┐
# │ Plugin      │ Version │ Status   │ Tools          │ Description    │
# ├─────────────┼─────────┼──────────┼────────────────┼────────────────┤
# │ feishu      │ 1.0.0   │ Enabled  │ 12 tools       │ Feishu integration │
# │ postgres    │ 0.3.1   │ Disabled │ 5 tools        │ PostgreSQL tools │
# └─────────────┴─────────┴──────────┴────────────────┴────────────────┘
```

## Troubleshooting

### Diagnostic Command

```bash
# Run comprehensive diagnostic
clawd_ex plugins doctor

# Example output:
# ✓ Node.js runtime available (v20.11.0)
# ✓ MCP bridge script found
# ✗ Plugin 'feishu' failed to load: Missing FEISHU_APP_ID
# ✓ MCP server 'postgres' responding
# ⚠ Plugin 'github' tools partially available (rate limited)
```

### Common Issues

#### Node.js Not Installed

**Problem**: `clawd_ex plugins doctor` shows Node.js unavailable

**Solution**:
```bash
# Install Node.js via package manager
# macOS with Homebrew:
brew install node

# Linux with apt:
sudo apt install nodejs npm

# Verify installation
node --version
npm --version
```

#### Plugin Load Failure

**Problem**: Plugin fails to initialize or tools are unavailable

**Solutions**:
1. **Check dependencies**:
   ```bash
   # Verify plugin package exists
   npm list <plugin-name>
   
   # Reinstall if missing
   clawd_ex plugins uninstall <plugin-name>
   clawd_ex plugins install <plugin-name>
   ```

2. **Validate configuration**:
   ```bash
   # Test JSON syntax
   cat ~/.clawd/mcp_servers.json | jq '.'
   
   # Check environment variables
   printenv | grep FEISHU
   ```

#### Tool Call Timeout

**Problem**: Tools take too long to respond or timeout

**Solution**: Adjust timeout in configuration:
```json
{
  "slow-plugin": {
    "command": "node",
    "args": ["path/to/plugin"],
    "env": {},
    "timeout": 30000,
    "retries": 3
  }
}
```

#### API Key Configuration Error

**Problem**: Authentication failures or missing credentials

**Solutions**:
1. **Check environment variables**:
   ```bash
   echo $FEISHU_APP_ID
   echo $FEISHU_APP_SECRET
   ```

2. **Update configuration**:
   ```bash
   # Edit configuration directly
   nano ~/.clawd/mcp_servers.json
   
   # Or use the configuration command
   clawd_ex configure
   ```

3. **Verify API credentials**:
   ```bash
   # Test API access manually
   curl -H "Authorization: Bearer $API_TOKEN" https://api.example.com/test
   ```

### Debug Mode

Enable verbose logging for plugin debugging:

```bash
# Set debug environment variable
export CLAWD_EX_DEBUG=true

# Run with verbose output
clawd_ex plugins doctor --verbose

# Check detailed logs
clawd_ex logs --level debug --tail 100 | grep -i plugin
```

### Getting Help

1. **Check plugin documentation**: Most plugins include usage examples in their README
2. **Review MCP specifications**: Visit [modelcontextprotocol.io](https://modelcontextprotocol.io)
3. **Community support**: Join the OpenClaw community for plugin-specific help
4. **Issue reporting**: Report bugs to plugin maintainers with diagnostic output

## Example: Setting Up Feishu Plugin

Complete walkthrough for setting up the Feishu plugin:

1. **Install the plugin**:
   ```bash
   clawd_ex plugins install @larksuiteoapi/feishu-openclaw-plugin
   ```

2. **Get Feishu credentials**:
   - Go to [Feishu Open Platform](https://open.feishu.cn/)
   - Create an app and note your App ID and App Secret

3. **Configure environment**:
   ```bash
   # Add to ~/.clawd/mcp_servers.json
   {
     "feishu": {
       "command": "node",
       "args": [
         "/Users/user/.clawd/node_modules/.bin/clawd-mcp-bridge",
         "--plugin", "@larksuiteoapi/feishu-openclaw-plugin"
       ],
       "env": {
         "FEISHU_APP_ID": "cli_your_app_id_here",
         "FEISHU_APP_SECRET": "your_app_secret_here"
       }
     }
   }
   ```

4. **Test the setup**:
   ```bash
   clawd_ex plugins doctor
   clawd_ex plugins info feishu
   ```

5. **Use in conversation**:
   The Feishu tools will automatically be available to agents for creating documents, managing calendars, etc.