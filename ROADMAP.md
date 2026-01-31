# ClawdEx 开发路线图

## 目标
实现与 Clawdbot 功能对等的 Elixir 版本。

## 阶段规划

### Phase 1: 核心工具补全 ✅
- [x] web_search, web_fetch
- [x] compact
- [ ] **apply_patch** - 多文件补丁 (低优先级)
- [ ] **image** - 图像分析工具 (低优先级)

### Phase 2: 会话与代理系统 ✅
- [x] **sessions_list** - 列出会话
- [x] **sessions_history** - 会话历史
- [x] **sessions_send** - 跨会话消息
- [x] **sessions_spawn** - 子代理生成
- [x] **agents_list** - 代理列表

### Phase 3: 自动化系统 ✅
- [x] **cron** - 定时任务管理 (Job schema + migration)
- [x] **gateway** - 自管理 (restart/config)
- [x] **message** - 多渠道消息工具

### Phase 4: 浏览器控制 ✅
- [x] **browser** 基础架构
  - [x] Chrome DevTools Protocol 集成
  - [x] start/stop/status
  - [x] tabs 管理 (open/close)
- [x] **browser** 页面操作
  - [x] snapshot (aria/ai)
  - [x] screenshot
  - [x] navigate/console
- [x] **browser** 自动化
  - [x] act (click/type/press/hover/select/fill/drag/wait)
  - [x] evaluate (JS 执行)
  - [x] upload/dialog

### Phase 5: 节点系统 ✅
- [x] **nodes** 基础
  - [x] 节点发现与配对
  - [x] status/describe/pending/approve/reject
- [x] **nodes** 功能
  - [x] notify (通知)
  - [x] run (远程执行)
  - [x] camera_snap/camera_list/camera_clip
  - [x] screen_record
  - [x] location_get

### Phase 6: Canvas/A2UI ✅
- [x] **canvas** 工具
  - [x] present/hide/navigate
  - [x] eval/snapshot
  - [x] a2ui_push/a2ui_reset

### Phase 7: OAuth 认证 ✅
- [x] **OAuth 凭证管理** (GenServer)
  - [x] 自动 token 刷新 (过期前 5 分钟)
  - [x] Claude CLI 凭证加载 (`~/.claude/.credentials.json`)
  - [x] 凭证持久化 (`~/.clawd_ex/oauth_credentials.json`)
- [x] **Anthropic OAuth** 
  - [x] Token 刷新 (`console.anthropic.com/v1/oauth/token`)
  - [x] PKCE 登录流程支持
  - [x] Claude Code 兼容 headers
  - [x] System prompt 前缀
- [x] **集成**
  - [x] Chat API 支持 OAuth
  - [x] Stream API 支持 OAuth
  - [x] 工具名称映射 (Claude Code convention)

---

## 当前状态

### ✅ 已完成 (Phase 1-7)
- **核心框架**: Agent Loop, Sessions, Memory
- **基础工具**: read/write/edit/exec/process
- **记忆系统**: BM25 + Vector hybrid, 中文支持
- **流式响应**: Block Streaming, 代码块保护
- **会话压缩**: AI 摘要自动压缩
- **渠道**: Telegram (Telegex), Discord (Nostrum), WebSocket
- **会话管理**: sessions_list/history/send/spawn, agents_list
- **自动化**: cron, gateway, message
- **浏览器**: CDP 完整控制
- **节点**: 远程设备控制
- **画布**: Canvas/A2UI
- **OAuth**: Anthropic Claude OAuth token 自动刷新

### 📋 剩余工作 (低优先级)
- `apply_patch` - 多文件补丁
- `image` - 图像分析工具

### 📊 统计
- **工具数量**: 21 个
- **测试用例**: 318 个
- **渠道数量**: 3 个 (Telegram/Discord/WebSocket)
- **AI 提供商**: 3 个 (Anthropic/OpenAI/Gemini)

---

## 更新日志

### 2026-01-31 (v0.2.1) - OAuth 支持
- ✨ **OAuth Token 支持**
  - `ClawdEx.AI.OAuth` GenServer 凭证管理
  - `ClawdEx.AI.OAuth.Anthropic` token 刷新
  - 自动检测 OAuth token (`sk-ant-oat*`)
  - Claude CLI 凭证加载
  - 凭证持久化
- 🔧 **流式 API 修复**
  - 修复 Req 0.5.x async response 格式
  - 修复 OAuth headers accept 冲突
- ✅ **测试**: 318 tests, 0 failures
- 🧪 **闭环验证**: Agent Loop + Browser 自动化通过

### 2026-01-31 (v0.2.0) - 功能完成
- 🎉 **里程碑**: 所有主要功能阶段完成
- Phase 6: Canvas/A2UI 工具
- Phase 5: 节点系统 (notify/run/camera/screen/location)
- Phase 4: 浏览器控制 (CDP, 完整自动化)
- Phase 3: 自动化系统 (cron/gateway/message)
- Phase 2: 会话与代理系统
- 优化: 记忆系统中文分词, 流式响应

### 2026-01-30 (v0.1.0)
- 初始路线图创建
- Phase 1 核心工具完成
- 基础框架搭建

---

## 技术亮点

### OAuth 实现
```elixir
# 自动从 Claude CLI 加载
ClawdEx.AI.OAuth.load_from_claude_cli()

# Token 刷新
ClawdEx.AI.OAuth.Anthropic.refresh_token(refresh_token)

# Claude Code 兼容 headers
ClawdEx.AI.OAuth.Anthropic.api_headers(access_token)
```

### Agent Loop 闭环
```
用户请求 → LLM 决策 → 工具调用 → 工具结果 → LLM 总结 → 用户响应
    ↑_______________________________________________|
```

### 浏览器自动化
```elixir
browser(start) → browser(open, url) → browser(screenshot, targetId) → 截图保存
```
