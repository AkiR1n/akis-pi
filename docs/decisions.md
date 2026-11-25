# 设计取舍与实测依据（Design Decisions & Evidence）

本文档记录 `akis-pi` 关键配置背后的实测数据、权衡代价与明确边界，方便二次调整时有的放矢。

> 口径说明：估算 token 按 `chars / 4`，实测 token 来自会话 JSONL 的 `usage` 或网关记录，文中均已区分标注。

---

## 1. `codemode.mode: "only"`：压缩常驻开销，且经 13 天生产复查无退步

**决策**：在 `settings.json` 中固定 `{"codemode":{"mode":"only"}}`。在 Pi `1.6.0` + `pi-subagents 0.90.0` 下，模型顶层仅直接可见 **6 个工具**（`ask_user`、`codemode`、`contact_supervisor`、`subagent`、`subagent_supervisor`、`tool_search`），其余 50+ 工具收进 QuickJS 沙箱按需发现。

**静态与生产实测数据**：

| 维度 | 观测结果 | 结论 |
| --- | --- | --- |
| 首轮固定提示词 | 53 → 6 直接工具；系统消息 35,464 → 23,913 字符；首轮 input 25,522 → 13,954 token（−45%）；网关首轮 `in` 中位数 7,785 → 3,953（−49%） | 固定开销压缩成立 |
| 13 天生产会话复查（2026-11-12 至 11-25，61 个净主会话 / 2,842 次脚本） | 脚本总失败率 **3.48%**（合并长寿会话 5,556 次为 **3.19%**）；`searchTools`/`describeTool` 探测仅占内层调用 **2.2%** 且含探测会话比例由 46% 降至 24% | 无退步信号，不触发“核心工具直出” |
| 失败根因拆分（99 次失败） | `SyntaxError` **45.5%**、`ReferenceError` **10.1%**、`TypeError` **6.1%**（合计 **61.6%** 为脚本自身 JS 编写错）；参数形态错仅 2 次（2.0%），且均为 `edit` 内容匹配保护而非参数名猜错 | 直出工具无法解决 JS 编写错，反而会把工具面推高到 ≥40k 字符 |

**对应治理策略**：
- **不将核心工具改为直出**，也不盲目放大 `inlineBudget`（此前 12 任务预筛已证伪“不在内联清单就不用 `edit`”的假设，control 组 11/12 任务仍靠 `describeTool` 正常调用 `edit`）；
- **在 `APPEND_SYSTEM.md` 精准治本**：禁止在 `codemode` 的 JS 数组/反引号里三层嵌套拼 Python 补丁脚本（直接用 `tools.edit`/`tools.write`）、明确沙箱跨轮独立无 `setTimeout`、禁止对 `searchTools()` 或 `read` 图片块调用 `JSON.parse`。

---

## 2. 双层权限门禁：`pi-permission-system` + `pi-permission-auto-review`

**决策**：在 `core` 模块中启用 `@gotgenes/pi-permission-system`（`42.2.1`）与 `@mzwing/pi-permission-auto-review`（`1.0.2`，`preset: "codex"`），同时提供脱敏基线配置 `config/pi-permission-system/config.json` 与 `config/pi-permission-auto-review/config.json`。

- **零开销快路径**：常规 `bash` 与只读 `rtk` 子命令（通过 `commandEffects.rtk` 声明为 `read`）直接 0 ms 放行；
- **AST 级高危拦截**：基于 `web-tree-sitter` + `tree-sitter-bash` 拆解复合命令，拦截 `rm -r*`（放行临时目录）、`git push --force`、`git reset --hard`、`git clean`、`sudo`、`npm publish`、`pi install/remove` 等，且同时覆盖 `rtk` 重写前后的命令形态；
- **有界委派与 Fail-Closed**：自动评审模型超时、不可达或遇到 `external_directory` / `path_write`（如 `~/.pi/agent/sessions/*`、`~/.pi/agent/memory/*`）时一律 `defer` 交由人类确认；无头 `pi -p` 模式下自动拒绝（`confirmation_unavailable`），绝不静默放行。

---

## 3. Magic Context 的三项核心阈值

| 参数 | 配置值 | 决策依据 |
| --- | --- | --- |
| `execute_threshold_tokens.default` | `400000` | 避免小窗口按 65% 过早压缩，也避免超长上下文进入注意力衰减区间；模型实际窗口低于 400k 时 MC 自动钳位至 90%。 |
| `memory.injection_budget_tokens` | `3000` | 1000 token 仅能注入约 4 条项目记忆，召回严重不足；3000 token 可覆盖核心上下文同时可控。 |
| `historian_timeout_ms` | `600000` | 180s 时长会话归档超时率高且会触发后台重试重复计费；放宽至 600s 显著降低中断。 |

**同步纪律**：若本机维护了多个 MC profile，三份 `magic-context.jsonc` 必须保持一致，且 `historian.pi.thinking_level` 必须显式写出，避免静默继承交互默认档位。

---

## 4. 搜索路由与 Magpie 边界

- **搜索链**：`searchRouting.providers = [exa, brave, bocha, gemini, degoog]`，将 `empty` 与 `domain-miss` 纳入 `fallbackOn`，避免搜索结果为空时停滞；修改路由后需重启 Pi 生效。
- **Magpie 接管原则**：只在“降低 Pi 常驻上下文或维护复杂度”时交由 Magpie 接管（模型路由、脱敏、技能路由降 42% 索引开销、独立 stdio `magpie mcp image`、反爬 `web_fetch` 兜底）；不接管本地持久记忆与桌面/浏览器自动化；需要斜杠命令注册的技能（如 `/skill:save-topic`、`/skill:self`）保持直连。

---

## 5. 分层记忆与 `RESIDENT.md` 规范

- **每轮常驻**：`resident-memory.ts` 仅注入 `RESIDENT.md`（硬预算 6000 字符，行边界截断），通过 `event.systemPromptOptions.sections` 独立挂载，不覆写主系统提示词、不破坏 KV Cache；
- **按需检索**：个人历史与笔记放入 `pi-knowledge`（`0.15.0` + 4 个本地补丁：尾延迟优化、markdown 真实行号 span、边界复核加固、`tree-sitter-qmljs` 可选依赖）；
- **安全边界**：检索与常驻记忆均视为数据而非指令，不可授予执行权限。

---

## 6. 子代理 5 角色分工与 UI 显示

- **角色与模型解耦**：5 个角色文件不硬编码 `model`，通过 `subagents.defaultModel`（`{{MODEL_EXEC}}`）和 `agentOverrides`（`analyze`/`review` 用 `{{MODEL_REVIEW}}`）集中分档；最强模型 `{{MODEL_PLAN}}` 不绑定常驻角色，按需在调用时传 `model:`；
- **工具面最小权限**：仅 `implement` 与 `lead` 拥有写权限；`explore` 无 shell；`analyze` 与 `review` 仅只读 + `bash`（带 `rtk.ts` 压缩与 `toolBudget` 护栏）；
- **界面精简**：`pi-compact-tools` 采用 `compact` + `normal` 模式，`edit` 默认展开便于人工审查 diff，其余工具折叠；`pi-subagents` 采用单行摘要 + FleetView 展示，关闭重复的 async widget；`pi-atelier` 保留自定义编辑器/侧栏/底栏。

---

## 7. 其他基础护栏配置

- `retry.provider.timeoutMs: 3600000`、`maxRetries: 0`：避免客户端与 Magpie 网关双层重试叠加放大延迟；
- `compaction` / `branchSummary` 显式声明 `reserveTokens`：防止上游默认值变动引发行为漂移；
- `enableInstallTelemetry: false`、`showCacheMissNotices: true`：关闭遥测，保留缓存未命中提示便于观测成本。
