# akis-pi

一份可以直接交给 AI 部署的 Pi coding agent 配置包：将 `config/` 和所选 `modules/` 渲染到目标机器，再通过 `scripts/doctor.mjs` 进行全项自检。
这不是插件市场，也不是 dotfiles 备份——这里只收录作者日常在用、并写明了设计取舍与实测依据的那部分配置。

作者：Aki。问题与建议请直接提交 Issue。

## 是什么

Pi 是一款轻量、灵活的 coding agent 工具 harness。默认情况下，随着安装的工具插件增多，模型每轮对话看到的系统提示与工具 schema 会急剧膨胀，容易导致首轮延迟高、上下文浪费严重，且在多代理协作时缺乏明确的角色边界与记忆管理。

akis-pi 针对上述问题提供了一套开箱即用的系统化解决方案：
1. **单一工具通道（codemode only）**：默认仅向模型暴露 3 个直接工具（`codemode`、`ask_user`、`tool_search`），其余 50 多个扩展工具全部收敛到 QuickJS 沙箱内部按需发现并以 `await tools.<name>()` 调用。首轮提示实测降低 **-45%**（探针实测从 25,522 降至 13,954 token）。
2. **多角色分工委派**：主会话专注规划与决策，将脚手架构建、测试、代码审查分发给不同定位的模型（便宜模型跑执行，异构模型做独立复核，强模型把控规划与架构）。
3. **分层记忆机制**：每轮会话仅注入几百到两千字符的「常驻事实」（`RESIDENT.md`）；海量项目历史与笔记下沉到按需检索；超长会话由压缩机制（Magic Context historian）按明确阈值与超时控制归档。
4. **弹性联网降级链**：检索与正文抓取按顺序逐级兜底，遇到 403 反爬时按规则改用第二条抓取通道，仅在需要登录态时移交浏览器。

## 适合谁 / 不适合谁

**适合**：
- 希望降低 Pi 提示词开销、减少工具 schema 干扰的重度使用者。
- 追求职责隔离，希望通过「多模型配合（廉价执行 + 异构复核 + 强力规划）」提升代码质量的开发者。
- 需要跨会话持久记忆、长会话无缝压缩，同时严格控制上下文污染的人。
- 使用 macOS 且需要本地 PDF 解析或浏览器自动化清理的人。

**不适合**：
- 希望一键无脑安装、完全不愿配置模型供应商与 API 凭据的人。
- 习惯所有工具 schema 全部常驻提示词、排斥写脚本式调用的使用习惯。
- 纯 Linux / Windows 环境使用者（目前仅在 macOS arm64 环境实测验证，Linux 缺乏环境实测，Windows 不在支持范围内）。

## 快速开始

这套配置推荐交给部署用的 AI 自动化安装（先让 AI 遵循 [AGENTS.md](AGENTS.md) 规则并逐步执行 [DEPLOY.md](DEPLOY.md)）。如果你选择手动部署，核心步骤如下：

```sh
# 1. 运行 dry run，预览将写入的文件、差异 diff 以及占位符解析情况
node scripts/render.mjs --home "$HOME" --modules core --strict \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'

# 2. 确认无误后应用渲染
node scripts/render.mjs --home "$HOME" --modules core --strict --apply \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'

# 3. 按照 DEPLOY.md 安装所需插件及依赖，最后运行只读自检
node scripts/doctor.mjs --home "$HOME" --modules core
```

`render.mjs` 不会覆盖 `mcp.json`、不写 `RESIDENT.md`、不删除任何文件。写入前会自动将目标备份至 `<agent-dir>/backups/akis-pi-<时间戳>/targets/<绝对目标路径去掉根斜杠>`，包括 agent-dir 外的目标：

| 模块 | agent-dir 外的写入路径 |
| --- | --- |
| core | `$HOME/.pi/web-search.json` |
| memory | `$HOME/.config/cortexkit/magic-context.jsonc`（MC 配置） |
| macos | `$HOME/.local/share/pi-pdf-parse/server.py`、`requirements.txt`（PDF 服务源码） |
| macos | `$HOME/Library/LaunchAgents/com.example.pipdfparse.plist` |

此外，`<agent-dir>/.akis-pi-render.json` 会记录已完成的模块；后续追加渲染新模块时，后加 memory 只会安全合并 packages 依赖，完整保留用户现有的 core 配置和自定义修改。严格模式在写入前整体拒绝未解析占位符；非严格模式也不会写入含占位符的文件。JSON/JSONC 替换按字符串转义，`*ApiKey` / `apiKey` 只接受 `!command` 或 `$ENV_VAR` / `${ENV_VAR}` 引用，明文凭据会被直接拦截拒绝。自定义 agent-dir 或 XDG 路径详见 [DEPLOY.md](DEPLOY.md) 第 0 步。

仓库内回归测试可运行：`node --test scripts/test/*.test.mjs`。无真实 key 验收可使用仅监听本地 127.0.0.1 的 `scripts/stub-provider.mjs`，隔离验证步骤详见 DEPLOY 文末。

## 模块

| 模块 | 内容 | 安装建议 | 详细说明 |
| --- | --- | --- | --- |
| **core** | `settings.json`、全局 `AGENTS.md`、`APPEND_SYSTEM.md`、8 个子代理角色、2 个 prompt 模板、compact-tools 显示配置、pi-web-access 搜索配置、rtk bash 重写扩展 | 必装 | 基础运行面 |
| **memory** | Magic Context（项目记忆 + 压缩）、resident-memory 扩展、pi-knowledge 知识库及 3 个关键补丁 | 推荐（需要跨会话持久记忆时安装；仅需精简工具面可跳过） | [modules/memory](modules/memory/README.md) |
| **macos** | herdr 面板状态扩展、ego-browser 窗口回收、本地离线 PDF→Markdown 端点、Keychain 凭据用法 | 推荐（macOS 用户安装；Linux 环境跳过） | [modules/macos](modules/macos/README.md) |
| **magpie** | Magpie 网关接入：本地 OpenAI 兼容 provider、MCP hub、生图/生视频扩展 | 可选（使用 Magpie 网关时启用；跳过时可直接对接任意 OpenAI 兼容供应商） | [modules/magpie](modules/magpie/README.md) |

模块之间仅有两处依赖解耦处理，渲染脚本已自动支持：`settings.json` 中的 pi-knowledge 与 Magic Context 包条目归属 memory 模块；`APPEND_SYSTEM.md` 中关于 Magpie 与 `ctx_*` 的规则行已明确标注「仅 X 模块」。

## 模型分工：三个角色，不是固定 ID

模板中所有模型位置均为占位符，不绑定任何特定供应商或商业模型：

| 占位符 | 角色定位 | 选取建议 |
| --- | --- | --- |
| `{{MODEL}}` | 主会话默认模型 | 日常主力交互模型 |
| `{{MODEL_EXEC}}` | 廉价执行：测试、脚手架、前端、批量改动 | 单价极低、能够稳定连续执行脚本的模型 |
| `{{MODEL_REVIEW}}` | impl-sol 与独立复核：查阅 diff、排查证据漏洞、关键改动核验 | 建议与执行模型**不同族/不同供应商**，避免同源认知盲区 |
| `{{MODEL_PLAN}}` | 架构规划、后端核心改动、难题攻关 | 能力最强的旗舰模型 |
| `{{MODEL_HISTORIAN}}` | 会话压缩归档（memory 模块） | 上下文窗口大、价格低廉，对深度推理要求不高 |

推荐分工原则：执行分配给低单价高响应速度的模型；复核换用异构供应商模型；规划交由最强模型把关。只需将其映射为你拥有的模型 ID 即可，角色职责边界保持不变——这是整套委派协作体系的基石。

角色文件名（如 `impl-*`、`opus-*`、`planner` 等）为历史命名，并不限制只能使用某一特定厂商；实际生效的仅为各角色配置文件中的 `model:` 字段。

## 设计取舍摘要

整套配置背后的每一次设计调整均有明确依据，详情见 [docs/decisions.md](docs/decisions.md)：

- **codemode only**：首轮系统提示字符大幅削减，固定输入开销下降 45%；但由于模型需要编写 JavaScript 脚本驱动工具，多步复杂任务的总 token（input + cacheRead）约增加 **+17%**。这是用执行期轻微开销换取首轮快速响应与低常驻成本的明确交换。
- **参数错误恢复循环**：不常驻 50+ 工具的完整 schema，而是在 `APPEND_SYSTEM.md` 约定「报错时通过 `describeTool` 查看声明并就地重试」，大幅降低常驻 token 负担。
- **Magic Context 阈值**：将执行压缩阈值设为 400,000 tokens（小窗口自动钳位至 90%），注入预算设为 3,000 tokens，压缩超时设为 600,000 ms，避免小模型过早压缩或长任务重试浪费。
- **紧凑工具输出（compact-tools）**：TUI 界面中默认折叠大多数长日志输出，保持思考摘要与 `edit` 代码改动完全展开，兼顾终端浏览体验与审查效率。

## 限制与未验证

- **操作系统支持**：验证环境为 macOS 27.2.1 / arm64。Linux 环境未经实测（core 与 memory 包含 onnxruntime-node、tree-sitter 等原生编译依赖，需按目标平台单独验证安装与运行时依赖；macos 模块不适用）。Windows 不在支持范围内。
- **自检工具限制**：`scripts/doctor.mjs` 仅执行只读检查，对照 settings 与 node_modules 及 manifest 校验；普通版本偏差提示 WARN，Pi/MC 主版本偏差报告 FAIL。注意：Pi 1.5.2 的 `pi list` 会自动安装缺失包，因此自动化脚本中不调用 `pi list`。
- **项目信任配置**：配置模板默认包含 `defaultProjectTrust: "always"`（不再逐次提示信任项目）。若希望每次确认，可手动改为 `ask`。
- **测量数据局限**：首轮探针数据不代表模型最终任务准确率；两组探针对比时同时调整了引导提示，无法单一归因于 codemode。

## 升级与维护

建议遵循「**一次只升级一个组件，升级后立即运行自检，若有异常迅速回滚**」的原则。各组件依赖关系如下：Pi 本体 → 插件 → Magic Context → pi-knowledge 补丁 → 可选外部模块。

详细升级步骤、备份指南与回滚方案请参考 [docs/upgrade.md](docs/upgrade.md)。

## 仓库目录

```
akis-pi/
├── AGENTS.md        给 AI 的部署规则（执行前必读）
├── DEPLOY.md        分步部署指南：操作 → 检查命令 → 期望结果 → 故障处理
├── manifest.json    组件版本清单、模块归属、锁定级别与平台说明
├── config/          配置模板：settings、AGENTS、APPEND_SYSTEM、compact-tools、subagent、角色、prompts 等
├── extensions/      rtk.ts（bash 常用命令压缩与重写扩展）
├── skills/          pi-workflow-notes（多步工作流编写注意事项）
├── modules/
│   ├── memory/      Magic Context 配置、resident-memory 扩展、RESIDENT 模板、pi-knowledge 补丁
│   ├── macos/       herdr 状态面板、ego-browser 窗口回收、PDF 离线解析端点、Keychain 凭据规范
│   └── magpie/      magpie.ts 扩展、mcp.json.example、路由说明
├── scripts/
│   ├── render.mjs   渲染配置至目标环境（默认 dry run，具备前置备份与 diff 输出）
│   └── doctor.mjs   只读健康体检脚本：PASS / WARN / FAIL
└── docs/
    ├── decisions.md 参数背后的设计取舍与实测数据
    └── upgrade.md   组件升级顺序、验证判据与回滚手册
```
