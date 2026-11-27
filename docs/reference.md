# 参考：版本、依赖与平台（Reference）

[README](../README.md) 仅保留总览表，本文说明每个版本锁定背后的工程原因、模型分档契约与跨平台依赖细节。部署步骤见 [DEPLOY.md](../DEPLOY.md)，设计权衡见 [decisions.md](decisions.md)。

---

## 1. 核心版本与依赖依据

### Node.js `24.22.3`
**不要使用 `24.19.0–24.21.x`。** 这几个版本在 `ObjectWrap` 清理钩子中存在上游缺陷（`nodejs/node#65446`），当 `pi-knowledge` 的 `better-sqlite3` 在 GC 阶段释放 `Statement` 时会触发 `SIGABRT` 崩溃。WSL2 实测 20 轮 memory 组合在 `24.21.0` 上崩溃 9 轮，切到 `24.22.3` 后为 0 崩溃。Pi 与全局 CLI（如 `agent-browser`）须共用同一 Node 树。

### Pi `1.6.1`
Pi `1.6.1` 上已验证 `pi-maintenance` 单测 47/47、`verify.mjs` 12 PASS + 1 SKIP、`pi-codex-exec` 单测 26/26、配置快照 38/38，以及权限 AST、rtk 改写与 reviewer 路由。`codemode.mode: "only"` 在 `1.6.1` 下保持 6 个直出工具（`ask_user_question`、`codemode`、`contact_supervisor`、`subagent`、`subagent_supervisor`、`tool_search`）。`pi-native-questions@0.2.0` 的 `ask_user_question` 返回结构与 `@mzwing/pi-permission-auto-review` 的可信 `user_interaction` 白名单原生对齐。

`1.6.1` 的破坏性变更只有一处：`showCacheMissNotices` 被拆成 `notices.cacheMisses / cacheWarming / compactionCosts / reasoningDrops`，旧值会在读取时自动迁移到四个新键（不落盘），`SettingsManager.getShowCacheMissNotices()` / `setShowCacheMissNotices()` 已删除。本项目配置已改用 `notices` 对象；导出器按 Pi 的解析顺序合成这四项，先以 `false` 为默认值，再展开旧键，最后用显式 `notices` 逐项覆盖。

### Magic Context `0.49.76`
相对 `0.49.56` 包含多项针对 Pi 的关键修复（无数据库 schema 迁移）：修复 `doctor --fix` 在 Pi 软链场景误删 cache 外文件、修复 Gemini 路由空 text block 导致的 prompt cache 丢失、修复长会话压缩后不再收缩及摘要携带全量项目记忆的 token 膨胀。

### `agent-browser` CLI `>=0.44.0` 与 `rtk` `>=1.1.0`
- `pi-agent-browser-native@0.9.42` 将运行时下限提升至 **`agent-browser >= 0.44.0`**，安装或升级扩展前必须先升级全局 `agent-browser` CLI；
- `extensions/rtk.ts` 依赖 `rtk rewrite` 子命令（需 `>=0.23.0`，基准为 `1.1.0`），缺失时自动 fail-open 放行原始 `bash`。

### 权限系统与自动评审
- `@gotgenes/pi-permission-system@44.0.2`：依赖 `web-tree-sitter` + `tree-sitter-bash` 做命令 AST 拆解，并配合 `commandEffects.rtk` 识别只读 `rtk` 子命令；`path_write` 除保护 `~/.pi/agent/sessions/*`、`~/.pi/agent/memory/*` 外，亦将 `~/.pi/agent/extensions`、`~/.pi/agent/settings.json`、`~/.pi/agent/auth.json`、`~/.config/magpie`、`~/Library/LaunchAgents` 等控制面路径纳入强制人工确认；
- `@mzwing/pi-permission-auto-review@1.0.2`：通过 `config/pi-permission-auto-review/config.json` 挂载到 `{{PROVIDER}}` / `{{MODEL_EXEC}}`（生产环境可替换为带多级回退的路由组），使用 `codex` preset，超时或异常时自动 `defer` 给人类；
- **可选内核沙箱（暂仅支持 macOS）**：若加装独立扩展 `pi-codex-exec`（`v1.4.0`），可通过 `~/.pi/agent/extensions/pi-codex-exec.json` 默认启用 macOS Seatbelt（`/usr/bin/sandbox-exec`）`protect-sensitive` 敏感路径写保护，并在运行中用 `/sandbox [status|on|off]` 热切换（Linux / Windows 暂不支持，保持 `off`）。

### Magpie
**必装组件**。负责统一模型目录与路由、请求脱敏、反爬 `web_fetch` 兜底、独立 stdio `magpie mcp image` 生图服务以及技能索引路由。

---

## 2. 模型分档与角色契约

所有模板均使用占位符，不绑定具体商业模型：

| 占位符 | 定位 | 选型建议 |
| --- | --- | --- |
| `{{MODEL}}` | 主会话默认模型 | 高性价比、工具脚本稳定的日常主力 |
| `{{MODEL_EXEC}}` | 廉价执行 & 默认自动评审 | 响应快、单价低，适合批量执行、测试与权限初审 |
| `{{MODEL_REVIEW}}` | `analyze` 与 `review` 角色 | 更强的异构通用模型，用于方案分析与独立验收 |
| `{{MODEL_PLAN}}` | 临时覆盖（不绑常驻角色） | 最强旗舰模型，在 `subagent({ model: ... })` 按需调用 |
| `{{MODEL_HISTORIAN}}` | Magic Context 归档压缩 | 大窗口、低成本 |

5 个子代理角色的工具权限矩阵：

| 角色 | 工具权限 | 默认模型档位 |
| --- | --- | --- |
| `explore` | 读 + 联网（无 `bash`） | `{{MODEL_EXEC}}` |
| `implement` | 读 + 联网 + `bash`（`rtk`）+ 写 + `codemode` | `{{MODEL_EXEC}}` |
| `lead` | `implement` 全部 + `subagent` | `{{MODEL_EXEC}}` |
| `analyze` | 读 + 联网 + `bash`（`rtk`，带 `toolBudget` 护栏，无写） | `{{MODEL_REVIEW}}` |
| `review` | 同 `analyze`（只读验收，输出 `VERDICT`） | `{{MODEL_REVIEW}}` |

凭据只接受环境变量引用（`$VAR` / `${VAR}`）或 `!command`，明文密钥会被 `render.mjs` 直接拒绝。

---

## 3. 平台支持与专属依赖

- **macOS arm64（基准平台）**：全部模块、5 角色子代理、双层权限门禁与 LaunchAgent 均已实测；无需额外系统运行库。
- **WSL2（Windows 默认推荐）**：
  - 源码、`node_modules`、知识库与 MC 存储必须放在 `/home/<user>`，不要放 `/mnt/c`；
  - 安装 `memory` 模块前必须设置：
    ```sh
    export ONNXRUNTIME_NODE_INSTALL=skip
    export ONNXRUNTIME_NODE_INSTALL_CUDA=skip
    ```
    （CPU 预编译绑定已在包内，跳过默认的 CUDA 下载避免 302 丢包）。
- **原生 Windows x64（试验）**：
  - 必装 Git for Windows（`!command` 凭据与 shell 依赖 Git Bash）；
  - 启用 `memory` 需提前安装 Microsoft Visual C++ 2015–2022 x64 运行库（缺少 `vcruntime140.dll` 会导致 `onnxruntime-node` 报 Win32 126）；
  - `pi-knowledge` 第 4 份补丁已将无预编译产物的 `tree-sitter-qmljs` 降级为可选依赖，缺失仅影响 `.qml` 文件分块，不阻断安装。
- **Linux x64 glibc（试验）**：同 WSL2 设置两个 `ONNXRUNTIME_NODE_INSTALL*` 变量。

---

## 4. 装后自检命令

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,magpie,memory
node scripts/deploy-check.mjs onnx   # 启用 memory 模块时核验 native runtime
```

`doctor.mjs` 返回 **0 FAIL** 即为安装合格；未实测平台的 `platform verification WARN` 属于如实标注而非故障。
