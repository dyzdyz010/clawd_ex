# ClawdEx 项目状态

> 最后更新: 2026-01-31

## 概览

ClawdEx 是 [Clawdbot](https://github.com/clawdbot/clawdbot) 的 Elixir/Phoenix 实现。

| 指标 | 数值 |
|------|------|
| 版本 | v0.2.1 |
| 工具数量 | 21 |
| 测试用例 | 318 ✅ |
| AI 提供商 | 3 (Anthropic, OpenAI, Gemini) |
| 消息渠道 | 3 (Telegram, Discord, WebSocket) |
| 代码行数 | ~18,000 |

## 功能状态

### ✅ 已完成

#### 核心框架
- [x] Phoenix 应用骨架
- [x] PostgreSQL + pgvector 设置
- [x] Application supervision tree
- [x] 配置管理

#### AI 提供商
- [x] Anthropic Claude (Chat + Stream)
- [x] OpenAI GPT (Chat + Stream)
- [x] Google Gemini (Chat + Stream)
- [x] **OAuth Token 支持** (Anthropic)
  - [x] 自动 token 刷新
  - [x] Claude CLI 凭证加载
  - [x] Claude Code 兼容 headers

#### 工具系统 (21/23)
| 工具 | 状态 | 说明 |
|------|------|------|
| read | ✅ | 文件读取 |
| write | ✅ | 文件写入 |
| edit | ✅ | 文件编辑 |
| exec | ✅ | 命令执行 |
| process | ✅ | 进程管理 |
| memory_search | ✅ | 语义搜索 |
| memory_get | ✅ | 记忆检索 |
| web_search | ✅ | 网页搜索 |
| web_fetch | ✅ | 网页抓取 |
| sessions_list | ✅ | 会话列表 |
| sessions_history | ✅ | 会话历史 |
| sessions_send | ✅ | 跨会话消息 |
| sessions_spawn | ✅ | 子代理生成 |
| agents_list | ✅ | 代理列表 |
| session_status | ✅ | 会话状态 |
| cron | ✅ | 定时任务 |
| gateway | ✅ | 自管理 |
| message | ✅ | 多渠道消息 |
| browser | ✅ | 浏览器控制 |
| nodes | ✅ | 节点控制 |
| canvas | ✅ | 画布/A2UI |
| compact | ✅ | 会话压缩 |
| apply_patch | ⏳ | 多文件补丁 (低优先级) |
| image | ⏳ | 图像分析 (低优先级) |

#### 会话管理
- [x] SessionManager (DynamicSupervisor)
- [x] SessionWorker (GenServer)
- [x] 会话持久化 (Ecto)
- [x] AI 摘要压缩

#### Agent Loop
- [x] GenStateMachine 状态机
- [x] 状态: idle → preparing → inferring → executing_tools
- [x] 工具执行与结果反馈
- [x] 多轮对话支持

#### 记忆系统
- [x] pgvector 向量存储 (HNSW)
- [x] BM25 关键词搜索
- [x] 混合检索 (Hybrid Search)
- [x] 中文分词支持 (Jieba)
- [x] 文档分块 (Chunker)

#### 流式响应
- [x] SSE 流式处理
- [x] 智能分块
- [x] 代码块保护
- [x] 人性化延迟

#### 浏览器控制
- [x] Chrome DevTools Protocol
- [x] 页面导航 (navigate)
- [x] 页面快照 (snapshot - aria/ai)
- [x] 截图 (screenshot)
- [x] 交互动作 (act - click/type/press/hover/select/fill/drag/wait)
- [x] JS 执行 (evaluate)
- [x] 文件上传 (upload)
- [x] 对话框处理 (dialog)
- [x] 控制台日志 (console)

#### 节点系统
- [x] 节点注册表 (Registry)
- [x] 节点配对流程
- [x] 远程通知 (notify)
- [x] 远程执行 (run)
- [x] 摄像头控制 (camera_snap/list/clip)
- [x] 屏幕录制 (screen_record)
- [x] 位置获取 (location_get)

#### 渠道
- [x] Telegram (Telegex)
- [x] Discord (Nostrum)
- [x] WebSocket (Phoenix Channels)

### ⏳ 待完成 (低优先级)

- [ ] `apply_patch` 工具 - 多文件补丁应用
- [ ] `image` 工具 - 图像分析

## 测试覆盖

```
318 tests, 0 failures
Finished in 2.3 seconds
```

### 测试分布
- 工具测试: 15+ 文件
- AI 测试: oauth_test, chat_test, stream_test
- 浏览器测试: server_test, cdp_test
- 节点测试: registry_test
- 会话测试: session_worker_test, compaction_test

## 依赖

### 核心
- Phoenix 1.8
- Ecto 3.13 + Postgrex
- pgvector 0.3

### AI
- Req 0.5 (HTTP client)
- Jason (JSON)

### 渠道
- Telegex (Telegram)
- Nostrum (Discord)

### 工具
- Floki (HTML parsing)
- Jieba (中文分词)

## 运行环境

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 14+ with pgvector
- Chrome/Chromium (optional)

## 文件结构

```
lib/clawd_ex/
├── agent/           # Agent Loop
│   └── loop.ex      # GenStateMachine
├── ai/              # AI 提供商
│   ├── chat.ex      # 非流式 API
│   ├── stream.ex    # 流式 API
│   ├── embeddings.ex
│   ├── oauth.ex     # OAuth 管理
│   └── oauth/
│       └── anthropic.ex
├── browser/         # 浏览器控制
│   ├── server.ex    # GenServer
│   └── cdp.ex       # CDP 协议
├── channels/        # 消息渠道
├── cron/            # 定时任务
├── memory/          # 记忆系统
├── nodes/           # 节点管理
├── sessions/        # 会话管理
├── streaming/       # 流式响应
└── tools/           # 21 个工具
    ├── registry.ex  # 工具注册表
    ├── browser.ex
    ├── nodes.ex
    ├── canvas.ex
    └── ...
```

## 里程碑

| 日期 | 版本 | 内容 |
|------|------|------|
| 2026-01-30 | v0.1.0 | 初始版本，基础框架 |
| 2026-01-31 | v0.2.0 | Phase 1-6 完成，核心功能对等 |
| 2026-01-31 | v0.2.1 | OAuth 支持，闭环验证通过 |

## 下一步

1. 完善文档和示例
2. 性能优化
3. 生产环境部署指南
4. 可选: apply_patch, image 工具
