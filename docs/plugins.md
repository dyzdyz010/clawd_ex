# Plugin System V2

ClawdEx 支持双运行时插件架构，既能运行原生 Elixir 插件（高性能），也能兼容 Node.js 插件（生态丰富）。

## 概述

### 插件类型

| 类型 | 运行时 | 性能 | 生态 | 适用场景 |
|------|--------|------|------|----------|
| **Elixir 插件** | BEAM VM | 🚀 极高 | 较小 | 核心渠道、系统工具 |
| **Node.js 插件** | JSON-RPC 桥接 | ⚡ 优秀 | 🌟 丰富 | OpenClaw 生态、第三方服务 |

### 架构设计

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
│  │ (22个)  │  │ (.beam)    │  │ (Port/stdio)    │   │
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

**统一接口** — 无论 Elixir 还是 Node.js 插件，对 ClawdEx 核心都是标准的 `Plugin` behaviour，上层代码无需区分。

---

## 快速开始

### 安装 Node.js 插件

```bash
# 从 npm 安装飞书插件
clawd plugins install @larksuiteoapi/feishu-openclaw-plugin

# 配置 API 凭证
clawd plugins config feishu

# 查看可用工具
clawd plugins info feishu

# 启用插件
clawd plugins enable feishu
```

### 安装 Elixir 插件

```bash
# 从 Git 安装自定义 Elixir 插件
clawd plugins install https://github.com/user/clawd-analytics-plugin

# 本地开发插件
clawd plugins install ./my-elixir-plugin
```

### 使用插件工具

插件安装后，其提供的工具会自动在 Agent 对话中可用：

```
Human: 帮我在飞书创建一个项目文档
Assistant: 我来为你创建飞书文档。

[使用 feishu_doc 工具创建文档]

已创建项目文档，链接：https://feishu.cn/docx/...
```

---

## CLI 命令

### 插件管理

```bash
# 列出所有插件
clawd plugins list
# ┌────────────┬─────────┬──────────┬──────────┬─────────────────┐
# │ Plugin ID  │ Version │ Runtime  │ Status   │ Tools           │
# ├────────────┼─────────┼──────────┼──────────┼─────────────────┤
# │ feishu     │ 2026.3.8│ node     │ enabled  │ 8 tools         │
# │ analytics  │ 1.0.0   │ beam     │ enabled  │ 3 tools         │
# └────────────┴─────────┴──────────┴──────────┴─────────────────┘

# 查看插件详情
clawd plugins info feishu
# Plugin: Feishu/Lark Integration
# Version: 2026.3.8
# Runtime: Node.js
# Tools: feishu_doc, feishu_bitable, feishu_calendar, feishu_im, ...
# Channels: feishu
# Skills: feishu-doc, feishu-bitable, feishu-calendar

# 插件诊断
clawd plugins doctor
# ✓ Node.js runtime available (v20.11.0)
# ✓ Plugin host sidecar running
# ✓ feishu: loaded, 8 tools registered
# ✗ analytics: failed to load - missing dependency
```

### 安装与卸载

```bash
# 从 npm 安装
clawd plugins install @scope/plugin-name
clawd plugins install @larksuiteoapi/feishu-openclaw-plugin

# 从 Git 安装
clawd plugins install https://github.com/user/plugin-repo
clawd plugins install git@github.com:user/plugin-repo.git

# 本地安装
clawd plugins install ./path/to/plugin
clawd plugins install /absolute/path/to/plugin

# 指定版本
clawd plugins install plugin-name@1.2.3

# 卸载插件
clawd plugins uninstall feishu
```

### 配置管理

```bash
# 配置插件（交互式）
clawd plugins config feishu

# 启用/禁用插件
clawd plugins enable feishu
clawd plugins disable feishu

# 更新配置文件
# 编辑 ~/.clawd/plugins/registry.json
nano ~/.clawd/plugins/registry.json
```

---

## 配置说明

### Registry 文件

插件注册表位于 `~/.clawd/plugins/registry.json`：

```json
{
  "version": 1,
  "plugins": {
    "feishu": {
      "id": "feishu",
      "name": "Feishu/Lark",
      "version": "2026.3.8",
      "runtime": "node",
      "entry": "./index.js",
      "path": "~/.clawd/plugins/feishu",
      "enabled": true,
      "installed_at": "2026-03-20T14:00:00Z",
      "source": "npm:@larksuiteoapi/feishu-openclaw-plugin",
      "config": {
        "app_id": "cli_xxx",
        "app_secret": "encrypted:xxx"
      },
      "provides": {
        "tools": ["feishu_doc", "feishu_bitable"],
        "channels": ["feishu"],
        "skills": ["./skills"]
      }
    }
  }
}
```

### 插件目录结构

```
~/.clawd/plugins/
├── registry.json              # 插件注册表
│
├── feishu/                     # Node.js 插件
│   ├── plugin.json             # 插件元数据
│   ├── package.json            # npm 包信息
│   ├── node_modules/           # JS 依赖
│   ├── index.js                # JS 入口
│   └── skills/                 # 技能文件
│       └── feishu-doc/
│           └── SKILL.md
│
└── analytics/                  # Elixir 插件
    ├── plugin.json
    └── beams/                  # 预编译 .beam 文件
        ├── Elixir.ClawdEx.Plugins.Analytics.beam
        └── ...
```

### 密钥管理

配置中的敏感信息使用 `encrypted:` 前缀加密存储：

```json
{
  "config": {
    "app_id": "cli_a1b2c3d4e5f6",
    "app_secret": "encrypted:AES256:base64encodeddata",
    "webhook_url": "https://api.example.com/hook"
  }
}
```

查看时自动脱敏：`cli_a••••••f6`

---

## 编写 Elixir 插件

### Plugin Behaviour

所有 Elixir 插件必须实现 `ClawdEx.Plugins.Plugin` behaviour：

```elixir
defmodule MyCompany.Analytics do
  @behaviour ClawdEx.Plugins.Plugin

  # 必需回调
  @impl true
  def id, do: "analytics"

  @impl true
  def name, do: "Analytics Plugin"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def description, do: "Data analytics and reporting tools"

  @impl true
  def plugin_type, do: :beam

  @impl true
  def capabilities, do: [:tools]

  @impl true
  def init(config) do
    # 初始化插件状态
    state = %{config: config, connection: nil}
    {:ok, state}
  end

  # 可选回调
  @impl true
  def tools do
    [
      %{
        name: "analytics_query",
        description: "Query analytics data",
        parameters: %{
          type: "object",
          properties: %{
            metric: %{type: "string", description: "Metric to query"},
            date_range: %{type: "string", description: "Date range"}
          },
          required: ["metric"]
        }
      }
    ]
  end

  @impl true
  def handle_tool_call("analytics_query", params, context) do
    # 实现工具逻辑
    metric = params["metric"]
    case query_analytics(metric) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp query_analytics(metric) do
    # 查询逻辑
    {:ok, %{metric: metric, value: 42}}
  end
end
```

### plugin.json

```json
{
  "id": "analytics",
  "name": "Analytics Plugin",
  "version": "1.0.0",
  "description": "Data analytics and reporting tools",
  "runtime": "beam",
  "entry": "Elixir.MyCompany.Analytics",
  "provides": {
    "tools": ["analytics_query", "analytics_report"],
    "channels": [],
    "skills": []
  },
  "config_schema": {
    "database_url": {
      "type": "string",
      "required": true,
      "label": "Database Connection URL"
    }
  }
}
```

### 渠道插件示例

```elixir
defmodule MyCompany.SlackChannel do
  @behaviour ClawdEx.Plugins.Plugin

  @impl true
  def capabilities, do: [:channels]

  @impl true
  def channels do
    [
      %{
        id: "slack",
        label: "Slack",
        module: MyCompany.SlackChannel.Handler
      }
    ]
  end
end

defmodule MyCompany.SlackChannel.Handler do
  use GenServer

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def send_message(chat_id, content, opts \\ []) do
    GenServer.call(__MODULE__, {:send_message, chat_id, content, opts})
  end

  def init(config) do
    {:ok, %{token: config["token"]}}
  end

  def handle_call({:send_message, chat_id, content, _opts}, _from, state) do
    # 发送消息到 Slack
    result = post_to_slack(state.token, chat_id, content)
    {:reply, result, state}
  end

  defp post_to_slack(token, channel, text) do
    # Slack API 调用
    {:ok, %{ts: "1234567890.123"}}
  end
end
```

---

## 编写 Node.js 插件

### OpenClaw 兼容 API

ClawdEx 的 Node.js 插件支持 OpenClaw 插件标准，现有插件无需修改：

```javascript
// index.js
export default function register(api) {
  // 注册工具
  api.registerTool({
    name: 'my_tool',
    description: 'My custom tool',
    parameters: {
      type: 'object',
      properties: {
        input: { type: 'string' }
      }
    },
    async execute(params, context) {
      return { result: `Processed: ${params.input}` };
    }
  });

  // 注册渠道
  api.registerChannel({
    id: 'my-channel',
    name: 'My Channel',
    async send(chatId, content, opts) {
      // 发送消息逻辑
      return { messageId: Date.now() };
    }
  });
}
```

### 工具注册

```javascript
// 简单工具
api.registerTool({
  name: 'weather_check',
  description: 'Check weather for a city',
  parameters: {
    type: 'object',
    properties: {
      city: { type: 'string', description: 'City name' }
    },
    required: ['city']
  },
  async execute(params) {
    const weather = await fetchWeather(params.city);
    return { temperature: weather.temp, condition: weather.desc };
  }
});

// 工具工厂（根据配置动态生成）
api.registerTool((context) => {
  if (!context.config.api_key) return null;
  
  return {
    name: 'premium_search',
    description: 'Premium search with API key',
    parameters: { /* ... */ },
    async execute(params) {
      return await searchWithApi(context.config.api_key, params.query);
    }
  };
});

// 批量注册
api.registerTool(() => [
  { name: 'tool1', /* ... */ },
  { name: 'tool2', /* ... */ }
]);
```

### 渠道注册

```javascript
api.registerChannel({
  id: 'webhook-channel',
  name: 'Webhook Channel',
  
  async send(chatId, content, opts) {
    const response = await fetch(chatId, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: content })
    });
    return { success: response.ok };
  },

  // 可选：开始监听消息
  async startPolling() {
    // 设置 webhook 监听或轮询
  }
});
```

### Hook 注册

```javascript
api.registerHook('before_tool_call', async (event) => {
  api.logger.info(`Calling tool: ${event.toolName}`);
  // 预处理逻辑
});

api.registerHook('after_tool_call', async (event) => {
  api.logger.info(`Tool ${event.toolName} completed in ${event.durationMs}ms`);
  // 后处理逻辑
});
```

### package.json 扩展

对于现有的 OpenClaw 插件，只需在 `package.json` 中添加：

```json
{
  "name": "@mycompany/clawd-plugin",
  "main": "./index.js",
  "openclaw": {
    "id": "my-plugin",
    "channels": ["my-channel"]
  }
}
```

ClawdEx 会自动生成标准的 `plugin.json`。

---

## 调试和日志

### 日志输出

**Elixir 插件**：
```elixir
require Logger
Logger.info("[MyPlugin] Processing request")
Logger.error("[MyPlugin] Failed: #{reason}")
```

**Node.js 插件**：
```javascript
api.logger.info('Processing request');
api.logger.error('Failed:', error.message);
api.logger.debug('Debug info:', data);
```

### 插件调试

```bash
# 启动时启用调试模式
CLAWD_DEBUG=true iex -S mix phx.server

# 查看插件日志
clawd logs --grep "Plugin"

# 测试插件加载
iex> ClawdEx.Plugins.Manager.reload()

# 手动调用工具
iex> ClawdEx.Tools.Registry.call_tool("feishu_doc", %{"action" => "list"}, %{})
```

### 常见问题

**Node.js 插件加载失败**：
1. 检查 Node.js 版本：`node --version`（需要 v16+）
2. 查看 plugin-host 日志：`tail -f ~/.clawd/logs/plugin-host.log`
3. 验证插件入口文件：`node -c ./path/to/plugin/index.js`

**Elixir 插件编译错误**：
1. 检查 .beam 文件路径
2. 验证模块名匹配
3. 确认依赖版本兼容

**工具调用超时**：
- Node.js 工具默认 30 秒超时
- 在插件配置中调整 `timeout` 参数

---

## 安全考虑

### 插件沙箱

- **Elixir 插件**：运行在 BEAM VM 中，进程隔离
- **Node.js 插件**：运行在独立的 Node.js 进程中，JSON-RPC 通信
- **文件系统**：插件只能访问自己的目录和配置的工作目录

### 权限管理

```json
{
  "config_schema": {
    "api_key": {
      "type": "string",
      "required": true,
      "sensitive": true,
      "label": "API Key"
    }
  },
  "permissions": {
    "network": ["api.example.com"],
    "filesystem": ["read", "write"],
    "tools": ["web_search", "file_read"]
  }
}
```

### 最佳实践

1. **最小权限原则** — 只申请必需的权限
2. **敏感数据加密** — 使用 `sensitive: true` 标记
3. **错误处理** — 优雅处理 API 失败和网络错误
4. **日志审计** — 记录重要操作，避免记录敏感信息

---

## 发布插件

### Elixir 插件发布

1. **编译 .beam 文件**：
   ```bash
   mix compile
   cp _build/prod/lib/*/ebin/*.beam ./beams/
   ```

2. **打包发布**：
   ```bash
   tar czf my-plugin.tar.gz plugin.json beams/ skills/
   ```

3. **安装**：
   ```bash
   clawd plugins install ./my-plugin.tar.gz
   ```

### Node.js 插件发布

1. **发布到 npm**：
   ```bash
   npm publish
   ```

2. **从 npm 安装**：
   ```bash
   clawd plugins install @mycompany/plugin-name
   ```

### 插件市场

未来将支持官方插件市场，开发者可以：
- 提交插件到市场审核
- 自动化测试和安全扫描
- 用户评分和反馈系统

---

## 故障排除

### 诊断命令

```bash
# 综合诊断
clawd plugins doctor

# 详细输出
clawd plugins doctor --verbose

# 单个插件诊断
clawd plugins info feishu --debug
```

### 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| Plugin not found | 插件未安装或路径错误 | 检查 `clawd plugins list` |
| Tool timeout | 工具执行时间过长 | 优化工具逻辑或调整超时 |
| Config error | 配置格式错误或缺少必需字段 | 使用 `clawd plugins config` 重新配置 |
| Permission denied | API 凭证错误或权限不足 | 验证 API Key 和权限设置 |
| Sidecar crashed | Node.js 进程崩溃 | 查看 plugin-host 日志，重启 ClawdEx |

### 获取帮助

1. **查看日志**：`clawd logs --level debug`
2. **社区支持**：GitHub Issues
3. **插件文档**：查看插件的 README 和示例
4. **开发指南**：参考 `docs/plugin-development.md`