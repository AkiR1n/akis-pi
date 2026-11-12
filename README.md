# akis-pi

一份可以直接交给 AI 部署的 Pi coding agent 配置包：把 `config/` 和所选 `modules/` 渲染到目标机器，再用 `scripts/doctor.mjs` 逐项检查。
它不是插件市场，也不是 dotfiles 备份，只收录作者日常在用、写明了取舍与实测依据的那部分配置。

作者：Aki。问题与建议请直接提交 Issue。

目录：[这是什么](#这是什么装完得到什么) · [适合谁](#适合谁--不适合谁) · [平台支持](#平台支持) · [前置条件](#前置条件) · [快速开始](#快速开始) · [回滚](#回滚) · [模块](#模块) · [模型分工](#模型分工三个角色不是固定-id) · [设计取舍](#设计取舍摘要) · [限制与未验证](#限制与未验证) · [升级与维护](#升级与维护)

## 这是什么，装完得到什么

Pi 是个轻量的 coding agent harness。工具插件装多了之后，系统提示与工具 schema 会一起膨胀，首轮变慢，上下文被无用信息占掉。

akis-pi 针对这四点做了调整，装完得到的是：

1. **单一工具通道（codemode only）**：Pi 1.5.2 + pi-subagents 0.88.0 下向模型暴露 6 个工具（`ask_user`、`codemode`、`contact_supervisor`、`subagent`、`subagent_supervisor`、`tool_search`），其余 50 多个扩展工具收进 QuickJS 沙箱，按需发现并用 `await tools.<name>()` 调用。首轮提示实测降低 **-45%**（探针从 25,522 降至 13,954 token）。
2. **多角色分工**：主会话做规划，把测试、脚手架、代码审查分发给不同定位的模型：便宜模型执行，异构模型复核，强模型把控规划。
3. **分层记忆**：每轮只注入几百到两千字符的常驻事实（`RESIDENT.md`）；项目历史与笔记按需检索；长会话由 Magic Context 按固定阈值与超时归档。
4. **联网分级兜底**：搜索与正文抓取按顺序回退，遇到 403 反爬时换第二条通道，需要登录态时移交浏览器。

## 适合谁 / 不适合谁

**适合**：
- 想降低 Pi 提示词开销、减少工具 schema 干扰。
- 想用多模型分工（廉价执行 + 异构复核 + 强力规划）协作。
- 需要跨会话持久记忆与长会话自动压缩，控制上下文膨胀。
- 用 macOS，需要本地 PDF 解析或浏览器窗口自动清理。

**不适合**：
- 想一键安装、不愿配置模型与 API 凭据。
- 习惯工具 schema 全常驻、不习惯写脚本调用。
- 需要开发者对每个平台、桌面插件和原生依赖都给出验收保证。目前的实机记录只有 macOS arm64 与 WSL2 上的 core+memory。

## 平台支持

macOS arm64 与 WSL2（Ubuntu 24.04 x64）的 core+memory 已完成实机验收，其余平台与模块按下面级别使用。上游支持不等于本包已验证：manifest 的 `platforms` 表示适用平台，`verified` 单独记录实测平台，doctor 在未实测平台会对每个组件报 `WARN`。

| 平台 | 状态 | 可选模块 | 说明 |
| --- | --- | --- | --- |
| macOS arm64 | 已实测 | core、memory、macos、pdf、magpie | 基准平台，探针与部署记录都来自这里 |
| WSL2（Ubuntu 24.04 x64） | core、memory 已实测；pdf、magpie 试验。Windows 用户的默认推荐 | core、memory、pdf、magpie | 走 POSIX 入口；memory 安装前设置 `ONNXRUNTIME_NODE_INSTALL=skip`（CPU）。memory 组合 20 轮、TUI 10 次无异常退出 |
| 原生 Windows x64 | **试验** | core、memory、pdf、magpie | 需 Git for Windows；memory 还需 VC++ 2015-2022 x64 运行库。开发机与全新中文账户机器部署通过；长时间运行、TUI 与桌面能力未验收 |
| Linux x64 glibc | 试验 | core、memory、pdf、magpie | 用户态由 WSL2 实测推断，无原生实机记录；Ubuntu 优先；memory 设置 `ONNXRUNTIME_NODE_INSTALL=skip`；凭据用 `$VAR` |

Windows 用户默认选 **WSL2 的 core+memory**：源码、`node_modules`、Magic Context 数据库与知识库都放在 WSL 的 `/home` 下，不要放 `/mnt/c`（跨文件系统访问慢一个数量级，权限与大小写语义也不同）。只有需要操作 Windows 桌面、或复用 Windows 登录态浏览器时才选原生 Windows。

原生 Windows 是可选的**试验**路径，代价要说清楚：

- Pi 的 shell 依赖 **Git for Windows**；部分镜像的默认执行策略是 Restricted，要按上游说明放开，不要用 Bypass 掩盖问题。
- 浏览器与 Electron 按其上游自述属于 best-effort：会话锁、恢复、退出清理都要单独验收，不能把“能启动”当通过。
- memory 的 onnxruntime-node 需要 **Microsoft Visual C++ 2015-2022 x64 可再发行组件**；缺 DLL 导致的 Win32 126 不能用 npm approve/rebuild 修复。安装与检查见 [DEPLOY](DEPLOY.md)。doctor 会把 onnx 加载失败记为 FAIL。
- `tree-sitter-qmljs` 没有预编译产物。memory 靠第 4 份补丁把它降级为可选依赖：安装或加载失败时 QML 文件退回文本分块并提示一次，其它语言不受影响。
- Herdr/Rex pane、tmux inspector、launchd、Keychain、ego 窗口回收在 Windows 上不提供。

## 前置条件

| 项 | 要求 |
| --- | --- |
| Node | 24.22.3（不要用 24.19.0–24.21.x，原因见 [docs/upgrade.md](docs/upgrade.md) 的 Node 一节） |
| Git | POSIX 自带即可；原生 Windows 需要 Git for Windows，Pi 的 shell 与凭据命令都走它 |
| Pi | 1.5.2（其他版本可能改过扩展接口，见 [docs/upgrade.md](docs/upgrade.md)） |
| Python | 只有 pdf 模块需要，3.9 以上，用于本地 PDF→Markdown 端点 |
| 模型 | 任意 OpenAI 兼容供应商；至少准备一个主力模型和一个便宜的批量执行模型 |

## 快速开始

这套配置推荐交给部署用的 AI 自动化安装（让 AI 遵循 [AGENTS.md](AGENTS.md) 规则并逐步执行 [DEPLOY.md](DEPLOY.md)）。如果你手动部署，核心步骤如下（原生 Windows 用 DEPLOY 的 PowerShell 入口，参数一致、写法按 PowerShell 调整）：

```sh
# 1. 运行 dry run，预览将写入的文件、差异 diff 以及占位符解析情况
node scripts/render.mjs --home "$HOME" --modules core --strict \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='$BOCHA_API_KEY'

# 2. 确认无误后应用渲染
node scripts/render.mjs --home "$HOME" --modules core --strict --apply \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='$BOCHA_API_KEY'

# 3. 按照 DEPLOY.md 安装所需插件及依赖，最后运行只读自检
node scripts/doctor.mjs --home "$HOME" --modules core
```

`render.mjs` 不覆盖 `mcp.json`、不写 `RESIDENT.md`、不删除文件。写入前自动备份目标至 `<agent-dir>/backups/akis-pi-<时间戳>/targets/<目标映射>`（POSIX 去掉根斜杠；Windows 保留 drive-C / drive-D 或 unc/server/share，避免跨盘碰撞），含 agent-dir 外的目标：

| 模块 | agent-dir 外的写入路径 |
| --- | --- |
| core | 搜索配置按上游位置：显式 agent-dir → XDG / agent / legacy 回退；与 doctor 一致 |
| memory | `<XDG_CONFIG_HOME 或 HOME/.config>/cortexkit/magic-context.jsonc`（MC 配置） |
| pdf | `$HOME/.local/share/pi-pdf-parse/server.py`、`requirements.txt`（唯一 PDF 服务源码） |
| pdf | macOS 的 `~/Library/LaunchAgents/com.example.pipdfparse.plist`；Linux/WSL 的 `<config-home>/systemd/user/pi-pdf-parse.service`；Windows 按说明手动建登录任务 |

`<agent-dir>/.akis-pi-render.json` 记录已完成模块。追加渲染 memory 时只合并 packages，保留已有 core 设置。严格模式写入前拒绝未解析占位符；非严格模式跳过含占位符的文件。凭据只接受 `!command` 或 `$ENV_VAR` / `${ENV_VAR}` 引用，明文凭据会被拒绝。自定义路径见 [DEPLOY.md](DEPLOY.md) 第 0 步。

回归测试：`node --test scripts/test/*.test.mjs`。无真实 key 验收见 DEPLOY 文末的回环 stub。

## 回滚

渲染不删除文件，改过的目标在写入前都备份到 `<agent-dir>/backups/akis-pi-<时间戳>/targets/`，路径映射与写入时一致。要退回去，把对应文件复制回原位。

`<agent-dir>/.akis-pi-render.json` 记录已完成模块，删掉对应条目就能重跑同一模块。组件升级与数据库回滚是另一套流程，见 [docs/upgrade.md](docs/upgrade.md)。

## 模块

| 模块 | 内容 | 安装建议 | 详细说明 |
| --- | --- | --- | --- |
| **core** | `settings.json`、全局 `AGENTS.md`、`APPEND_SYSTEM.md`、8 个子代理角色、2 个 prompt 模板、compact-tools 配置、pi-web-access 搜索配置、rtk bash 重写扩展 | 必装 | 基础运行面 |
| **memory** | Magic Context（项目记忆 + 压缩）、resident-memory 扩展、pi-knowledge 知识库及 4 个补丁（QML 可选） | 推荐（需要持久项目记忆时装；仅需精简工具面可跳过） | [modules/memory](modules/memory/README.md) |
| **macos** | herdr 状态面板扩展、ego-browser 窗口回收 | 仅 darwin 可选；其它平台拒绝选择 | [modules/macos](modules/macos/README.md) |
| **pdf** | 本地 PDF→Markdown 端点；launchd / systemd user / Windows 登录任务说明 | 按需，独立于 macos | [modules/pdf](modules/pdf/README.md) |
| **magpie** | Magpie 网关接入：本地 OpenAI 兼容 provider、MCP hub、生图/生视频扩展 | 可选（用 Magpie 网关时启用；跳过可直连任意 OpenAI 兼容服务） | [modules/magpie](modules/magpie/README.md) |

模块间依赖解耦：`settings.json` 中的 pi-knowledge 与 Magic Context 包归属 memory 模块；`APPEND_SYSTEM.md` 里关于 Magpie 与 `ctx_*` 的规则已标注适用模块。

## 模型分工：三个角色，不是固定 ID

模板中所有模型位置均为占位符，不绑定特定供应商或商业模型：

| 占位符 | 角色定位 | 选取建议 |
| --- | --- | --- |
| `{{MODEL}}` | 主会话默认模型 | 日常主力交互 |
| `{{MODEL_EXEC}}` | 廉价执行：测试、脚手架、前端、批量改动 | 单价低、能稳定跑脚本的模型 |
| `{{MODEL_REVIEW}}` | impl-sol 与独立复核：查 diff、排查漏洞、改动核验 | 建议与执行模型**不同族/不同供应商**，减少同源盲区 |
| `{{MODEL_PLAN}}` | 架构规划、后端核心改动、难题攻关 | 最强的旗舰模型 |
| `{{MODEL_HISTORIAN}}` | 会话压缩归档（memory 模块） | 窗口大、价格低，不要求强推理 |

分工原则：执行用低单价高速度模型，复核用异构模型，规划用最强模型。映射为你持有的模型 ID 即可。

角色文件名（如 `impl-*`、`opus-*`、`planner`）是历史命名，不限厂商；实际生效的是各角色配置里的 `model:` 字段。

## 设计取舍摘要

各项设计背后的取舍依据见 [docs/decisions.md](docs/decisions.md)：

- **codemode only**：首轮系统提示字符减少，固定输入开销下降 45%；但由于模型需要写脚本驱动工具，多步任务的总 token（input + cacheRead）约增加 **+17%**。这是用运行时代价换取首轮低成本的取舍。
- **参数错误恢复规则**：不常驻 50+ 工具的完整 schema，而是在 `APPEND_SYSTEM.md` 约定「报错时通过 `describeTool` 查看声明并就地重试」，减少常驻 token 负担。
- **Magic Context 阈值**：将执行压缩阈值设为 400,000 tokens（小窗口自动钳位至 90%），注入预算设为 3,000 tokens，压缩超时设为 600,000 ms，避免过早压缩或长任务重试浪费。
- **紧凑工具输出（compact-tools）**：TUI 界面默认折叠大多数长日志，保持思考摘要与 `edit` 代码修改展开，兼顾终端浏览与人工审查。

## 限制与未验证

- **系统支持**：实测过的是 macOS arm64 与 WSL2（仅 core+memory），平台分级见上文「平台支持」。原生依赖、浏览器会话恢复与桌面 helper 要分别验证，路径单测不算实机证据。
- **npm**：默认不写 npmCommand，使用普通 npm；POSIX 上可显式 `render --mise` 或 `--set USE_MISE=true`。agent-browser CLI 属于 core，须单独安装 CLI 与浏览器。
- **自检工具**：`scripts/doctor.mjs` 只读检查 settings、node_modules 和 manifest；版本偏差报 WARN，Pi/MC 主版本偏差报 FAIL。由于 Pi 1.5.2 的 `pi list` 会自动补装缺包，脚本不调用 `pi list`。
- **项目信任**：模板默认 `defaultProjectTrust: "always"`（不逐次弹窗）。想每次确认可改为 `ask`。
- **探针数据**：首轮探针数据不代表最终任务准确率；两组探针同时调整了引导提示，不能单一归因于 codemode。

## 升级与维护

建议遵循「一次只升级一个组件，升级后立即自检，有异常迅速回滚」的原则。组件依赖关系：Pi 本体 → 插件 → Magic Context → pi-knowledge 补丁 → 可选外部模块。

详细升级步骤、备份与回滚方案见 [docs/upgrade.md](docs/upgrade.md)。

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
│   ├── macos/       herdr 状态面板、ego-browser 窗口回收（仅 darwin）
│   ├── pdf/         PDF 唯一源码与各平台服务启动适配
│   └── magpie/      magpie.ts 扩展、mcp.json.example、路由说明
├── scripts/
│   ├── render.mjs   渲染配置至目标环境（默认 dry run，具备前置备份与 diff 输出）
│   └── doctor.mjs   只读健康体检脚本：PASS / WARN / FAIL
├── tests/
│   ├── windows/     原生 Windows 实机测试：宿主驱动 run.ps1 + 虚拟机内 guest-deploy.ps1
│   └── wsl/         WSL2 实机测试：run.sh 在一次性副本发行版内跑 POSIX 入口
└── docs/
    ├── decisions.md 参数背后的设计取舍与实测数据
    └── upgrade.md   组件升级顺序、验证判据与回滚手册
```
