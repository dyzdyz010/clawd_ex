#!/usr/bin/env node

/**
 * ClawdEx MCP Bridge
 * 
 * Generic adapter that loads any OpenClaw-compatible plugin and exposes
 * its registered tools as an MCP (Model Context Protocol) server over stdio.
 * 
 * Usage:
 *   node bridge.js --plugin <path-or-dir>  [--config <json>]
 * 
 * Zero external dependencies — pure Node.js stdlib.
 */

import { createInterface } from 'readline';
import { readFileSync, existsSync } from 'fs';
import { resolve, join, dirname } from 'path';
import { pathToFileURL } from 'url';
import { homedir, platform, arch } from 'os';

// ============================================================================
// Argument parsing
// ============================================================================

function parseArgs(argv) {
  const result = { plugin: null, config: null, extensionsDir: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--plugin' && argv[i + 1]) result.plugin = argv[++i];
    else if (argv[i] === '--config' && argv[i + 1]) result.config = argv[++i];
    else if (argv[i] === '--extensions-dir' && argv[i + 1]) result.extensionsDir = argv[++i];
  }
  return result;
}

function expandPath(p) {
  if (p.startsWith('~/')) return join(homedir(), p.slice(2));
  return resolve(p);
}

// ============================================================================
// Plugin resolution
// ============================================================================

function resolvePlugin(spec, extensionsDir) {
  if (!spec) throw new Error('--plugin is required');

  // 1. Absolute or relative path
  const expanded = expandPath(spec);
  if (existsSync(expanded)) return expanded;

  // 2. Check extensions directory
  const extDir = extensionsDir || join(homedir(), '.clawd', 'extensions');
  const inExt = join(extDir, spec);
  if (existsSync(inExt)) return inExt;

  // 3. Try as a Node module (bare specifier)
  try {
    const resolved = import.meta.resolve(spec);
    return new URL(resolved).pathname;
  } catch { /* fall through */ }

  throw new Error(`Cannot resolve plugin: ${spec}`);
}

function findEntryPoint(pluginDir) {
  // If pluginDir is already a .js/.mjs/.ts file, use it directly
  if (/\.(js|mjs|ts)$/.test(pluginDir) && existsSync(pluginDir)) {
    return resolve(pluginDir);
  }

  // Read package.json to find entry
  const pkgPath = join(pluginDir, 'package.json');
  if (existsSync(pkgPath)) {
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    // OpenClaw plugins declare entry in openclaw.extensions
    const ocEntry = pkg.openclaw?.extensions?.[0];
    if (ocEntry) return resolve(pluginDir, ocEntry);
    // Fallback to main/module
    if (pkg.module) return resolve(pluginDir, pkg.module);
    if (pkg.main) return resolve(pluginDir, pkg.main);
  }
  // Default
  if (existsSync(join(pluginDir, 'index.js'))) return join(pluginDir, 'index.js');
  if (existsSync(join(pluginDir, 'index.mjs'))) return join(pluginDir, 'index.mjs');
  throw new Error(`No entry point found in ${pluginDir}`);
}

// ============================================================================
// Config loading
// ============================================================================

function loadConfig(configPath) {
  if (!configPath) return {};
  try {
    const expanded = expandPath(configPath);
    return JSON.parse(readFileSync(expanded, 'utf8'));
  } catch {
    return {};
  }
}

// ============================================================================
// Fake OpenClaw Plugin API — captures registerTool calls
// ============================================================================

function createFakeApi(config) {
  const capturedTools = [];

  const logger = {
    info: (msg) => process.stderr.write(`[bridge:info] ${msg}\n`),
    warn: (msg) => process.stderr.write(`[bridge:warn] ${msg}\n`),
    error: (msg) => process.stderr.write(`[bridge:error] ${msg}\n`),
    debug: (msg) => { if (process.env.DEBUG) process.stderr.write(`[bridge:debug] ${msg}\n`); },
  };

  const mockContext = {
    config: config,
    workspaceDir: process.env.CLAWD_WORKSPACE || join(homedir(), '.clawd', 'workspace'),
    agentDir: process.env.CLAWD_AGENT_DIR || join(homedir(), '.clawd'),
    agentId: 'bridge',
    sessionKey: 'mcp-bridge',
  };

  const api = {
    id: 'clawd-mcp-bridge',
    name: 'ClawdEx MCP Bridge',
    version: '0.1.0',
    description: 'MCP bridge for OpenClaw-compatible plugins',
    source: 'mcp-bridge',
    config: config,
    pluginConfig: config.pluginConfig || config,
    logger,
    runtime: {
      platform: platform(),
      arch: arch(),
      homeDir: homedir(),
      getWorkspaceDir: () => mockContext.workspaceDir,
      getAgentDir: () => mockContext.agentDir,
    },

    // === Core: capture tool registrations ===
    registerTool(toolOrFactory, opts) {
      if (typeof toolOrFactory === 'function') {
        // Tool Factory — invoke with context to get actual tool(s)
        try {
          const result = toolOrFactory(mockContext);
          if (Array.isArray(result)) {
            result.forEach(t => { if (t) capturedTools.push(normalizeTool(t)); });
          } else if (result) {
            capturedTools.push(normalizeTool(result));
          }
        } catch (err) {
          logger.warn(`Tool factory failed: ${err.message}`);
        }
      } else if (toolOrFactory) {
        capturedTools.push(normalizeTool(toolOrFactory));
      }
    },

    // === No-ops for capabilities we don't bridge ===
    registerChannel() {},
    registerProvider() {},
    registerHook() {},
    registerCli() {},
    registerService() {},
    registerCommand() {},
    registerHttpRoute() {},
    registerGatewayMethod() {},
    registerContextEngine() {},
    on() {},
    resolvePath: (p) => resolve(p),
  };

  return { api, capturedTools };
}

function normalizeTool(tool) {
  // Find the execute function (different plugins use different names)
  const executeFn = tool.execute || tool.run || tool.handler;
  return {
    name: tool.name,
    description: tool.description || `Tool: ${tool.name}`,
    inputSchema: tool.parameters || tool.inputSchema || tool.schema || {
      type: 'object',
      properties: {},
    },
    execute: executeFn,
  };
}

// ============================================================================
// MCP Server over stdio
// ============================================================================

function startMcpServer(tools) {
  const toolMap = new Map();
  for (const tool of tools) {
    if (tool.name && tool.execute) {
      toolMap.set(tool.name, tool);
    }
  }

  process.stderr.write(`[bridge] MCP server ready with ${toolMap.size} tool(s): ${[...toolMap.keys()].join(', ')}\n`);

  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

  rl.on('line', async (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;

    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      respond(null, null, { code: -32700, message: 'Parse error' });
      return;
    }

    const { id, method, params } = msg;

    // Notifications (no id) — just acknowledge silently
    if (id === undefined || id === null) {
      // e.g. notifications/initialized
      return;
    }

    switch (method) {
      case 'initialize':
        respond(id, {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'clawd-mcp-bridge', version: '0.1.0' },
        });
        break;

      case 'tools/list':
        respond(id, {
          tools: [...toolMap.values()].map(t => ({
            name: t.name,
            description: t.description,
            inputSchema: t.inputSchema,
          })),
        });
        break;

      case 'tools/call': {
        const { name, arguments: args } = params || {};
        const tool = toolMap.get(name);
        if (!tool) {
          respond(id, null, { code: -32601, message: `Tool not found: ${name}` });
          break;
        }
        try {
          const result = await tool.execute(args || {}, {});
          respond(id, { content: formatContent(result) });
        } catch (err) {
          respond(id, {
            content: [{ type: 'text', text: `Error: ${err.message}` }],
            isError: true,
          });
        }
        break;
      }

      case 'ping':
        respond(id, {});
        break;

      default:
        respond(id, null, { code: -32601, message: `Method not found: ${method}` });
    }
  });

  rl.on('close', () => process.exit(0));
  process.on('SIGTERM', () => process.exit(0));
  process.on('SIGINT', () => process.exit(0));
}

function respond(id, result, error) {
  const msg = { jsonrpc: '2.0', id };
  if (error) msg.error = error;
  else msg.result = result;
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function formatContent(result) {
  if (result === null || result === undefined) return [{ type: 'text', text: '' }];
  if (typeof result === 'string') return [{ type: 'text', text: result }];
  if (typeof result === 'object') {
    // MCP native content format
    if (Array.isArray(result.content)) return result.content;
    return [{ type: 'text', text: JSON.stringify(result, null, 2) }];
  }
  return [{ type: 'text', text: String(result) }];
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.plugin) {
    process.stderr.write('Usage: bridge.js --plugin <path-or-dir> [--config <json>]\n');
    process.exit(1);
  }

  // Resolve plugin path
  const pluginDir = resolvePlugin(args.plugin, args.extensionsDir);
  const entryPoint = findEntryPoint(pluginDir);

  process.stderr.write(`[bridge] Loading plugin from ${entryPoint}\n`);

  // Load plugin module
  const pluginModule = await import(pathToFileURL(entryPoint));
  const plugin = pluginModule.default || pluginModule;

  // Create fake API and capture tools
  const config = loadConfig(args.config);
  const { api, capturedTools } = createFakeApi(config);

  // Call plugin registration
  const pluginDef = typeof plugin === 'function' ? { register: plugin } : plugin;
  if (pluginDef.register) await pluginDef.register(api);
  if (pluginDef.activate) await pluginDef.activate(api);

  process.stderr.write(`[bridge] Captured ${capturedTools.length} tool(s)\n`);

  if (capturedTools.length === 0) {
    process.stderr.write('[bridge:warn] No tools captured. Plugin may use an unsupported registration pattern.\n');
  }

  // Start MCP server
  startMcpServer(capturedTools);
}

process.on('unhandledRejection', (reason) => {
  process.stderr.write(`[bridge:error] Unhandled rejection: ${reason}\n`);
  process.exit(1);
});

main().catch(err => {
  process.stderr.write(`[bridge:fatal] ${err.message}\n`);
  process.exit(1);
});
