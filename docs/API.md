# ClawdEx API 文档

ClawdEx 是一个使用 Elixir Phoenix 构建的 AI 助手框架，提供 Web UI、WebSocket 通信和 CLI 接口。

## 概述

### 架构概览
- **Web UI**: Phoenix LiveView 驱动的响应式界面
- **WebSocket**: 实时双向通信，支持流式响应
- **CLI**: 独立可执行文件，支持批处理和自动化
- **多渠道支持**: Discord, Telegram, HTTP Webhook
- **AI 提供商**: OpenRouter, Ollama, Groq
- **工具系统**: 50+ 内置工具，支持自定义扩展

### 核心组件
```
User Interface (LiveView/CLI)
          ↓
Session Manager (状态管理)
          ↓
Agent Loop (状态机: idle → preparing → inferring → executing → ...)
          ↓
AI Provider + Tool Registry
```

## WebSocket API

ClawdEx 使用 Phoenix PubSub 实现实时通信，支持以下消息类型：

### 连接
LiveView 自动建立 WebSocket 连接，订阅相关频道：

```elixir
# 自动订阅会话频道
PubSub.subscribe(ClawdEx.PubSub, "session:#{session_key}")

# 自动订阅代理频道  
PubSub.subscribe(ClawdEx.PubSub, "agent:#{agent_id}")
```

### 消息格式

#### 代理响应
```elixir
%{
  type: :agent_result,
  session_key: "user:123:discord:456",
  result: %{
    content: "助手回复内容",
    tool_calls: [],
    tokens_in: 150,
    tokens_out: 45,
    stop_reason: "stop"
  }
}
```

#### 流式消息块
```elixir
%{
  type: :ai_chunk,
  session_key: "user:123:discord:456", 
  chunk: %{
    content: "部分",
    accumulated: "完整内容部分"
  }
}
```

#### 工具执行状态
```elixir
%{
  type: :tool_execution,
  session_key: "user:123:discord:456",
  tool: "web_search",
  status: :completed,
  result: %{...}
}
```

## LiveView Pages

### Dashboard (`/`)
- **功能**: 系统概览和统计
- **实时数据**: 会话数量、代理状态、系统健康度
- **组件**: 状态卡片、最近活动、快速操作

### Chat (`/chat`)
- **功能**: 主要聊天界面
- **特性**: 
  - 实时消息流
  - Markdown 渲染
  - 工具调用可视化
  - 流式响应
- **WebSocket**: 订阅 `session:current` 频道

### Sessions (`/sessions`)
- **功能**: 会话管理和历史
- **路由**:
  - `/sessions` - 会话列表
  - `/sessions/:id` - 会话详情和消息历史
- **操作**: 查看、删除、导出会话

### Agents (`/agents`)
- **功能**: 代理管理
- **路由**:
  - `/agents` - 代理列表
  - `/agents/new` - 创建新代理
  - `/agents/:id/edit` - 编辑代理配置
- **配置**: 模型选择、系统提示、工具权限

### Skills (`/skills`)
- **功能**: 技能管理和监控
- **特性**: 技能列表、热重载状态、YAML 配置预览

### Tasks (`/tasks`)
- **功能**: 任务管理
- **路由**:
  - `/tasks` - 任务列表
  - `/tasks/:id` - 任务详情和执行状态
- **状态**: pending, running, completed, failed

### A2A Communication (`/a2a`)
- **功能**: 代理间通信监控
- **特性**: 消息路由可视化、通信日志、调试工具

### Cron Jobs (`/cron`)
- **功能**: 定时任务管理
- **路由**:
  - `/cron` - 任务列表和调度状态
  - `/cron/new` - 创建新任务
  - `/cron/:id` - 任务详情
  - `/cron/:id/edit` - 编辑任务
- **调度器**: 支持 cron 表达式

### Webhooks (`/webhooks`)
- **功能**: Webhook 配置和日志
- **端点**: `/api/webhooks/inbound` (POST)

### Logs (`/logs`)
- **功能**: 系统日志查看器
- **过滤**: 按级别、时间、组件筛选

### Settings (`/settings`)
- **功能**: 全局配置管理
- **设置**: AI 提供商、渠道配置、系统参数

## CLI Commands

ClawdEx 提供统一的 CLI 接口 `clawd_ex`：

### 系统管理

```bash
# 显示应用状态
clawd_ex status [--verbose] [--format json]

# 健康检查
clawd_ex health [--verbose]

# 交互式配置向导
clawd_ex configure

# 启动应用
clawd_ex start

# 停止应用  
clawd_ex stop

# 显示版本
clawd_ex version
```

### 会话管理

```bash
# 列出会话
clawd_ex sessions list [--limit N] [--format json]

# 查看会话历史
clawd_ex sessions history <session_key> [--limit N]
```

### 代理管理

```bash
# 列出代理
clawd_ex agents list [--format json]

# 创建新代理
clawd_ex agents add <name> [--model <model>] [--system-prompt <prompt>]
```

### 定时任务

```bash
# 列出 cron 任务
clawd_ex cron list [--format json]

# 手动触发任务
clawd_ex cron run <job_id>
```

### CLI 选项

- `--help, -h`: 显示帮助信息
- `--verbose, -v`: 启用详细输出
- `--format, -f`: 输出格式 (text, json)
- `--limit, -l`: 限制结果数量

## AI Providers

### OpenRouter
- **模型**: 支持所有 OpenRouter 模型路由
- **配置**: `OPENROUTER_API_KEY` 环境变量
- **特性**: 
  - 流式和非流式响应
  - 工具调用支持
  - 自动模型选择 (`openrouter/auto`)

```elixir
# 环境变量
export OPENROUTER_API_KEY="sk-or-v1-..."

# 支持的模型示例
"anthropic/claude-3-opus"
"openai/gpt-4-turbo"  
"openrouter/auto"
```

### Ollama
- **本地部署**: 支持本地 Ollama 实例
- **配置**: `OLLAMA_URL` (默认 `http://localhost:11434`)
- **模型**: 支持所有 Ollama 兼容模型

```elixir
# 环境变量
export OLLAMA_URL="http://localhost:11434"

# 示例模型
"llama3:8b"
"mistral:7b"
"codellama:13b"
```

### Groq  
- **高速推理**: 专为高吞吐量优化
- **配置**: `GROQ_API_KEY` 环境变量
- **模型**: Groq 支持的模型列表

```elixir
# 环境变量
export GROQ_API_KEY="gsk_..."

# 支持的模型示例
"llama3-8b-8192"
"mixtral-8x7b-32768"
"gemma-7b-it"
```

## 工具系统

ClawdEx 包含丰富的工具库，提供文件操作、网络请求、系统集成等功能：

### 核心工具

#### 文件操作
- `read` - 读取文件内容
- `write` - 写入文件
- `edit` - 精确编辑文件

#### 系统执行
- `exec` - 执行 shell 命令
- `process` - 管理后台进程

#### 网络工具
- `web_search` - 网络搜索
- `web_fetch` - 网页内容获取
- `browser` - 浏览器自动化

#### 会话管理
- `sessions_list` - 列出会话
- `sessions_history` - 会话历史
- `sessions_send` - 跨会话消息
- `sessions_spawn` - 生成子代理

#### 代理系统
- `agents_list` - 代理列表
- `session_status` - 会话状态

#### 自动化
- `cron` - 定时任务管理
- `gateway` - 网关控制
- `message` - 多渠道消息

#### 多媒体
- `tts` - 文字转语音
- `image` - 图像处理
- `canvas` - 画布操作

#### 系统工具
- `compact` - 内存压缩
- `memory_tool` - 内存管理

### 工具注册

```elixir
# 工具注册示例
defmodule ClawdEx.Tools.Registry do
  @tools [
    %{name: "read", module: ClawdEx.Tools.Read},
    %{name: "write", module: ClawdEx.Tools.Write},
    %{name: "exec", module: ClawdEx.Tools.Exec},
    # ... 更多工具
  ]
end
```

### 工具调用格式

```elixir
%{
  "name" => "web_search",
  "input" => %{
    "query" => "Elixir Phoenix LiveView tutorial",
    "limit" => 5
  }
}
```

---

## 开发接入

### 自定义工具开发

```elixir
defmodule MyApp.Tools.CustomTool do
  @behaviour ClawdEx.Tools.Tool
  
  def call(%{"param" => value}, _context) do
    # 工具逻辑
    {:ok, "结果"}
  end
  
  def schema do
    %{
      name: "custom_tool",
      description: "自定义工具描述",
      input_schema: %{
        type: "object",
        properties: %{
          param: %{type: "string", description: "参数描述"}
        },
        required: ["param"]
      }
    }
  end
end
```

### 自定义 AI 提供商

```elixir  
defmodule MyApp.AI.Providers.CustomProvider do
  @behaviour ClawdEx.AI.Provider
  
  def chat(model, messages, opts \\ []) do
    # 实现聊天接口
  end
  
  def stream(model, messages, opts \\ []) do
    # 实现流式接口
  end
end
```

---

*此文档对应 ClawdEx v0.4.0。如需更新或有疑问，请参考源码或提交 Issue。*