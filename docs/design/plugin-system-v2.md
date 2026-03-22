# ClawdEx Plugin System V2 — 混合架构设计

## 目标

实现类似 OpenClaw 的插件系统：`clawd plugin install feishu` → 装好即用。

核心原则：
- **Elixir 插件**：原生 .beam 加载，性能最优，核心渠道/工具用这个
- **Node.js 插件**：通过 sidecar 进程 + JSON-RPC 协议桥接，兼容 OpenClaw 生态
- **统一接口**：上层代码不关心插件是 Elixir 还是 JS 实现的

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────┐
│                  ClawdEx Core                        │
│                                                      │
│  Tools.Registry ──── Plugins.Manager ──── Skills     │
│       │                    │                         │
│       │         ┌──────────┴──────────┐              │
│       │         │                     │              │
│  ┌────▼────┐  ┌─▼──────────┐  ┌──────▼──────────┐   │
│  │ Builtin │  │ Elixir     │  │ Node.js         │   │
│  │ Tools   │  │ Plugins    │  │ Plugin Bridge   │   │
│  │ (30个)  │  │ (.beam)    │  │ (Port/stdio)    │   │
│  └─────────┘  └────────────┘  └───────┬─────────┘   │
│                                       │              │
└───────────────────────────────────────┼──────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │  Node.js Sidecar   │
                              │  (plugin-host.mjs) │
                              │                    │
                              │  ┌──────┐ ┌──────┐ │
                              │  │feishu│ │slack │ │
                              │  └──────┘ └──────┘ │
                              └────────────────────┘
```

---

## 2. 插件目录结构

```
~/.clawd/
├── plugins/
│   ├── registry.json              # 已安装插件清单
│   │
│   ├── feishu/                    # Node.js 插件
│   │   ├── plugin.json            # 统一元数据
│   │   ├── package.json           # npm 包信息
│   │   ├── node_modules/          # JS 依赖
│   │   ├── index.js               # JS 入口
│   │   └── skills/                # 技能文件
│   │       └── feishu-doc/
│   │           └── SKILL.md
│   │
│   └── custom-tools/              # Elixir 插件
│       ├── plugin.json
│       └── beams/                 # 预编译 .beam 文件
│           ├── Elixir.ClawdEx.Plugins.CustomTools.beam
│           └── ...
│
├── skills/                        # 独立 skills（现有）
└── workspace/
```

### plugin.json（统一元数据格式）

```json
{
  "id": "feishu",
  "name": "Feishu/Lark",
  "version": "2026.3.8",
  "description": "飞书集成 - 文档、多维表格、日历、IM",
  "runtime": "node",
  "entry": "./index.js",

  "provides": {
    "channels": ["feishu"],
    "tools": ["feishu_doc", "feishu_bitable", "feishu_calendar"],
    "skills": ["./skills"],
    "providers": [],
    "hooks": ["before_tool_call", "after_tool_call"]
  },

  "config_schema": {
    "app_id": { "type": "string", "required": true, "label": "飞书 App ID" },
    "app_secret": { "type": "string", "required": true, "sensitive": true }
  },

  "dependencies": {
    "clawd_ex": ">=0.5.0"
  }
}
```

对 Elixir 插件，`runtime` 为 `"beam"`，`entry` 为模块名：

```json
{
  "id": "custom-analytics",
  "runtime": "beam",
  "entry": "Elixir.ClawdEx.Plugins.Analytics",
  "provides": {
    "tools": ["analytics_query", "analytics_report"]
  }
}
```

---

## 3. Elixir 侧核心模块

### 3.1 Plugin Behaviour (扩展现有)

```elixir
defmodule ClawdEx.Plugins.Plugin do
  @moduledoc """
  Plugin behaviour — 所有插件（包括 Node 桥接）的统一接口
  """

  @type capability :: :tools | :channels | :providers | :hooks | :skills
  @type plugin_type :: :beam | :node

  @callback name() :: String.t()
  @callback version() :: String.t()
  @callback description() :: String.t()
  @callback plugin_type() :: plugin_type()
  @callback capabilities() :: [capability()]
  @callback init(config :: map()) :: {:ok, state :: any()} | {:error, reason :: any()}
  @callback stop(state :: any()) :: :ok

  # 可选回调
  @callback tools() :: [tool_spec()]
  @callback channels() :: [channel_spec()]
  @callback providers() :: [provider_spec()]
  @callback hooks() :: [hook_spec()]
  @callback handle_tool_call(tool_name :: String.t(), params :: map(), context :: map()) ::
              {:ok, any()} | {:error, any()}

  @optional_callbacks [
    tools: 0, channels: 0, providers: 0, hooks: 0,
    handle_tool_call: 3, stop: 1
  ]
end
```

### 3.2 Plugin Manager (重写)

```elixir
defmodule ClawdEx.Plugins.Manager do
  @moduledoc """
  插件生命周期管理器

  启动时：
  1. 读取 ~/.clawd/plugins/registry.json
  2. 加载 Elixir 插件（add_pathz + Code.ensure_loaded）
  3. 启动 Node.js sidecar（如有 Node 插件）
  4. 初始化所有插件
  5. 注册 tools/channels/providers 到各 Registry
  """

  use GenServer

  def start_link(opts), do: ...

  # 动态安装/卸载（运行时）
  def install_plugin(source, opts \\ []), do: ...
  def uninstall_plugin(plugin_id), do: ...
  def enable_plugin(plugin_id), do: ...
  def disable_plugin(plugin_id), do: ...

  # 查询
  def list_plugins(), do: ...
  def get_plugin(id), do: ...
  def get_all_tools(), do: ...
  def get_all_channels(), do: ...
end
```

### 3.3 Node Plugin Bridge

核心适配层 — 管理 Node.js sidecar 进程，通过 JSON-RPC 通信：

```elixir
defmodule ClawdEx.Plugins.NodeBridge do
  @moduledoc """
  Node.js 插件桥接器

  启动一个 Node.js 子进程 (plugin-host.mjs)，
  通过 stdin/stdout JSON-RPC 协议与之通信。

  所有 Node 插件共享一个 sidecar 进程（进程内隔离）。
  """

  use GenServer

  # 生命周期
  def start_link(opts), do: ...
  def load_plugin(plugin_dir, config), do: ...
  def unload_plugin(plugin_id), do: ...

  # 工具调用
  def call_tool(plugin_id, tool_name, params, context), do: ...

  # 渠道操作
  def send_message(plugin_id, channel_id, content, opts), do: ...
  def start_channel(plugin_id, config), do: ...

  # 内部：Port 通信
  defp send_rpc(state, method, params), do: ...
  defp handle_rpc_response(state, response), do: ...
end
```

### 3.4 Node Plugin Adapter

让 Node 插件「看起来」和 Elixir 插件一样：

```elixir
defmodule ClawdEx.Plugins.NodeAdapter do
  @moduledoc """
  将 Node.js 插件包装为标准 Plugin behaviour。

  Tools.Registry 和 Channels.Registry 不需要知道
  底层是 Elixir 还是 Node.js — 全都是 Plugin。
  """

  @behaviour ClawdEx.Plugins.Plugin

  defstruct [:plugin_id, :plugin_json, :bridge_pid]

  @impl true
  def plugin_type, do: :node

  @impl true
  def handle_tool_call(tool_name, params, context) do
    ClawdEx.Plugins.NodeBridge.call_tool(@plugin_id, tool_name, params, context)
  end

  # ... 其他回调委托给 NodeBridge
end
```

### 3.5 Channel Registry (新增)

替代 ChannelDispatcher 中的硬编码分支：

```elixir
defmodule ClawdEx.Channels.Registry do
  @moduledoc """
  动态渠道注册表

  内置渠道（Telegram、Discord）启动时自动注册。
  插件提供的渠道通过 Plugins.Manager 注册。
  """

  use GenServer

  def register(channel_id, module_or_adapter), do: ...
  def unregister(channel_id), do: ...
  def get(channel_id), do: ...
  def list(), do: ...
  def send_message(channel_id, chat_id, content, opts), do: ...
end
```

---

## 4. JSON-RPC 协议

Elixir ↔ Node.js sidecar 通过 stdin/stdout 通信，每行一个 JSON 对象。

### 4.1 请求（Elixir → Node）

```json
{"jsonrpc":"2.0","id":1,"method":"plugin.load","params":{"pluginDir":"/path/to/feishu","config":{"app_id":"xxx"}}}
{"jsonrpc":"2.0","id":2,"method":"tool.call","params":{"pluginId":"feishu","tool":"feishu_doc","params":{"action":"read","doc_token":"xxx"},"context":{"sessionKey":"..."}}}
{"jsonrpc":"2.0","id":3,"method":"channel.send","params":{"pluginId":"feishu","chatId":"oc_xxx","content":"Hello","opts":{}}}
{"jsonrpc":"2.0","id":4,"method":"channel.start_polling","params":{"pluginId":"feishu"}}
{"jsonrpc":"2.0","id":5,"method":"plugin.unload","params":{"pluginId":"feishu"}}
```

### 4.2 响应（Node → Elixir）

```json
{"jsonrpc":"2.0","id":1,"result":{"ok":true,"tools":["feishu_doc","feishu_bitable"],"channels":["feishu"]}}
{"jsonrpc":"2.0","id":2,"result":{"ok":true,"data":{"content":"# 文档标题\n..."}}}
{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Permission denied"}}
```

### 4.3 通知（Node → Elixir，无 id）

```json
{"jsonrpc":"2.0","method":"channel.message","params":{"pluginId":"feishu","message":{"chatId":"oc_xxx","content":"你好","senderId":"ou_xxx","senderName":"张三"}}}
{"jsonrpc":"2.0","method":"plugin.log","params":{"pluginId":"feishu","level":"info","message":"Connected to Feishu API"}}
{"jsonrpc":"2.0","method":"hook.emit","params":{"pluginId":"feishu","hook":"after_tool_call","event":{"toolName":"feishu_doc","durationMs":230}}}
```

### 4.4 核心方法清单

| 方向 | 方法 | 说明 |
|------|------|------|
| → Node | `plugin.load` | 加载插件，返回 capabilities |
| → Node | `plugin.unload` | 卸载插件 |
| → Node | `plugin.config` | 更新插件配置 |
| → Node | `tool.list` | 列出插件的工具定义（name, description, parameters） |
| → Node | `tool.call` | 调用工具 |
| → Node | `channel.send` | 发送消息 |
| → Node | `channel.start` | 启动渠道（开始监听） |
| → Node | `channel.stop` | 停止渠道 |
| ← Elixir | `channel.message` | 收到新消息 |
| ← Elixir | `plugin.log` | 日志输出 |
| ← Elixir | `hook.emit` | 触发钩子事件 |
| ← Elixir | `plugin.error` | 插件运行时错误 |

---

## 5. Node.js Sidecar (plugin-host.mjs)

ClawdEx 自带的 Node.js 脚本，负责在单个进程中加载多个 JS 插件：

```javascript
// priv/plugin-host/plugin-host.mjs
import { createInterface } from 'readline';

const plugins = new Map();

const rl = createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  const req = JSON.parse(line);
  try {
    const result = await handleRequest(req);
    respond(req.id, result);
  } catch (err) {
    respondError(req.id, err.message);
  }
});

async function handleRequest(req) {
  switch (req.method) {
    case 'plugin.load':
      return await loadPlugin(req.params);
    case 'tool.call':
      return await callTool(req.params);
    case 'tool.list':
      return await listTools(req.params);
    case 'channel.send':
      return await channelSend(req.params);
    // ...
  }
}

async function loadPlugin({ pluginDir, config }) {
  const mod = await import(`${pluginDir}/index.js`);
  const plugin = mod.default || mod;

  // 构建简化版的 Plugin API（模拟 OpenClaw 的 api 对象）
  const api = createPluginApi(plugin.id || path.basename(pluginDir), config);

  if (plugin.register) {
    await plugin.register(api);
  }

  plugins.set(api.id, { plugin, api, tools: api._tools, channels: api._channels });

  return {
    ok: true,
    tools: api._tools.map(t => ({
      name: t.name,
      description: t.description,
      parameters: t.parameters
    })),
    channels: api._channels.map(c => c.id)
  };
}

function createPluginApi(id, config) {
  const api = {
    id,
    name: id,
    config,
    pluginConfig: config,
    _tools: [],
    _channels: [],
    _hooks: [],
    runtime: createMinimalRuntime(),
    logger: {
      info: (msg) => notify('plugin.log', { pluginId: id, level: 'info', message: msg }),
      warn: (msg) => notify('plugin.log', { pluginId: id, level: 'warn', message: msg }),
      error: (msg) => notify('plugin.log', { pluginId: id, level: 'error', message: msg }),
    },
    registerTool: (tool, opts) => { api._tools.push(normalizeTool(tool, opts)); },
    registerChannel: (reg) => { api._channels.push(reg.plugin || reg); },
    registerHook: () => {},  // TODO: Phase 2
    registerProvider: () => {},  // TODO
    registerCli: () => {},
    registerService: () => {},
    registerCommand: () => {},
    registerHttpRoute: () => {},
    registerGatewayMethod: () => {},
    registerContextEngine: () => {},
    resolvePath: (p) => p,
    on: (hook, handler) => { api._hooks.push({ hook, handler }); },
  };
  return api;
}

function respond(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
}

function respondError(id, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message } }) + '\n');
}

function notify(method, params) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
}
```

关键点：`createPluginApi` 模拟了 OpenClaw 的 `OpenClawPluginApi` 接口，
让已有的 OpenClaw JS 插件 **不用改代码** 就能在 ClawdEx 里加载。

---

## 6. 安装流程

### CLI 命令

```bash
# 从 npm 安装
clawd plugin install @larksuiteoapi/feishu-openclaw-plugin

# 从 Git 仓库安装
clawd plugin install https://github.com/user/clawd-plugin-xxx

# 从本地目录安装
clawd plugin install ./my-plugin

# 管理
clawd plugin list
clawd plugin config feishu
clawd plugin enable feishu
clawd plugin disable feishu
clawd plugin remove feishu
```

### install 流程

```
clawd plugin install @larksuiteoapi/feishu-openclaw-plugin
  │
  ├── 1. mkdir ~/.clawd/plugins/feishu/
  ├── 2. npm install --prefix ~/.clawd/plugins/feishu/ @larksuiteoapi/feishu-openclaw-plugin
  ├── 3. 读取 package.json + openclaw.plugin.json
  ├── 4. 生成标准 plugin.json
  ├── 5. 复制 skills/ 到 ~/.clawd/skills/feishu-*（或在 plugin.json 中引用）
  ├── 6. 更新 ~/.clawd/plugins/registry.json
  └── 7. 通知 Plugins.Manager 热加载（如果运行中）
```

### registry.json

```json
{
  "version": 1,
  "plugins": {
    "feishu": {
      "id": "feishu",
      "version": "2026.3.8",
      "runtime": "node",
      "path": "~/.clawd/plugins/feishu",
      "enabled": true,
      "installed_at": "2026-03-20T14:00:00Z",
      "config": {
        "app_id": "cli_xxx",
        "app_secret": "encrypted:xxx"
      }
    }
  }
}
```

---

## 7. 实现阶段

### Phase 1 — 核心框架（2-3 天）

- [ ] **Plugin behaviour 扩展** — 加 `plugin_type/0`, `capabilities/0`, `channels/0`, `handle_tool_call/3`
- [ ] **Channels.Registry** — 新增动态渠道注册表，ChannelDispatcher 改为查 Registry
- [ ] **registry.json 读写** — `ClawdEx.Plugins.Store` 模块
- [ ] **Elixir 动态插件加载** — `add_pathz` + `Code.ensure_loaded` 从 plugins/*/beams/

### Phase 2 — Node.js Bridge（3-4 天）

- [ ] **plugin-host.mjs** — Node sidecar 脚本，模拟 OpenClaw Plugin API
- [ ] **NodeBridge GenServer** — Elixir 侧 Port 管理 + JSON-RPC 通信
- [ ] **NodeAdapter** — 把 Node 插件包装为标准 Plugin behaviour
- [ ] **工具调用链路** — Tools.Registry → NodeAdapter → NodeBridge → plugin-host → JS 插件
- [ ] **渠道消息链路** — NodeBridge 收到 `channel.message` 通知 → 路由到 SessionManager

### Phase 3 — CLI 安装（2 天）

- [ ] **`clawd plugin install`** — npm install + 元数据提取 + registry 更新
- [ ] **`clawd plugin list/config/remove`** — 管理命令
- [ ] **热加载** — 运行时安装后自动加载，不需重启

### Phase 4 — 兼容性验证（1-2 天）

- [ ] 用飞书插件 `@larksuiteoapi/feishu-openclaw-plugin` 做端到端测试
- [ ] 验证 tools 注册和调用
- [ ] 验证 channel 消息收发
- [ ] 验证 skills 加载

### Phase 5 — 现有模块插件化（持续）

- [ ] 把 Telegram 从硬编码改为内置 Elixir 插件
- [ ] 把 Discord 从硬编码改为内置 Elixir 插件
- [ ] AI Providers 支持插件注册
- [ ] 把部分核心 Tools 标记为可替换

---

## 8. 关键设计决策

### Q: Node.js sidecar 是一个进程还是每个插件一个？

**一个进程，进程内隔离。** 原因：
- 减少进程开销
- 共享 Node.js runtime 内存
- OpenClaw 也是单进程加载所有插件
- 如果单个插件崩溃，catch 住不影响其他

### Q: 如何处理 OpenClaw 插件依赖 OpenClaw runtime API？

plugin-host.mjs 中 `createPluginApi` 提供兼容层，模拟 OpenClaw 的 runtime：
- `runtime.config` → 简化版配置读写
- `runtime.media` → 代理回 Elixir 侧处理
- `runtime.subagent` → 代理回 ClawdEx 的 session 系统
- 不支持的 API → 返回 noop 或 warning

不追求 100% 兼容，先支持 tools + channels + skills，
hooks 和高级功能后续按需加。

### Q: 插件配置中的 secret 怎么存？

registry.json 中 `encrypted:xxx` 前缀标记加密字段。
使用 `ClawdEx.Security.encrypt/decrypt` 处理。
展示时脱敏 `cli_a••••••4f`。

### Q: 性能影响？

- Elixir 插件：零开销，原生调用
- Node 插件：每次 tool call 约 1-5ms IPC 开销（JSON 序列化 + stdio）
- 对比 HTTP API 调用（飞书 API ~100-500ms），IPC 开销可忽略

---

## 9. 与现有代码的改动范围

| 文件 | 改动 |
|------|------|
| `plugins/plugin.ex` | 扩展 behaviour |
| `plugins/manager.ex` | 重写，支持 registry.json + 动态加载 |
| `plugins/supervisor.ex` | 加入 NodeBridge |
| `channels/channel_dispatcher.ex` | 查 Channels.Registry 而非硬编码 |
| `tools/registry.ex` | 已支持 plugin tools，小调整 |
| `skills/loader.ex` | 加插件 skills 目录扫描 |
| `application.ex` | Telegram/Discord supervisor 改为条件启动 |
| **新增** `plugins/node_bridge.ex` | Node.js sidecar 管理 |
| **新增** `plugins/node_adapter.ex` | Node → Plugin 适配器 |
| **新增** `plugins/store.ex` | registry.json 读写 |
| **新增** `channels/registry.ex` | 动态渠道注册 |
| **新增** `cli/plugin_commands.ex` | CLI 命令 |
| **新增** `priv/plugin-host/plugin-host.mjs` | Node sidecar |
