# ClawdEx 开发路线图

## 目标
实现与 Clawdbot 功能对等的 Elixir 版本。

## 阶段规划

### Phase 1: 核心工具补全 (优先级高)
- [x] web_search, web_fetch
- [x] compact
- [ ] **apply_patch** - 多文件补丁
- [ ] **image** - 图像分析工具

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

### Phase 5: 节点系统 (可选)
- [ ] **nodes** 基础
  - [ ] 节点发现与配对
  - [ ] status/describe
- [ ] **nodes** 功能
  - [ ] notify (通知)
  - [ ] run (远程执行)
  - [ ] camera_snap/camera_clip
  - [ ] screen_record
  - [ ] location_get

### Phase 6: Canvas/A2UI (可选)
- [ ] **canvas** 工具
  - [ ] present/hide/navigate
  - [ ] eval/snapshot
  - [ ] a2ui_push/a2ui_reset

---

## 当前状态

**已完成:**
- 核心框架 (Agent Loop, Sessions, Memory)
- 基础工具 (read/write/edit/exec/process)
- 记忆系统 (BM25 + Vector hybrid)
- 流式响应 (Block Streaming)
- 会话压缩 (Compaction)
- 渠道 (Telegram/Discord/WebSocket)

**进行中:**
- Phase 5: 节点系统

---

## 更新日志

### 2026-01-31
- 初始路线图创建
- Phase 1 基本完成
- 开始 Phase 2
