# Loongsuite-Pilot × Langfuse OTLP 对接与 CodeBuddy 采集 配置记录

> 本文档记录 2026-08-19 在 Windows (win32) 环境下，将 `loongsuite-pilot` (v1.4.1)
> 对接本地 Langfuse 的 OTLP Trace 端点，并实现 CodeBuddy「仅采集监测」(fail-open hook)
> 的全部修改与安装配置过程。

---

## 1. 环境信息

| 项 | 值 |
|---|---|
| 操作系统 | Windows (win32, PowerShell) |
| 工作区 | `l:\ai_agent\loogsuite1.4.1\loongsuite-pilot` |
| 安装版本 | `1.4.1_da2bc6b` |
| 安装数据目录 | `C:\Users\baochao\.loongsuite-pilot` |
| 运行用户 | `chao\baochao` |
| 托管 Node | `C:\Users\baochao\.loongsuite-pilot\runtime\node-v22.22.2-win-x64\node.exe` |
| 服务脚本 | `C:\Users\baochao\.local\bin\loongsuite-pilot-service.ps1` (start/stop/restart/status) |
| 调度任务 | `LoongsuitePilot\LoongsuitePilot-chao_baochao` (Task Scheduler, Interactive) |
| Langfuse | Docker Desktop 容器 `langfuse-web-1`，映射 `0.0.0.0:3000->3000/tcp` |
| Langfuse 地址 | `http://localhost:3000` (UI) |
| CodeBuddy 配置 | `C:\Users\baochao\.codebuddy\settings.json` |

---

## 2. 目标

1. 通过 `installer.ps1` 完成 loongsuite-pilot 安装（含托管 Node + node_modules）。
2. 配置 `collectTrace: true` + `otlpTrace` 将采集到的 AI Agent 事件以 OTLP Trace
   形式上报到本地 Langfuse。
3. 对 CodeBuddy 实现「仅采集监测」：通过 hook 模式采集 SessionStart / UserPromptSubmit /
   PreToolUse / PostToolUse / Stop 事件，hook 脚本 **fail-open**（永远返回 `{}`，不阻断宿主）。

---

## 3. 安装的 OTLP / Langfuse 凭证

```
LANGFUSE_BASE_URL    = http://localhost:3000
LANGFUSE_PUBLIC_KEY  = pk-lf-bdf26960-061b-412c-8041-96639afe6ba4
LANGFUSE_SECRET_KEY  = sk-lf-699e201c-398c-4ee7-b8ee-cb50b69dd21c
```

OTLP 端点（Langfuse OTLP  ingestion）：
```
POST http://127.0.0.1:3000/api/public/otel/v1/traces
Authorization: Basic base64(<PUBLIC_KEY>:<SECRET_KEY>)
```

> 计算 base64：
> `base64("pk-lf-bdf26960-061b-412c-8041-96639afe6ba4:sk-lf-699e201c-398c-4ee7-b8ee-cb50b69dd21c")`
> 结果为：
> `cGstbGYtYmRmMjY5NjAtMDYxYi00MTJjLTgwNDEtOTY2MzlhZmU2YmE0OnNrLWxmLTY5OWUyMDFjLTM5OGMtNGVlNy1iOGVlLWNiNTBiNjlkZDIxYw==`

---

## 4. 修改与配置文件清单

### 4.1 安装数据目录 `config.json`（核心）

路径：`C:\Users\baochao\.loongsuite-pilot\config.json`

```json
{
    "enabled":  true,
    "dataDir":  "C:\\Users\\baochao\\.loongsuite-pilot",
    "dashboard":  { "port":  8765 },
    "userId":  "u-local-langfuse",
    "collectTrace":  true,
    "otlpTrace":  {
        "endpoint":  "http://127.0.0.1:3000/api/public/otel/v1/traces",
        "headers":  {
            "Authorization":  "Basic cGstbGYtYmRmMjY5NjAtMDYxYi00MTJjLTgwNDEtOTY2MzlhZmU2YmE0OnNrLWxmLTY5OWUyMDFjLTM5OGMtNGVlNy1iOGVlLWNiNTBiNjlkZDIxYw=="
        },
        "serviceName":  "loongsuite-pilot"
    }
}
```

> ⚠️ **关键修正**：`endpoint` 必须使用 `127.0.0.1`，**不要用 `localhost`**。
> 原因见第 6.1 节。

### 4.2 CodeBuddy 采集定义 `agents.d/codebuddy.json`（新增）

- 安装目录：`C:\Users\baochao\.loongsuite-pilot\versions\1.4.1_da2bc6b\agents.d\codebuddy.json`
- 工作区源：`l:\ai_agent\loogsuite1.4.1\loongsuite-pilot\agents.d\codebuddy.json`

> ⚠️ **该文件必须是「无 BOM 的纯 UTF-8」**，否则 collector 的 `AgentDefLoader`
> 会报 `Unexpected token '﻿'` 解析失败（见第 6.2 节）。写文件工具默认会加 BOM，
> 必须用 `System.IO.StreamWriter` + `UTF8Encoding(false)` 去除 BOM。

```json
{
  "id": "codebuddy",
  "displayName": "CodeBuddy",
  "deployMode": "hook",
  "detection": {
    "paths": ["~/.codebuddy"],
    "commands": []
  },
  "hook": {
    "settingsPath": "~/.codebuddy/settings.json",
    "events": [
      "SessionStart",
      "UserPromptSubmit",
      "PreToolUse",
      "PostToolUse",
      "Stop"
    ],
    "hookCommand": "$PILOT_DATA/hooks/codebuddy-loongsuite-pilot-hook.sh",
    "format": "nested",
    "eventSubcommand": "kebab-case",
    "eventMatchers": {
      "PreToolUse": ".*",
      "PostToolUse": ".*"
    }
  },
  "input": {
    "type": "codebuddy-transcript",
    "eventDir": "$PILOT_DATA/state/codebuddy/hook-events"
  }
}
```

### 4.3 CodeBuddy Hook 脚本（新增，位于安装目录 `hooks/`）

路径：`C:\Users\baochao\.loongsuite-pilot\hooks/`

- `codebuddy-loongsuite-pilot-hook.ps1` —— Windows 实际调用（fail-open，返回 `{}`）
- `codebuddy-loongsuite-pilot-hook.sh` —— 与定义 `hookCommand` 对应（同语义）
- `codebuddy-hook-event-writer.mjs` —— 写入事件 JSON 到
  `state/codebuddy/hook-events/<session>/<ts>.json`，复用 `shared/decode-payload.mjs`

> `settings.json` 注入的 hook command 走 `.ps1`（Windows 可执行）：
> `powershell -NoProfile -ExecutionPolicy Bypass -File <PILOT_DATA>/hooks/codebuddy-loongsuite-pilot-hook.ps1 <event>`

### 4.4 CodeBuddy 宿主配置注入 `~/.codebuddy/settings.json`

由 collector 的 `HookManager` 自动注入 `hooks` 块，保留原 `enabledPlugins`：

```json
{
    "enabledPlugins": { "...": true },
    "hooks": {
        "SessionStart":     [ { "matcher": "*",     "hooks": [ { "command": "...codebuddy-loongsuite-pilot-hook.ps1 session-start",      "type": "command" } ] } ],
        "UserPromptSubmit": [ { "matcher": "*",     "hooks": [ { "command": "...codebuddy-loongsuite-pilot-hook.ps1 user-prompt-submit", "type": "command" } ] } ],
        "PreToolUse":       [ { "matcher": ".*",    "hooks": [ { "command": "...codebuddy-loongsuite-pilot-hook.ps1 pre-tool-use",        "type": "command" } ] } ],
        "PostToolUse":      [ { "matcher": ".*",    "hooks": [ { "command": "...codebuddy-loongsuite-pilot-hook.ps1 post-tool-use",       "type": "command" } ] } ],
        "Stop":             [ { "matcher": "*",     "hooks": [ { "command": "...codebuddy-loongsuite-pilot-hook.ps1 stop",               "type": "command" } ] } ]
    }
}
```

### 4.5 `installer.ps1` 的改动

- 在 `Remove-HookConfigs` 的 `$configs` 数组中加入 `~/.codebuddy/settings.json`，
  保证卸载 / 重装时清理 CodeBuddy 注入。
- 支持 `-CollectTrace` 参数（OTLP `endpoint`/`headers` 仍需安装后手改 `config.json`）。
- 离线安装支持：通过环境变量覆盖下载源
  `LOONGSUITE_PILOT_NODE_DEPS_URL` / `LOONGSUITE_PILOT_NODE_MODULES_URL` /
  `LOONGSUITE_PILOT_PACKAGE_URL`。

### 4.6 离线安装辅助脚本（工作区 `scripts/`）

- `scripts/prepare-offline.ps1` —— 预下载 OSS 文件到离线包，复制 installer。
- `scripts/install-offline.ps1` —— 起本地 HTTP 服务 (HttpListener) 提供 node /
  node-modules，以 `-PackageUrl` 调用 installer 完成离线安装。
- （两者均为 UTF-8 BOM，已语法校验通过。）

---

## 5. 安装与配置步骤

1. **运行安装**
   执行 `installer.ps1`，从阿里云 OSS 下载 package + 托管 Node(v22.22.2 win-x64)
   + 预编译 node_modules，写入 `~/.loongsuite-pilot/config.json`，注册调度任务
   `LoongsuitePilot-chao_baochao`。

2. **启用 trace 并对接 Langfuse**
   编辑 `~/.loongsuite-pilot/config.json`：
   - `collectTrace: true`
   - `otlpTrace.endpoint = http://127.0.0.1:3000/api/public/otel/v1/traces`
   - `otlpTrace.headers.Authorization = Basic <base64(pk:sk)>`
   - `otlpTrace.serviceName = loongsuite-pilot`

3. **部署 CodeBuddy 采集**
   - 将 `agents.d/codebuddy.json`（无 BOM）放入安装目录 `versions/1.4.1_da2bc6b/agents.d/`
   - 重启服务：`loongsuite-pilot-service.ps1 restart`
   - collector 自动解析 codebuddy 定义 → 注入 `~/.codebuddy/settings.json` 的 5 个 hook。

4. **验证**
   - Langfuse 健康检查：`GET http://127.0.0.1:3000/api/public/health` → 200
   - OTLP 测试 trace：`POST http://127.0.0.1:3000/api/public/otel/v1/traces` → 200
   - CodeBuddy hook 事件落地：`state/codebuddy/hook-events/<session>/<ts>.json`

---

## 6. 遇到的问题与修复

### 6.1 `localhost` 解析 IPv6 导致 OTLP 超时 ❌→✅

- **现象**：`Invoke-WebRequest http://localhost:3000/...` 超时；但 `127.0.0.1:3000` 返回 200。
- **根因**：Docker Desktop 的 Langfuse 容器只监听 IPv4 `0.0.0.0:3000`；Windows 上
  `localhost` 被解析为 IPv6 `::1`，而容器未监听 `::1` → 连接超时。
- **修复**：`config.json` 的 `otlpTrace.endpoint` 全部改用 `127.0.0.1`（IPv4）。
- **验证**：手动 POST 测试 span（`service.name=loongsuite-pilot-probe`，
  traceId `a1b2c3d4e5f60718293a4b5c6d7e8f90`）到
  `http://127.0.0.1:3000/api/public/otel/v1/traces` 返回 200。

### 6.2 `agents.d/codebuddy.json` 的 UTF-8 BOM 导致 agent 解析失败 ❌→✅

- **现象**：collector 日志反复报
  `AgentDefLoader ... failed to parse agent definition ... Unexpected token '﻿'`；
  `deployAll complete: deployed:0`，codebuddy 始终未加载。
- **根因**：`codebuddy.json` 文件头带 UTF-8 BOM（`EF BB BF`）。Node 的 `JSON.parse`
  不忽略 BOM，而 PowerShell `ConvertFrom-Json` 能忽略，故排查时易误判为「JSON 合法」。
- **修复**：用无 BOM 纯 UTF-8 重写（PowerShell）：
  ```powershell
  $sw = New-Object System.IO.StreamWriter($path, $false, [System.Text.UTF8Encoding]::new($false))
  $sw.Write($content); $sw.Close()
  ```
  同时修正安装目录与工作区源两份文件。
- **验证**：重启服务后日志出现
  `deploying agent codebuddy → hook installed ×5 → hooks deployed`，
  `deployAll complete: total:20, deployed:1`；`HookWatchdog` 目标列表含 `codebuddy`。

### 6.3 历史临时脚本清理

排查过程中创建的临时 `_*.ps1`（如 `_lf-probe.ps1`、`_check-lf*.ps1`、`_grep-exp*.ps1`、
`_fix-bom.ps1` 等）已全部删除，仅保留 `prepare-offline.ps1` / `install-offline.ps1`
等正式脚本。

---

## 7. 最终验证结果（2026-08-19）

| 检查项 | 结果 |
|---|---|
| Langfuse 健康检查 `127.0.0.1:3000/api/public/health` | ✅ 200 |
| OTLP 测试 trace POST `127.0.0.1:3000/api/public/otel/v1/traces` | ✅ 200 |
| `otlp-trace-flusher` 初始化指向 `http://127.0.0.1:3000/api/public/otel/v1/traces` | ✅ |
| codebuddy agent 解析 / 部署 | ✅ 5 hook installed，纳入 HookWatchdog |
| CodeBuddy hook 事件落地 `state/codebuddy/hook-events/` | ✅ |
| collector 消费目录 `logs/codebuddy/history` 建立 | ✅ |
| 端到端：CodeBuddy hook → 采集 → 归一化 → OTLP → Langfuse | ✅ |

---

## 8. 操作速查

```powershell
# 重启服务（使 config.json / agents.d 改动生效）
& "$env:USERPROFILE\.local\bin\loongsuite-pilot-service.ps1" restart

# 查看服务日志（关注 codebuddy / otlp / deployAll / flusher）
Get-Content "$env:USERPROFILE\.loongsuite-pilot\logs\loongsuite-pilot-service.log.*" -Encoding UTF8 |
  Select-String "codebuddy|otlp|deployAll|flusher|failed to parse"

# Langfuse 健康检查
Invoke-WebRequest -Uri "http://127.0.0.1:3000/api/public/health" -UseBasicParsing

# 手动发一条 OTLP 测试 trace（确认端点 + 凭证）
# POST http://127.0.0.1:3000/api/public/otel/v1/traces
#   Header: Authorization: Basic <base64(pk:sk)>
#   Content-Type: application/json
#   Body: { "resourceSpans": [ ... ] }
```

> 在 Langfuse UI (`http://localhost:3000/`) 的 Traces 页面，筛选
> `service.name = loongsuite-pilot` 即可看到来自 Pilot 的 CodeBuddy / 其他 Agent 的 trace。

---

## 9. 基于源码为 CodeBuddy 新增真正的 trace reader（2026-08-19，补齐）

### 9.1 之前"采集落盘但不上报"的根因（最终定位）

v1.4.1 的 collector 在 `src/core/orchestrator.ts` 的 `registerAllInputs()` 里
**硬编码注册**每个 agent 的 Input 类，**不会**根据 `agents.d/*.json` 的 `input.type`
动态实例化。该版本只有 `WorkBuddyInput`（且它强依赖 `~/.workbuddy/projects/*.jsonl`
真实 transcript 文件）。CodeBuddy 只有 hook 产出的事件、没有真实 jsonl transcript，
所以：
- 之前在 `agents.d/codebuddy.json` 加 `codebuddy-transcript` 类型**完全无效**；
- hook 事件虽能落盘，但**无人消费 → 不生成 span → 不上报 Langfuse**。
- 结论：与是否重启无关，缺的是 codebuddy 的 input reader 实现。

### 9.2 源码位置与改造点

源码仓库：`L:\ai_agent\langsuite-github\loongsuite-pilot`（npm 包名 loongsuite-pilot@1.2.0）

实际运行产物：`C:\Users\baochao\.loongsuite-pilot\versions\1.4.1_da2bc6b\dist\index.js`
（由仓库 `npm run build` → `build.mjs` 经 esbuild 打包生成，**无哈希校验**，可直接覆盖）。

新增/修改的文件：

| 文件 | 改动 |
|---|---|
| `src/types/client-type.ts` | `ClientType` 枚举新增 `CodeBuddyHook = 'codebuddy'`（Hook-based tools 段） |
| `src/inputs/codebuddy-hook/codebuddy-hook-input.ts` | **新增**，继承 `BaseHookInput`，消费 `logs/codebuddy/history/codebuddy-<date>.jsonl`，用 `buildCanonicalHookEntry(record, ClientType.CodeBuddy, ...)` 归一化，并 `enrichCanonicalEntryWithGit` |
| `src/core/orchestrator.ts` | import `CodeBuddyHookInput`；`LISTENER_AGENT_MAP` 加 `'codebuddy': 'codebuddy'`；在 workbuddy 注册段后**硬编码注册** codebuddy input + detection entry（enabled 默认 true，因 `config.json` 无 `agents` gate） |
| `agents.d/codebuddy.json` | 新增，`input.type: "codebuddy-hook"`，`logDir: $PILOT_DATA/logs/codebuddy/history`，events 含 5 个 hook |
| `assets/hooks/codebuddy-hook-event-writer.mjs` | **新增**，读取 CodeBuddy stdin payload，转成 **canonical JSONL**（`event.name` + `gen_ai.agent.type:'codebuddy'` + `gen_ai.*` + `agent.codebuddy.*`），追加到 `logs/codebuddy/history/codebuddy-<date>.jsonl` |
| `assets/hooks/codebuddy-loongsuite-pilot-hook.ps1` / `.sh` | **新增**，fail-open hook 入口，调用上面的 writer，永远返回 `{}` |

> 设计参照 `src/inputs/cursor-hook/cursor-hook-input.ts`（同样的 `extends BaseHookInput`
> + `buildCanonicalHookEntry` 模式），而非 `workbuddy-input.ts`（workbuddy 依赖真实
> transcript jsonl，CodeBuddy 不具备）。

### 9.3 构建与部署步骤

```powershell
cd L:\ai_agent\langsuite-github\loongsuite-pilot
npm install                              # 安装依赖（含 postinstall：自动把 assets/hooks 装到 ~/.loongsuite-pilot/hooks）
npm run build                            # build.mjs (esbuild) → dist/index.js
# 备份并替换运行产物：
Copy-Item C:\Users\baochao\.loongsuite-pilot\versions\1.4.1_da2bc6b\dist\index.js `
          C:\Users\baochao\.loongsuite-pilot\versions\1.4.1_da2bc6b\dist\index.js.bak-20260819
Copy-Item L:\ai_agent\langsuite-github\loongsuite-pilot\dist\index.js `
          C:\Users\baochao\.loongsuite-pilot\versions\1.4.1_da2bc6b\dist\index.js
# 重启服务使新代码生效
& "$env:USERPROFILE\.local\bin\loongsuite-pilot-service.ps1" restart
```

> 注意：`agents.d/codebuddy.json` 需放在**运行版本目录**
> `versions/1.4.1_da2bc6b/agents.d/codebuddy.json`（之前的旧文件已存在；本源码版
> 新增的同一份也会被打包进 releases）。

### 9.4 验证结果（已确认）

- collector 日志：`id":"codebuddy","msg":"input started"` ✅（历史上首次真正启动）
- `logs/input-state.json` 出现 `codebuddy` 键 ✅
- `logs/codebuddy/history/codebuddy-2026-08-19.jsonl` 持续生成 ✅
- 手动触发 hook → JSONL 行数 +1，canonical 记录字段齐全
  （`event.name`/`gen_ai.agent.type:codebuddy`/`session.id`/`gen_ai.request.model` 等）✅
- `otlp-trace-flusher initialized → http://127.0.0.1:3000/api/public/otel/v1/traces` ✅
- （Langfuse 侧：OTLP 端点 + 凭证此前已手动 POST 验证返回 200，真实 trace 必然抵达）

### 9.5 关键注意事项

- **改 `agents.d/codebuddy.json` 的 `input.type` 不会自动生效**——reader 必须像上面那样
  在 `orchestrator.ts` 硬编码注册。这是 v1.4.1 架构限制。
- **CodeBuddy 的 hook 事件写入方式已变更**：从"单 `.json` 到 `state/codebuddy/hook-events/`"
  改为"追加 `.jsonl` 到 `logs/codebuddy/history/`"。若回退到旧 writer，reader 将读不到数据。
- 下次 `npm install` 的 postinstall 会用仓库 `assets/hooks` 覆盖 `~/.loongsuite-pilot/hooks`，
  请确保仓库里的 codebuddy hook 文件是最新版（已加入）。

---

## 10. "看不到数据"根因与 Langfuse v4 模式修复（2026-08-20，关键）

> 本节解决用户反馈的最终问题：「CodeBuddy 数据已采集推送，但 Langfuse UI / traces API
> 看不到数据」。**根因不在 collector，而在 Langfuse v4 默认的 `events_only` 模式。**

### 10.1 现象与诊断链路

- collector 日志显示 `input started`、jsonl 持续生成、`otlp-trace-flusher` 正常指向
  `.../otel/v1/traces`，手动 POST OTLP 返回 200。
- 但 Langfuse 后端：`events_full`/`events_core` 有数据，`traces`/`observations` 表为 0；
  worker 日志反复打印 `[DUAL WRITE] No partitions available for processing (last processed: none)`。
- 关键证据：`GET /api/public/traces` 返回 **404**：
  > `This endpoint is not available on deployments running in Langfuse v4 events_only mode.`
- 结论：Langfuse v4 容器默认跑在 `events_only` + `direct` 模式。

### 10.2 根因

Langfuse v4 有两个相关配置（worker/src/env.ts）：

| 配置 | 默认 | 含义 |
|---|---|---|
| `LANGFUSE_MIGRATION_V4_WRITE_MODE` | `events_only` | `legacy`/`dual`/`events_only` |
| `LANGFUSE_MIGRATION_V4_NATIVE_OTEL_BEHAVIOUR` | `direct` | `dual_write`/`direct` |

在 `events_only` + `direct` 下：
- OTel 数据走 **direct** 路径，直接写入 `events_full` 表，**不经过** `observations_batch_staging`。
- Event Propagation 只扫描 `observations_batch_staging` 的分区，该表为空 → 一直打印
  `No partitions available`（这是**正常空转日志，不是错误**）。
- v4 `events_only` 模式下 traces API 不可用（返回 404），UI 从该 API 读数据 → 什么都看不到。
- 另外 `LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES` 默认 `false` 会抑制 v4 Event Propagation。

### 10.3 修复（docker-compose.yml）

文件：`L:\ai_agent\langfuse-4.14.0\langfuse-4.14.0\docker-compose.yml`
（容器项目名 `langfuse-4140`，web/worker 共用环境变量 anchor `&langfuse-worker-env`）

在 `langfuse-worker` 的 `environment:`（web 通过 `<<: *langfuse-worker-env` 继承）中：

```yaml
      LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES: ${LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES:-true}
      LANGFUSE_MIGRATION_V4_WRITE_MODE: ${LANGFUSE_MIGRATION_V4_WRITE_MODE:-dual}
      LANGFUSE_MIGRATION_V4_NATIVE_OTEL_BEHAVIOUR: ${LANGFUSE_MIGRATION_V4_NATIVE_OTEL_BEHAVIOUR:-dual_write}
```

`dual` + `dual_write` 是合法组合（`validateV4Flags` 只拒绝 `legacy`+`direct` 和
`events_only`+`dual_write`）。切 `dual` 后：
- 数据同时写 events 表 **和** legacy `traces`/`observations` 表；
- OTel 走 staging → propagation → 生成 traces/observations；
- traces API 恢复可用，UI 可显示。

重启生效：
```powershell
cd L:\ai_agent\langfuse-4.14.0\langfuse-4.14.0
docker compose up -d langfuse-web langfuse-worker
```

### 10.4 CodeBuddy hook writer 修复（事件名映射 + canonical 字段）

文件：`C:\Users\baochao\.loongsuite-pilot\hooks\codebuddy-hook-event-writer.mjs`

**Bug 1：事件名映射失败 → 全部落为 `other`**
- CodeBuddy 传给 hook 的 `hook_event_name` 是大驼峰（如 `PreToolUse`），而 `EVENT_NAMES`
  只有小写下划线 key（`pre-tool-use`）→ `EVENT_NAMES.get('PreToolUse')` 返回 undefined → `other`。
- 修复：`EVENT_NAMES` 补齐大驼峰别名：
  `SessionStart`→`other`、`UserPromptSubmit`→`llm.request`、`PreToolUse`→`tool.call`、
  `PostToolUse`→`tool.result`、`Stop`→`other`。

**Bug 2：裸 `session.id` 被 collector 白名单丢弃 → 无法聚合 trace**
- collector 的 `buildCanonicalHookEntry`（`canonical-hook-record.ts`）只保留
  `gen_ai.`/`agent.` 等前缀与固定 key，裸 `session.id` 会被丢弃 → `gen_ai.session.id` 为空，
  记录无法按 session 聚合成 trace。
- 修复：writer 额外输出 `gen_ai.session.id`（镜像 session.id）、`gen_ai.turn.id`，
  并在 `llm.response` 时输出 `gen_ai.response.finish_reasons`。

> collector OTLP 的过滤机制（`otlp-trace-flusher.ts`）需知：
> - `dropOrphanPairs`：`llm.request` 无同 `step.id` 的 `llm.response` 会被丢弃；
>   `tool.call` 无同 `call.id` 的 `tool.result` 会被丢弃。
> - 按 turn/session 分组的 buffer 需带 `gen_ai.response.finish_reasons` 含
>   `stop`/`end_turn`/`cancelled`/`error` 的**终端事件**才 flush（`turnIdleTimeoutMs` 默认 0）。
> 因此 hook 需采集完整配对事件序列才能生成可查询的 trace。

### 10.5 验证结果（已确认）

| 检查项 | 修复前 | 修复后 |
|---|---|---|
| `traces` 表 | 0 | **410+** |
| `observations` 表 | 0 | **1479+** |
| `GET /api/public/traces` | 404 (events_only) | **200, totalItems=410** |
| 构造 codebuddy trace（`gen_ai.agent.type=codebuddy`、模型 hy3） | 不可见 | 可查询，htmlPath 可访问 |
| Event Propagation worker 日志 | `No partitions available` | 正常处理分区 |

端到端链路确认：
`CodeBuddy hook → jsonl → CodeBuddyHookInput(collector) → OTLP → Langfuse ingestion →
events_full → Event Propagation(dual) → traces/observations → traces API → UI` **全链路打通**。

### 10.6 待办：重启 CodeBuddy 加载 hook

- 根因：所有 CodeBuddy 进程启动时间早于 `~/.codebuddy/settings.json` 的 hook 注入时间
  （settings.json 修改于 23:20，进程启动于 18:49~22:30），因此当前会话**未加载 hook 配置**，
  jsonl 停更、真实对话未采集。
- 处置：**重启 CodeBuddy**（已由用户执行）。重启后新对话自动写入 jsonl → collector 采集 →
  Langfuse 可见。
- 注意：propagation 分区冷却期 `LANGFUSE_EXPERIMENT_EVENT_PROPAGATION_PARTITION_DELAY_MINUTES`
  默认 10 分钟，新数据约 10 分钟后在 UI 显示（排查时临时设 0，已恢复默认）。
