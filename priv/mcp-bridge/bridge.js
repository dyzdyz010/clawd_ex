#!/usr/bin/env node

/**
 * ClawdEx MCP Bridge
 * 
 * Bridges OpenClaw plugins to MCP (Model Context Protocol) format.
 * Loads an OpenClaw plugin and exposes its tools as MCP tools.
 */

import { readFileSync } from 'fs';
import { pathToFileURL } from 'url';
import path from 'path';

// MCP Server implementation
class MCPServer {
  constructor() {
    this.tools = new Map();
    this.initialized = false;
  }

  async initialize(pluginPath) {
    try {
      // Load plugin package.json to get entry point
      const packageJsonPath = path.join(pluginPath, 'package.json');
      const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf8'));
      
      // Get entry point from openclaw field or main
      const entryPoint = packageJson.openclaw?.entry || packageJson.main || 'index.js';
      const pluginEntryPath = path.resolve(pluginPath, entryPoint);
      
      // Import the plugin module
      const pluginModule = await import(pathToFileURL(pluginEntryPath));
      const plugin = pluginModule.default || pluginModule;
      
      // Initialize plugin if it has an init method
      if (typeof plugin.init === 'function') {
        await plugin.init();
      }
      
      // Register tools from plugin
      if (plugin.tools && Array.isArray(plugin.tools)) {
        for (const tool of plugin.tools) {
          this.registerTool(tool);
        }
      } else if (typeof plugin.getTools === 'function') {
        const tools = await plugin.getTools();
        for (const tool of tools) {
          this.registerTool(tool);
        }
      }
      
      this.initialized = true;
      this.logDebug(`Initialized plugin from ${pluginPath} with ${this.tools.size} tools`);
      
    } catch (error) {
      this.logError(`Failed to initialize plugin: ${error.message}`);
      throw error;
    }
  }

  registerTool(tool) {
    if (!tool.name || typeof tool.execute !== 'function') {
      this.logError(`Invalid tool: missing name or execute function`);
      return;
    }

    const mcpTool = {
      name: tool.name,
      description: tool.description || `Tool: ${tool.name}`,
      inputSchema: tool.schema || {
        type: 'object',
        properties: {},
        additionalProperties: true
      },
      execute: tool.execute.bind(tool)
    };

    this.tools.set(tool.name, mcpTool);
    this.logDebug(`Registered tool: ${tool.name}`);
  }

  async handleRequest(request) {
    try {
      const { id, method, params } = request;

      switch (method) {
        case 'initialize':
          return {
            id,
            result: {
              protocolVersion: '2024-11-05',
              capabilities: {
                tools: {}
              },
              serverInfo: {
                name: 'clawd-ex-plugin-bridge',
                version: '1.0.0'
              }
            }
          };

        case 'tools/list':
          const toolsList = Array.from(this.tools.values()).map(tool => ({
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema
          }));
          
          return {
            id,
            result: {
              tools: toolsList
            }
          };

        case 'tools/call':
          const { name, arguments: args } = params;
          const tool = this.tools.get(name);
          
          if (!tool) {
            return {
              id,
              error: {
                code: -32601,
                message: `Tool not found: ${name}`
              }
            };
          }

          try {
            const result = await tool.execute(args);
            return {
              id,
              result: {
                content: [
                  {
                    type: 'text',
                    text: typeof result === 'string' ? result : JSON.stringify(result, null, 2)
                  }
                ]
              }
            };
          } catch (toolError) {
            return {
              id,
              error: {
                code: -32000,
                message: `Tool execution failed: ${toolError.message}`,
                data: { tool: name, error: toolError.message }
              }
            };
          }

        default:
          return {
            id,
            error: {
              code: -32601,
              message: `Method not found: ${method}`
            }
          };
      }
    } catch (error) {
      return {
        id: request.id || null,
        error: {
          code: -32603,
          message: `Internal error: ${error.message}`
        }
      };
    }
  }

  logDebug(message) {
    if (process.env.DEBUG) {
      console.error(`[DEBUG] ${message}`);
    }
  }

  logError(message) {
    console.error(`[ERROR] ${message}`);
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  
  // Parse command line arguments
  let pluginPath = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--plugin' && i + 1 < args.length) {
      pluginPath = args[i + 1];
      break;
    }
  }

  if (!pluginPath) {
    console.error('Usage: bridge.js --plugin <plugin-path>');
    process.exit(1);
  }

  const server = new MCPServer();
  
  try {
    // Initialize the plugin
    await server.initialize(pluginPath);
    
    // Set up JSON-RPC communication over stdio
    process.stdin.setEncoding('utf8');
    
    let buffer = '';
    
    process.stdin.on('data', async (chunk) => {
      buffer += chunk;
      
      // Process complete JSON-RPC messages
      let newlineIndex;
      while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        
        if (line) {
          try {
            const request = JSON.parse(line);
            const response = await server.handleRequest(request);
            process.stdout.write(JSON.stringify(response) + '\n');
          } catch (parseError) {
            const errorResponse = {
              id: null,
              error: {
                code: -32700,
                message: `Parse error: ${parseError.message}`
              }
            };
            process.stdout.write(JSON.stringify(errorResponse) + '\n');
          }
        }
      }
    });

    process.stdin.on('end', () => {
      process.exit(0);
    });

    // Handle cleanup on exit
    process.on('SIGINT', () => {
      server.logDebug('Received SIGINT, shutting down...');
      process.exit(0);
    });

    process.on('SIGTERM', () => {
      server.logDebug('Received SIGTERM, shutting down...');
      process.exit(0);
    });

    server.logDebug('MCP bridge started and ready');
    
  } catch (error) {
    console.error(`Failed to start bridge: ${error.message}`);
    process.exit(1);
  }
}

// Handle unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled Rejection at:', promise, 'reason:', reason);
  process.exit(1);
});

main().catch(error => {
  console.error(`Fatal error: ${error.message}`);
  process.exit(1);
});