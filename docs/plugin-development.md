# Plugin Development Guide

完整的 ClawdEx 插件开发指南，涵盖 Elixir 和 Node.js 两种运行时。

---

## plugin.json Schema

所有插件都需要 `plugin.json` 元数据文件，定义插件的基本信息和能力。

### 完整 Schema

```json
{
  "$schema": "https://clawd.ai/schemas/plugin.json",
  "id": "string (required)",
  "name": "string (required)",
  "version": "string (required, semver)",
  "description": "string (required)",
  "runtime": "beam | node (required)",
  "entry": "string (required)",
  "author": "string (optional)",
  "license": "string (optional, default: MIT)",
  "homepage": "string (optional)",
  "repository": "string (optional)",

  "provides": {
    "tools": ["string (tool names)"],
    "channels": ["string (channel ids)"],
    "providers": ["string (provider names)"],
    "hooks": ["string (hook names)"],
    "skills": ["string (skill paths)"]
  },

  "config_schema": {
    "field_name": {
      "type": "string | number | boolean | array | object",
      "required": "boolean (optional, default: false)",
      "sensitive": "boolean (optional, default: false)",
      "default": "any (optional)",
      "label": "string (optional, for UI)",
      "description": "string (optional)",
      "enum": ["array of allowed values (optional)"],
      "pattern": "string (regex pattern for validation)"
    }
  },

  "dependencies": {
    "clawd_ex": "string (version requirement)",
    "other_plugin": "string (version requirement)"
  },

  "permissions": {
    "network": ["string (allowed domains)"],
    "filesystem": ["read | write | execute"],
    "tools": ["string (tool names this plugin can use)"],
    "system": ["string (system capabilities)"]
  },

  "metadata": {
    "category": "string (plugin category)",
    "tags": ["string (search tags)"],
    "icon": "string (icon URL or emoji)",
    "screenshots": ["string (screenshot URLs)"],
    "minimum_version": "string (minimum ClawdEx version)"
  }
}
```

### 字段说明

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | string | ✓ | 插件唯一标识符，kebab-case |
| `name` | string | ✓ | 插件显示名称 |
| `version` | string | ✓ | 语义化版本号 |
| `description` | string | ✓ | 插件功能描述 |
| `runtime` | enum | ✓ | 运行时：`"beam"` 或 `"node"` |
| `entry` | string | ✓ | 入口点：模块名（beam）或文件路径（node） |
| `provides` | object | ✓ | 插件提供的能力清单 |
| `config_schema` | object | | 配置项架构定义 |
| `dependencies` | object | | 依赖的插件和版本要求 |
| `permissions` | object | | 权限申请清单 |
| `metadata` | object | | 元数据信息 |

### 配置项类型

```json
{
  "config_schema": {
    "api_key": {
      "type": "string",
      "required": true,
      "sensitive": true,
      "label": "API Key",
      "description": "Your service API key",
      "pattern": "^[a-zA-Z0-9_-]+$"
    },
    "timeout": {
      "type": "number",
      "default": 30000,
      "label": "Timeout (ms)",
      "description": "Request timeout in milliseconds"
    },
    "enabled_features": {
      "type": "array",
      "default": ["search", "upload"],
      "label": "Enabled Features",
      "description": "List of enabled features"
    },
    "webhook_config": {
      "type": "object",
      "default": {},
      "label": "Webhook Configuration",
      "description": "Webhook settings"
    },
    "debug_mode": {
      "type": "boolean",
      "default": false,
      "label": "Debug Mode"
    }
  }
}
```

---

## Elixir 插件开发

### 项目结构

```
my-analytics-plugin/
├── lib/
│   └── my_analytics/
│       ├── plugin.ex           # 主插件模块
│       ├── tools/
│       │   ├── query.ex        # 查询工具
│       │   └── report.ex       # 报告工具
│       └── channels/
│           └── webhook.ex      # Webhook 渠道
├── beams/                      # 编译后的 .beam 文件
├── skills/                     # 技能文件
│   └── analytics/
│       └── SKILL.md
├── plugin.json                 # 插件元数据
├── mix.exs                     # Mix 项目配置
└── README.md
```

### 主插件模块

```elixir
defmodule MyAnalytics.Plugin do
  @behaviour ClawdEx.Plugins.Plugin

  # ============================================================================
  # 必需回调
  # ============================================================================

  @impl true
  def id, do: "my-analytics"

  @impl true
  def name, do: "Analytics Plugin"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def description, do: "Advanced analytics and reporting tools"

  @impl true
  def plugin_type, do: :beam

  @impl true
  def capabilities, do: [:tools, :channels, :hooks]

  @impl true
  def init(config) do
    state = %{
      config: config,
      db: connect_to_database(config),
      cache: :ets.new(__MODULE__, [:set, :private])
    }
    {:ok, state}
  end

  # ============================================================================
  # 可选回调 - 工具定义
  # ============================================================================

  @impl true
  def tools do
    [
      %{
        name: "analytics_query",
        description: "Query analytics data with filters and aggregations",
        parameters: %{
          type: "object",
          properties: %{
            metric: %{
              type: "string",
              description: "Metric to query (pageviews, conversions, etc.)",
              enum: ["pageviews", "conversions", "revenue", "users"]
            },
            date_range: %{
              type: "string",
              description: "Date range in ISO format or preset",
              pattern: "^(\\d{4}-\\d{2}-\\d{2}/\\d{4}-\\d{2}-\\d{2}|today|yesterday|last_7_days|last_30_days)$"
            },
            filters: %{
              type: "object",
              description: "Additional filters",
              properties: %{
                country: %{type: "string"},
                device_type: %{type: "string", enum: ["desktop", "mobile", "tablet"]}
              }
            },
            group_by: %{
              type: "array",
              items: %{type: "string"},
              description: "Dimensions to group by"
            }
          },
          required: ["metric", "date_range"]
        }
      },
      %{
        name: "analytics_report",
        description: "Generate comprehensive analytics report",
        parameters: %{
          type: "object",
          properties: %{
            report_type: %{
              type: "string",
              enum: ["summary", "detailed", "trends"],
              description: "Type of report to generate"
            },
            date_range: %{type: "string", description: "Date range"},
            export_format: %{
              type: "string",
              enum: ["json", "csv", "pdf"],
              default: "json"
            }
          },
          required: ["report_type", "date_range"]
        }
      }
    ]
  end

  # ============================================================================
  # 可选回调 - 渠道定义
  # ============================================================================

  @impl true
  def channels do
    [
      %{
        id: "analytics-webhook",
        label: "Analytics Webhook",
        module: MyAnalytics.Channels.Webhook
      }
    ]
  end

  # ============================================================================
  # 可选回调 - Hook 定义
  # ============================================================================

  @impl true
  def hooks do
    [
      %{
        event: "after_tool_call",
        handler: &handle_tool_audit/2
      }
    ]
  end

  # ============================================================================
  # 工具执行
  # ============================================================================

  @impl true
  def handle_tool_call("analytics_query", params, context) do
    with {:ok, validated} <- validate_query_params(params),
         {:ok, data} <- execute_query(validated, context) do
      {:ok, format_query_result(data)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_tool_call("analytics_report", params, context) do
    with {:ok, validated} <- validate_report_params(params),
         {:ok, report} <- generate_report(validated, context) do
      {:ok, report}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # 私有函数
  # ============================================================================

  defp connect_to_database(config) do
    # 数据库连接逻辑
    case MyAnalytics.Database.connect(config["database_url"]) do
      {:ok, conn} -> conn
      {:error, reason} -> 
        Logger.error("[MyAnalytics] Database connection failed: #{reason}")
        nil
    end
  end

  defp validate_query_params(params) do
    # 参数验证逻辑
    required = ["metric", "date_range"]
    missing = required -- Map.keys(params)
    
    if Enum.empty?(missing) do
      {:ok, params}
    else
      {:error, "Missing required parameters: #{Enum.join(missing, ", ")}"}
    end
  end

  defp execute_query(params, context) do
    # 查询执行逻辑
    metric = params["metric"]
    date_range = parse_date_range(params["date_range"])
    filters = params["filters"] || %{}
    group_by = params["group_by"] || []

    query = build_query(metric, date_range, filters, group_by)
    
    case MyAnalytics.Database.execute(query) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, "Query failed: #{reason}"}
    end
  end

  defp format_query_result(data) do
    %{
      data: data,
      meta: %{
        total_rows: length(data),
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  defp handle_tool_audit(event, _state) do
    # Hook 处理逻辑
    Logger.info("[MyAnalytics] Tool called: #{event.tool_name}, duration: #{event.duration_ms}ms")
    :ok
  end

  # ... 其他私有函数
end
```

### 工具模块分离

对于复杂插件，可以将工具逻辑分离到独立模块：

```elixir
defmodule MyAnalytics.Tools.QueryTool do
  @moduledoc """
  Analytics query tool implementation
  """

  def spec do
    %{
      name: "analytics_query",
      description: "Query analytics data",
      parameters: %{
        # ... 参数定义
      }
    }
  end

  def execute(params, context) do
    # 工具执行逻辑
    with {:ok, validated} <- validate(params),
         {:ok, data} <- query_database(validated, context) do
      {:ok, format_response(data)}
    end
  end

  defp validate(params) do
    # 验证逻辑
  end

  defp query_database(params, context) do
    # 数据库查询
  end

  defp format_response(data) do
    # 响应格式化
  end
end
```

在主插件模块中引用：

```elixir
defmodule MyAnalytics.Plugin do
  # ...

  @impl true
  def tools do
    [
      MyAnalytics.Tools.QueryTool.spec(),
      MyAnalytics.Tools.ReportTool.spec()
    ]
  end

  @impl true
  def handle_tool_call("analytics_query", params, context) do
    MyAnalytics.Tools.QueryTool.execute(params, context)
  end

  def handle_tool_call("analytics_report", params, context) do
    MyAnalytics.Tools.ReportTool.execute(params, context)
  end
end
```

### 渠道模块

```elixir
defmodule MyAnalytics.Channels.Webhook do
  use GenServer
  require Logger

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def send_message(chat_id, content, opts \\ []) do
    GenServer.call(__MODULE__, {:send_message, chat_id, content, opts})
  end

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl true
  def init(config) do
    state = %{
      webhook_url: config["webhook_url"],
      secret: config["webhook_secret"],
      timeout: config["timeout"] || 30_000
    }
    
    Logger.info("[Analytics] Webhook channel started")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, chat_id, content, opts}, _from, state) do
    result = send_webhook(state, chat_id, content, opts)
    {:reply, result, state}
  end

  # ============================================================================
  # Private functions
  # ============================================================================

  defp send_webhook(state, chat_id, content, opts) do
    payload = %{
      chat_id: chat_id,
      content: content,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      options: opts
    }

    headers = [
      {"Content-Type", "application/json"},
      {"User-Agent", "ClawdEx-Analytics/1.0"}
    ]

    # Add signature if secret is configured
    headers = case state.secret do
      nil -> headers
      secret -> 
        signature = compute_signature(payload, secret)
        [{"X-Webhook-Signature", signature} | headers]
    end

    case HTTPoison.post(state.webhook_url, Jason.encode!(payload), headers, timeout: state.timeout) do
      {:ok, %HTTPoison.Response{status_code: 200}} ->
        {:ok, %{status: "sent", timestamp: payload.timestamp}}
      
      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        {:error, "HTTP #{code}: #{body}"}
      
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Request failed: #{reason}"}
    end
  end

  defp compute_signature(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, Jason.encode!(payload))
    |> Base.encode16(case: :lower)
  end
end
```

### 编译和打包

```bash
# 编译插件
mix compile

# 复制 .beam 文件到 beams/ 目录
mkdir -p beams
cp _build/prod/lib/my_analytics/ebin/*.beam beams/

# 创建插件包
tar czf my-analytics-1.0.0.tar.gz plugin.json beams/ skills/
```

---

## Node.js 插件开发

### 项目结构

```
my-service-plugin/
├── src/
│   ├── index.js                # 主入口
│   ├── tools/
│   │   ├── search.js           # 搜索工具
│   │   └── upload.js           # 上传工具
│   ├── channels/
│   │   └── webhook.js          # Webhook 渠道
│   └── utils/
│       └── api.js              # API 工具函数
├── skills/                     # 技能文件
│   └── my-service/
│       └── SKILL.md
├── tests/                      # 测试文件
├── plugin.json                 # 插件元数据
├── package.json                # npm 包信息
└── README.md
```

### 主入口文件

```javascript
// src/index.js
import SearchTool from './tools/search.js';
import UploadTool from './tools/upload.js';
import WebhookChannel from './channels/webhook.js';

export default function register(api) {
  // 插件初始化
  api.logger.info(`Initializing ${api.config.service_name || 'My Service'} plugin`);

  // 验证配置
  if (!api.config.api_key) {
    throw new Error('API key is required');
  }

  // 注册工具
  api.registerTool(new SearchTool(api));
  api.registerTool(new UploadTool(api));

  // 条件性注册工具（基于配置）
  if (api.config.enable_batch_operations) {
    api.registerTool(createBatchTools(api));
  }

  // 注册渠道
  if (api.config.webhook_url) {
    api.registerChannel(new WebhookChannel(api));
  }

  // 注册 hooks
  api.on('before_tool_call', async (event) => {
    api.logger.debug(`About to call tool: ${event.toolName}`);
    // 预处理逻辑
  });

  api.on('after_tool_call', async (event) => {
    // 记录调用统计
    await logToolUsage(api, event);
  });

  api.logger.info('Plugin registered successfully');
}

// 工具工厂函数
function createBatchTools(api) {
  return [
    {
      name: 'batch_search',
      description: 'Search multiple queries in batch',
      parameters: {
        type: 'object',
        properties: {
          queries: {
            type: 'array',
            items: { type: 'string' },
            description: 'List of search queries'
          },
          max_results_per_query: {
            type: 'number',
            default: 10,
            maximum: 50
          }
        },
        required: ['queries']
      },
      async execute(params, context) {
        const results = await Promise.allSettled(
          params.queries.map(query => searchSingle(api, query, params.max_results_per_query))
        );
        
        return {
          results: results.map((result, index) => ({
            query: params.queries[index],
            status: result.status,
            data: result.status === 'fulfilled' ? result.value : null,
            error: result.status === 'rejected' ? result.reason.message : null
          }))
        };
      }
    }
  ];
}

async function logToolUsage(api, event) {
  // 统计逻辑（可选）
  const stats = {
    tool: event.toolName,
    duration: event.durationMs,
    success: !event.error,
    timestamp: new Date().toISOString()
  };
  
  // 发送到分析服务
  try {
    await sendAnalytics(api.config, stats);
  } catch (err) {
    api.logger.warn(`Failed to send analytics: ${err.message}`);
  }
}
```

### 工具类实现

```javascript
// src/tools/search.js
export default class SearchTool {
  constructor(api) {
    this.api = api;
    this.client = createApiClient(api.config);
  }

  // 工具规格定义
  get name() { return 'service_search'; }
  get description() { return 'Search the service database'; }
  get parameters() {
    return {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Search query string',
          minLength: 1,
          maxLength: 200
        },
        filters: {
          type: 'object',
          properties: {
            category: { type: 'string' },
            date_range: { type: 'string' },
            tags: { 
              type: 'array',
              items: { type: 'string' }
            }
          }
        },
        limit: {
          type: 'number',
          default: 20,
          minimum: 1,
          maximum: 100
        },
        sort: {
          type: 'string',
          enum: ['relevance', 'date', 'popularity'],
          default: 'relevance'
        }
      },
      required: ['query']
    };
  }

  // 工具执行函数
  async execute(params, context) {
    const { query, filters = {}, limit = 20, sort = 'relevance' } = params;

    try {
      // 参数验证
      this.validateParams(params);

      // API 调用
      const results = await this.client.search({
        q: query,
        filters,
        limit,
        sort,
        // 从 context 中传递会话信息
        session_id: context.sessionKey
      });

      // 结果处理
      return {
        results: results.items.map(this.formatResult),
        total: results.total,
        query,
        filters,
        meta: {
          duration_ms: results.duration,
          api_version: results.version
        }
      };
    } catch (error) {
      this.api.logger.error(`Search failed: ${error.message}`, { query, error });
      throw new Error(`Search failed: ${error.message}`);
    }
  }

  validateParams(params) {
    if (!params.query?.trim()) {
      throw new Error('Query cannot be empty');
    }
    if (params.limit > 100) {
      throw new Error('Limit cannot exceed 100');
    }
  }

  formatResult(item) {
    return {
      id: item.id,
      title: item.title,
      description: item.description,
      url: item.url,
      score: item.relevance_score,
      metadata: {
        category: item.category,
        updated_at: item.updated_at,
        tags: item.tags || []
      }
    };
  }
}

function createApiClient(config) {
  return {
    async search(params) {
      const response = await fetch(`${config.api_base_url}/search`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${config.api_key}`,
          'Content-Type': 'application/json',
          'User-Agent': 'ClawdEx-Plugin/1.0'
        },
        body: JSON.stringify(params)
      });

      if (!response.ok) {
        throw new Error(`API error: ${response.status} ${response.statusText}`);
      }

      return await response.json();
    }
  };
}
```

### 异步工具

```javascript
// 长时间运行的工具
class AsyncProcessTool {
  constructor(api) {
    this.api = api;
    this.jobs = new Map(); // 任务跟踪
  }

  get name() { return 'async_process'; }
  get description() { return 'Start an asynchronous processing job'; }
  get parameters() {
    return {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['start', 'status', 'cancel'],
          description: 'Action to perform'
        },
        job_id: {
          type: 'string',
          description: 'Job ID for status/cancel actions'
        },
        data: {
          type: 'object',
          description: 'Data to process (for start action)'
        }
      },
      required: ['action']
    };
  }

  async execute(params, context) {
    switch (params.action) {
      case 'start':
        return await this.startJob(params.data, context);
      case 'status':
        return await this.getJobStatus(params.job_id);
      case 'cancel':
        return await this.cancelJob(params.job_id);
      default:
        throw new Error(`Unknown action: ${params.action}`);
    }
  }

  async startJob(data, context) {
    const jobId = generateJobId();
    
    // 启动后台处理
    const promise = this.processInBackground(data, context);
    this.jobs.set(jobId, {
      id: jobId,
      status: 'running',
      started_at: new Date(),
      promise
    });

    // 异步完成处理
    promise
      .then(result => {
        this.jobs.set(jobId, {
          ...this.jobs.get(jobId),
          status: 'completed',
          completed_at: new Date(),
          result
        });
        this.api.logger.info(`Job ${jobId} completed`);
      })
      .catch(error => {
        this.jobs.set(jobId, {
          ...this.jobs.get(jobId),
          status: 'failed',
          completed_at: new Date(),
          error: error.message
        });
        this.api.logger.error(`Job ${jobId} failed: ${error.message}`);
      });

    return {
      job_id: jobId,
      status: 'started',
      message: 'Job started successfully. Use status action to check progress.'
    };
  }

  async getJobStatus(jobId) {
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new Error(`Job ${jobId} not found`);
    }

    const response = {
      job_id: jobId,
      status: job.status,
      started_at: job.started_at
    };

    if (job.completed_at) {
      response.completed_at = job.completed_at;
    }

    if (job.status === 'completed') {
      response.result = job.result;
    } else if (job.status === 'failed') {
      response.error = job.error;
    }

    return response;
  }

  async processInBackground(data, context) {
    // 模拟长时间处理
    await new Promise(resolve => setTimeout(resolve, 5000));
    return { processed: true, data_size: JSON.stringify(data).length };
  }
}

function generateJobId() {
  return `job_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
}
```

### 渠道实现

```javascript
// src/channels/webhook.js
export default class WebhookChannel {
  constructor(api) {
    this.api = api;
    this.config = api.config;
  }

  get id() { return 'my-service-webhook'; }
  get name() { return 'My Service Webhook'; }

  async send(chatId, content, opts = {}) {
    try {
      const payload = {
        chat_id: chatId,
        content,
        timestamp: new Date().toISOString(),
        metadata: opts.metadata || {}
      };

      const response = await fetch(this.config.webhook_url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.config.webhook_token}`,
          'X-Plugin-Version': '1.0.0'
        },
        body: JSON.stringify(payload)
      });

      if (!response.ok) {
        throw new Error(`Webhook failed: ${response.status}`);
      }

      const result = await response.json();
      
      this.api.logger.info(`Message sent via webhook: ${chatId}`);
      
      return {
        success: true,
        message_id: result.id,
        timestamp: payload.timestamp
      };
    } catch (error) {
      this.api.logger.error(`Webhook send failed: ${error.message}`);
      throw error;
    }
  }

  // 可选：启动监听
  async startPolling() {
    if (!this.config.enable_polling) return;

    this.api.logger.info('Starting webhook polling...');
    
    setInterval(async () => {
      try {
        await this.pollForMessages();
      } catch (error) {
        this.api.logger.error(`Polling error: ${error.message}`);
      }
    }, this.config.poll_interval || 30000);
  }

  async pollForMessages() {
    // 实现消息轮询逻辑
    // 当收到新消息时，通知 ClawdEx
  }
}
```

### 错误处理和重试

```javascript
class RobustApiTool {
  constructor(api) {
    this.api = api;
    this.retryConfig = {
      maxRetries: 3,
      baseDelay: 1000,
      maxDelay: 10000
    };
  }

  async execute(params, context) {
    return await this.withRetry(async () => {
      return await this.performApiCall(params, context);
    });
  }

  async withRetry(fn) {
    let lastError;
    
    for (let attempt = 1; attempt <= this.retryConfig.maxRetries; attempt++) {
      try {
        return await fn();
      } catch (error) {
        lastError = error;
        
        // 不重试的错误类型
        if (this.isNonRetryableError(error)) {
          throw error;
        }
        
        if (attempt < this.retryConfig.maxRetries) {
          const delay = Math.min(
            this.retryConfig.baseDelay * Math.pow(2, attempt - 1),
            this.retryConfig.maxDelay
          );
          
          this.api.logger.warn(`Attempt ${attempt} failed, retrying in ${delay}ms: ${error.message}`);
          await new Promise(resolve => setTimeout(resolve, delay));
        }
      }
    }
    
    throw new Error(`Max retries exceeded. Last error: ${lastError.message}`);
  }

  isNonRetryableError(error) {
    // 4xx 错误通常不需要重试
    if (error.status >= 400 && error.status < 500) {
      return true;
    }
    
    // 特定错误类型
    const nonRetryableMessages = [
      'invalid api key',
      'authentication failed',
      'insufficient permissions'
    ];
    
    return nonRetryableMessages.some(msg => 
      error.message.toLowerCase().includes(msg)
    );
  }
}
```

### 测试

```javascript
// tests/search.test.js
import { expect } from 'chai';
import SearchTool from '../src/tools/search.js';

describe('SearchTool', () => {
  let api, tool;

  beforeEach(() => {
    api = createMockApi();
    tool = new SearchTool(api);
  });

  describe('execute', () => {
    it('should search successfully with valid params', async () => {
      const params = {
        query: 'test search',
        limit: 10
      };
      const context = { sessionKey: 'test-session' };

      const result = await tool.execute(params, context);

      expect(result).to.have.property('results');
      expect(result).to.have.property('total');
      expect(result.query).to.equal('test search');
    });

    it('should throw error for empty query', async () => {
      const params = { query: '' };
      const context = {};

      try {
        await tool.execute(params, context);
        expect.fail('Should have thrown error');
      } catch (error) {
        expect(error.message).to.include('Query cannot be empty');
      }
    });
  });
});

function createMockApi() {
  return {
    config: {
      api_key: 'test-key',
      api_base_url: 'https://api.example.com'
    },
    logger: {
      info: () => {},
      warn: () => {},
      error: () => {},
      debug: () => {}
    }
  };
}
```

---

## 工具注册最佳实践

### 参数设计

```javascript
// 好的参数设计
{
  name: 'file_search',
  description: 'Search files with advanced filters and sorting',
  parameters: {
    type: 'object',
    properties: {
      query: {
        type: 'string',
        description: 'Search query (supports regex if starts with /)',
        minLength: 1,
        maxLength: 500
      },
      path: {
        type: 'string',
        description: 'Directory to search in (relative to workspace)',
        default: '.'
      },
      include_extensions: {
        type: 'array',
        items: { type: 'string' },
        description: 'File extensions to include (e.g., [".js", ".md"])'
      },
      exclude_patterns: {
        type: 'array',
        items: { type: 'string' },
        description: 'Patterns to exclude (supports glob)',
        default: ['node_modules/**', '.git/**']
      },
      max_results: {
        type: 'number',
        minimum: 1,
        maximum: 1000,
        default: 50
      },
      sort_by: {
        type: 'string',
        enum: ['name', 'size', 'modified', 'relevance'],
        default: 'relevance'
      }
    },
    required: ['query']
  }
}
```

### 响应格式

```javascript
// 统一的响应格式
async execute(params, context) {
  try {
    const results = await performSearch(params);
    
    return {
      // 主要数据
      results: results.items,
      
      // 元数据
      meta: {
        total_found: results.total,
        search_time_ms: results.duration,
        query: params.query,
        filters_applied: getAppliedFilters(params)
      },
      
      // 可选：分页信息
      pagination: {
        page: 1,
        per_page: params.max_results,
        has_more: results.total > params.max_results
      },
      
      // 可选：建议
      suggestions: results.did_you_mean ? [results.did_you_mean] : []
    };
  } catch (error) {
    // 结构化错误响应
    throw new ToolError({
      code: 'SEARCH_FAILED',
      message: error.message,
      details: {
        query: params.query,
        error_type: error.constructor.name
      }
    });
  }
}

class ToolError extends Error {
  constructor({ code, message, details }) {
    super(message);
    this.code = code;
    this.details = details;
    this.name = 'ToolError';
  }
}
```

---

## 渠道注册

### 基础渠道

```javascript
api.registerChannel({
  id: 'email-notifications',
  name: 'Email Notifications',
  
  async send(chatId, content, opts = {}) {
    // chatId 通常是邮箱地址
    const email = {
      to: chatId,
      subject: opts.subject || 'Notification from ClawdEx',
      body: content,
      html: opts.html || false,
      attachments: opts.attachments || []
    };
    
    const result = await sendEmail(email);
    return { messageId: result.id };
  }
});
```

### 双向渠道

```javascript
api.registerChannel({
  id: 'slack-webhook',
  name: 'Slack Webhook Channel',
  
  async send(chatId, content, opts = {}) {
    const message = {
      channel: chatId,
      text: content,
      blocks: opts.blocks,
      thread_ts: opts.thread_ts
    };
    
    return await this.slackApi.chat.postMessage(message);
  },
  
  // 启动监听（可选）
  async startPolling() {
    // 设置 webhook 端点或 WebSocket 连接
    this.webhookServer = createWebhookServer();
    
    this.webhookServer.on('message', (message) => {
      // 转发消息到 ClawdEx
      // 注意：这需要 ClawdEx 支持渠道消息推送
      this.api.emit('channel.message', {
        chatId: message.channel,
        content: message.text,
        senderId: message.user,
        metadata: {
          timestamp: message.ts,
          thread_ts: message.thread_ts
        }
      });
    });
  }
});
```

---

## Hook 注册

### 事件类型

```javascript
// 工具调用生命周期
api.on('before_tool_call', async (event) => {
  // event: { toolName, params, context, sessionKey }
  api.logger.info(`Starting tool: ${event.toolName}`);
});

api.on('after_tool_call', async (event) => {
  // event: { toolName, params, context, result, error, durationMs }
  if (event.error) {
    api.logger.error(`Tool ${event.toolName} failed: ${event.error.message}`);
  } else {
    api.logger.info(`Tool ${event.toolName} completed in ${event.durationMs}ms`);
  }
});

// 消息生命周期
api.on('before_message_process', async (event) => {
  // event: { message, sessionKey, channel }
  // 预处理消息或添加上下文
});

api.on('after_message_process', async (event) => {
  // event: { message, response, sessionKey, durationMs }
  // 后处理或记录统计
});

// 会话生命周期
api.on('session_created', async (event) => {
  // event: { sessionKey, agentId, channel }
});

api.on('session_ended', async (event) => {
  // event: { sessionKey, reason, duration }
});
```

### Hook 实现示例

```javascript
// 审计日志 Hook
api.on('after_tool_call', async (event) => {
  const auditLog = {
    timestamp: new Date().toISOString(),
    tool: event.toolName,
    session: event.context.sessionKey,
    duration_ms: event.durationMs,
    success: !event.error,
    error: event.error?.message,
    params_hash: hashSensitiveData(event.params)
  };
  
  await saveAuditLog(auditLog);
});

// 性能监控 Hook
api.on('after_tool_call', async (event) => {
  if (event.durationMs > 5000) { // 超过 5 秒
    api.logger.warn(`Slow tool execution: ${event.toolName} took ${event.durationMs}ms`);
    
    // 发送告警
    await sendSlowToolAlert({
      tool: event.toolName,
      duration: event.durationMs,
      session: event.context.sessionKey
    });
  }
});

// 速率限制 Hook
const toolUsage = new Map();

api.on('before_tool_call', async (event) => {
  const key = `${event.context.sessionKey}:${event.toolName}`;
  const now = Date.now();
  const minute = Math.floor(now / 60000);
  const usageKey = `${key}:${minute}`;
  
  const count = (toolUsage.get(usageKey) || 0) + 1;
  toolUsage.set(usageKey, count);
  
  // 限制每分钟调用次数
  if (count > 60) {
    throw new Error(`Rate limit exceeded for ${event.toolName}`);
  }
  
  // 清理旧数据
  if (count === 1) {
    setTimeout(() => toolUsage.delete(usageKey), 120000);
  }
});
```

---

## 调试和日志

### 开发环境调试

```javascript
export default function register(api) {
  // 开发环境额外日志
  if (api.config.debug_mode) {
    api.on('before_tool_call', (event) => {
      console.log('🔧 Tool Call:', {
        tool: event.toolName,
        params: event.params,
        session: event.context.sessionKey
      });
    });
  }
  
  // 性能测量
  const performanceLogs = api.config.enable_performance_logs;
  
  api.registerTool({
    name: 'my_tool',
    // ...
    async execute(params, context) {
      const startTime = performanceLogs ? process.hrtime.bigint() : null;
      
      try {
        const result = await actualWork(params, context);
        
        if (performanceLogs) {
          const duration = Number(process.hrtime.bigint() - startTime) / 1000000;
          api.logger.debug(`my_tool execution: ${duration.toFixed(2)}ms`);
        }
        
        return result;
      } catch (error) {
        if (performanceLogs) {
          const duration = Number(process.hrtime.bigint() - startTime) / 1000000;
          api.logger.debug(`my_tool failed after: ${duration.toFixed(2)}ms`);
        }
        throw error;
      }
    }
  });
}
```

### 错误上下文

```javascript
class DetailedError extends Error {
  constructor(message, context = {}) {
    super(message);
    this.name = 'DetailedError';
    this.context = context;
    this.timestamp = new Date().toISOString();
  }

  toJSON() {
    return {
      message: this.message,
      name: this.name,
      context: this.context,
      timestamp: this.timestamp,
      stack: this.stack
    };
  }
}

// 使用示例
async execute(params, context) {
  try {
    return await apiCall(params);
  } catch (error) {
    throw new DetailedError('API call failed', {
      originalError: error.message,
      params: sanitizeParams(params),
      sessionKey: context.sessionKey,
      apiUrl: this.config.api_url,
      statusCode: error.status
    });
  }
}
```

### 日志最佳实践

```javascript
// 结构化日志
api.logger.info('Tool execution completed', {
  tool: 'search_tool',
  params: { query: 'sanitized-query' },
  results_count: 42,
  duration_ms: 150,
  session: context.sessionKey
});

// 分级日志
api.logger.debug('API request details', { url, headers: sanitizeHeaders(headers) });
api.logger.info('Search completed', { query, results_count });
api.logger.warn('Rate limit approaching', { current: 80, limit: 100 });
api.logger.error('API call failed', { error: error.message, retrying: true });

// 避免敏感信息
function sanitizeParams(params) {
  const safe = { ...params };
  
  // 移除或掩码敏感字段
  ['password', 'api_key', 'token', 'secret'].forEach(field => {
    if (safe[field]) {
      safe[field] = '***';
    }
  });
  
  // 截断长内容
  if (safe.content && safe.content.length > 200) {
    safe.content = safe.content.slice(0, 200) + '...';
  }
  
  return safe;
}
```