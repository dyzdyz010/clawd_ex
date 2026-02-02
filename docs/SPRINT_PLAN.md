# ClawdEx Sprint Plan - 功能对齐

**开始时间**: 2026-02-02
**目标**: 与 OpenClaw 功能对齐

---

## 🎯 当前 Sprint: 工具补全

### 任务分配

| 任务 | 负责人 | 状态 | 说明 |
|------|--------|------|------|
| **T1. image 工具** | 子代理-1 | 🚧 进行中 | Vision API (Anthropic/OpenAI/Gemini) |
| **T2. tts 工具** | 子代理-2 | 🚧 进行中 | ElevenLabs/OpenAI TTS/Edge TTS |
| **T3. OpenRouter 提供商** | 子代理-3 | 🚧 进行中 | 多模型路由 |
| **T4. 集成测试** | 主代理 | ⬜ 待办 | E2E 测试补全 |

---

## T1. image 工具规格

**文件**: `lib/clawd_ex/tools/image.ex`

**功能**:
- 调用 Vision API 分析图片
- 支持 URL 和 base64 图片输入
- 支持多提供商: Anthropic Claude, OpenAI GPT-4V, Google Gemini

**参数**:
```elixir
%{
  "image" => %{type: "string", description: "Image URL or base64 data URL", required: true},
  "prompt" => %{type: "string", description: "Question about the image"},
  "model" => %{type: "string", description: "Vision model to use"}
}
```

**实现要点**:
- 使用 Req HTTP 客户端
- 复用现有 AI 模块 (ClawdEx.AI.Chat)
- 图片大小限制 (20MB default)
- base64 data URL 解码

---

## T2. tts 工具规格

**文件**: `lib/clawd_ex/tools/tts.ex`

**功能**:
- 文字转语音
- 支持多提供商: OpenAI TTS, ElevenLabs, Edge TTS

**参数**:
```elixir
%{
  "text" => %{type: "string", description: "Text to convert", required: true},
  "channel" => %{type: "string", description: "Channel for output format"}
}
```

**实现要点**:
- OpenAI TTS API (简单, 高质量)
- ElevenLabs API (高质量, 需 API key)
- Edge TTS (免费, 使用 node-edge-tts 或 HTTP)
- 输出到临时文件，返回 MEDIA: 路径

---

## T3. OpenRouter 提供商规格

**文件**: `lib/clawd_ex/ai/providers/openrouter.ex`

**功能**:
- OpenRouter API 集成
- 多模型路由 (Claude/GPT/Gemini/Llama 等)

**实现要点**:
- OpenAI 兼容 API
- 模型别名解析
- 流式响应支持
- X-Title header

---

## 验收标准

### 每个任务必须满足:
1. ✅ 代码实现 (遵循 AGENTS.md 规范)
2. ✅ 单元测试 (使用 start_supervised!/1)
3. ✅ 集成到 Registry
4. ✅ mix precommit 通过

### 整体验收:
- [ ] mix test 全部通过
- [ ] mix format 无警告
- [ ] mix compile --warnings-as-errors 通过

---

## 时间线

| 时间 | 里程碑 |
|------|--------|
| +30min | T1, T2, T3 代码实现完成 |
| +45min | 单元测试通过 |
| +60min | 集成测试通过 |
| +90min | 代码审查 & 优化 |

---

## 参考文件

- OpenClaw image: `src/agents/tools/image-tool.helpers.ts`
- OpenClaw tts: `src/tts/tts.ts`, `src/agents/tools/tts-tool.ts`
- ClawdEx 工具模板: `lib/clawd_ex/tools/web_search.ex`
