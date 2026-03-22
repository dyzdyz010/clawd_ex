#!/usr/bin/env node

/**
 * ClawdEx Plugin Host — Node.js sidecar for Plugin System V2
 *
 * Long-running process that loads multiple plugins and exposes their
 * tools/channels via JSON-RPC 2.0 over stdio (newline-delimited).
 *
 * Protocol: Elixir NodeBridge ↔ stdin/stdout ↔ this script
 *
 * Zero external dependencies — pure Node.js stdlib.
 */

import { createInterface } from 'readline';
import { readFileSync, existsSync } from 'fs';
import { resolve, join } from 'path';
import { pathToFileURL } from 'url';
import { homedir, platform, arch } from 'os';

// ============================================================================
// JSON-RPC transport (hoisted for use by console interceptors)
// ============================================================================

function respond(id, result) {
  const msg = { jsonrpc: '2.0', id, result };
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function respondError(id, code, message) {
  const msg = {
    jsonrpc: '2.0',
    id,
    error: { code, message },
  };
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function notify(method, params) {
  const msg = { jsonrpc: '2.0', method, params };
  process.stdout.write(JSON.stringify(msg) + '\n');
}

// ============================================================================
// C4: Intercept console.log/warn/error to prevent plugins from writing
// directly to stdout (which would corrupt the JSON-RPC protocol).
// Redirect to plugin.log notifications.
// ============================================================================

console.log = (...args) => {
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  notify('plugin.log', { pluginId: 'host', level: 'info', message: msg });
};
console.warn = (...args) => {
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  notify('plugin.log', { pluginId: 'host', level: 'warn', message: msg });
};
console.error = (...args) => {
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  notify('plugin.log', { pluginId: 'host', level: 'error', message: msg });
};
console.debug = (...args) => {
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  notify('plugin.log', { pluginId: 'host', level: 'debug', message: msg });
};

// ============================================================================
// State — loaded plugins keyed by plugin ID
// ============================================================================

const plugins = new Map();
// Each entry: { id, dir, tools: Map<name, {name, description, parameters, execute}>, channels: [] }

// ============================================================================
// Plugin API factory — creates an OpenClaw-like API for each plugin
// ============================================================================

function createPluginApi(pluginId, pluginDir, config) {
  const tools = new Map();
  const channels = [];

  const logger = {
    info:  (msg) => notify('plugin.log', { pluginId, level: 'info',  message: String(msg) }),
    warn:  (msg) => notify('plugin.log', { pluginId, level: 'warn',  message: String(msg) }),
    error: (msg) => notify('plugin.log', { pluginId, level: 'error', message: String(msg) }),
    debug: (msg) => notify('plugin.log', { pluginId, level: 'debug', message: String(msg) }),
  };

  const mockContext = {
    config,
    workspaceDir: process.env.CLAWD_WORKSPACE || join(homedir(), '.clawd', 'workspace'),
    agentDir: process.env.CLAWD_AGENT_DIR || join(homedir(), '.clawd'),
    agentId: 'plugin-host',
    sessionKey: `plugin-host:${pluginId}`,
  };

  const api = {
    id: `clawd-plugin-host:${pluginId}`,
    name: 'ClawdEx Plugin Host',
    version: '0.2.0',
    config,
    pluginConfig: config,
    logger,
    runtime: {
      platform: platform(),
      arch: arch(),
      homeDir: homedir(),
      getWorkspaceDir: () => mockContext.workspaceDir,
      getAgentDir: () => mockContext.agentDir,
    },

    registerTool(toolOrFactory) {
      if (typeof toolOrFactory === 'function') {
        try {
          const result = toolOrFactory(mockContext);
          if (Array.isArray(result)) {
            result.forEach(t => { if (t) tools.set(t.name, normalizeTool(t)); });
          } else if (result) {
            tools.set(result.name, normalizeTool(result));
          }
        } catch (err) {
          logger.warn(`Tool factory failed: ${err.message}`);
        }
      } else if (toolOrFactory) {
        tools.set(toolOrFactory.name, normalizeTool(toolOrFactory));
      }
    },

    registerChannel(channelDef) {
      if (channelDef && channelDef.id) {
        channels.push(channelDef);
      }
    },

    // No-ops for capabilities we don't support yet
    registerProvider() {},
    registerHook() {},
    registerCli() {},
    registerService() {},
    registerCommand() {},
    registerHttpRoute() {},
    registerGatewayMethod() {},
    registerContextEngine() {},
    on() {},
    resolvePath: (p) => resolve(pluginDir, p),
  };

  return { api, tools, channels };
}

function normalizeTool(tool) {
  const executeFn = tool.execute || tool.run || tool.handler;
  return {
    name: tool.name,
    description: tool.description || `Tool: ${tool.name}`,
    parameters: tool.parameters || tool.inputSchema || tool.schema || {
      type: 'object',
      properties: {},
    },
    execute: executeFn,
  };
}

// ============================================================================
// Plugin resolution
// ============================================================================

function findEntryPoint(pluginDir) {
  if (/\.(js|mjs|cjs)$/.test(pluginDir) && existsSync(pluginDir)) {
    return resolve(pluginDir);
  }

  const pkgPath = join(pluginDir, 'package.json');
  if (existsSync(pkgPath)) {
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    const ocEntry = pkg.openclaw?.extensions?.[0];
    if (ocEntry) return resolve(pluginDir, ocEntry);
    if (pkg.module) return resolve(pluginDir, pkg.module);
    if (pkg.main) return resolve(pluginDir, pkg.main);
  }

  // plugin.json entry field
  const pluginJsonPath = join(pluginDir, 'plugin.json');
  if (existsSync(pluginJsonPath)) {
    const meta = JSON.parse(readFileSync(pluginJsonPath, 'utf8'));
    if (meta.entry) return resolve(pluginDir, meta.entry);
  }

  if (existsSync(join(pluginDir, 'index.js'))) return join(pluginDir, 'index.js');
  if (existsSync(join(pluginDir, 'index.mjs'))) return join(pluginDir, 'index.mjs');

  throw new Error(`No entry point found in ${pluginDir}`);
}

// ============================================================================
// RPC handlers
// ============================================================================

async function handlePluginLoad(params) {
  const { pluginDir, config } = params;
  if (!pluginDir) throw new Error('pluginDir is required');

  const resolvedDir = resolve(pluginDir);
  const entryPoint = findEntryPoint(resolvedDir);

  // Read plugin.json for ID if available
  let pluginId;
  const pluginJsonPath = join(resolvedDir, 'plugin.json');
  if (existsSync(pluginJsonPath)) {
    const meta = JSON.parse(readFileSync(pluginJsonPath, 'utf8'));
    pluginId = meta.id;
  }
  if (!pluginId) {
    // Derive from directory name
    pluginId = resolvedDir.split('/').pop();
  }

  // Create API and load plugin
  // C4: Validate entryPoint is within pluginDir (prevent path traversal)
  const realEntry = resolve(entryPoint);
  const realDir = resolve(resolvedDir);
  if (!realEntry.startsWith(realDir + '/') && realEntry !== realDir) {
    throw new Error(`Entry point "${entryPoint}" is outside plugin directory "${resolvedDir}"`);
  }

  const { api, tools, channels } = createPluginApi(pluginId, resolvedDir, config || {});

  let pluginModule;
  try {
    pluginModule = await import(pathToFileURL(entryPoint).href);
  } catch (err) {
    throw new Error(`Failed to load plugin module: ${err.message}`);
  }
  const plugin = pluginModule.default || pluginModule;

  const pluginDef = typeof plugin === 'function' ? { register: plugin } : plugin;
  try {
    if (pluginDef.register) await pluginDef.register(api);
  } catch (err) {
    throw new Error(`Plugin register() failed: ${err.message}`);
  }
  try {
    if (pluginDef.activate) await pluginDef.activate(api);
  } catch (err) {
    notify('plugin.error', { pluginId, error: `activate() failed: ${err.message}` });
    // Continue — plugin may still be partially usable
  }

  plugins.set(pluginId, {
    id: pluginId,
    dir: resolvedDir,
    tools,
    channels,
  });

  return {
    ok: true,
    pluginId,
    tools: [...tools.keys()],
    channels: channels.map(c => c.id),
  };
}

async function handlePluginUnload(params) {
  const { pluginId } = params;
  if (!pluginId) throw new Error('pluginId is required');

  const entry = plugins.get(pluginId);
  if (!entry) throw new Error(`Plugin not loaded: ${pluginId}`);

  plugins.delete(pluginId);
  return { ok: true };
}

async function handleToolList(params) {
  const { pluginId } = params;
  if (!pluginId) throw new Error('pluginId is required');

  const entry = plugins.get(pluginId);
  if (!entry) throw new Error(`Plugin not loaded: ${pluginId}`);

  const tools = [...entry.tools.values()].map(t => ({
    name: t.name,
    description: t.description,
    parameters: t.parameters,
  }));

  return { ok: true, tools };
}

async function handleToolCall(params) {
  const { pluginId, tool: toolName, params: toolParams, context } = params;
  if (!pluginId) throw new Error('pluginId is required');
  if (!toolName) throw new Error('tool name is required');

  const entry = plugins.get(pluginId);
  if (!entry) throw new Error(`Plugin not loaded: ${pluginId}`);

  const tool = entry.tools.get(toolName);
  if (!tool) throw new Error(`Tool not found: ${toolName}`);
  if (!tool.execute) throw new Error(`Tool ${toolName} has no execute function`);

  let result;
  try {
    result = await tool.execute(toolParams || {}, context || {});
  } catch (err) {
    notify('plugin.error', { pluginId, error: `Tool ${toolName} execution failed: ${err.message}` });
    throw new Error(`Tool execution failed: ${err.message}`);
  }
  return { ok: true, data: result };
}

async function handleChannelSend(params) {
  const { pluginId, chatId, content, opts } = params;
  if (!pluginId) throw new Error('pluginId is required');

  const entry = plugins.get(pluginId);
  if (!entry) throw new Error(`Plugin not loaded: ${pluginId}`);

  // Find channel with send capability
  for (const ch of entry.channels) {
    if (ch.send) {
      const result = await ch.send(chatId, content, opts || {});
      return { ok: true, data: result };
    }
  }

  throw new Error(`No sendable channel found in plugin ${pluginId}`);
}

// ============================================================================
// Main loop — read JSON-RPC from stdin
// ============================================================================

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

// Signal readiness to the Elixir NodeBridge
notify('host.ready', {});

rl.on('line', async (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;

  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    respondError(null, -32700, 'Parse error');
    return;
  }

  const { id, method, params } = msg;

  // Notifications (no id) — ignore silently
  if (id === undefined || id === null) return;

  try {
    let result;
    switch (method) {
      case 'plugin.load':
        result = await handlePluginLoad(params || {});
        break;
      case 'plugin.unload':
        result = await handlePluginUnload(params || {});
        break;
      case 'tool.list':
        result = await handleToolList(params || {});
        break;
      case 'tool.call':
        result = await handleToolCall(params || {});
        break;
      case 'channel.send':
        result = await handleChannelSend(params || {});
        break;
      case 'ping':
        result = { ok: true };
        break;
      default:
        respondError(id, -32601, `Method not found: ${method}`);
        return;
    }
    respond(id, result);
  } catch (err) {
    respondError(id, -32000, err.message || String(err));
  }
});

rl.on('close', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));

process.on('unhandledRejection', (reason) => {
  notify('plugin.error', {
    pluginId: 'host',
    error: `Unhandled rejection: ${reason}`,
  });
});
