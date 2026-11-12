# akis-pi

来自 AkiyamaRin 的自用 Pi 配置。装完是一套能交给 AI 部署、也能自己读懂每个选择的 Pi 环境。

特色：

- **简单工具通道**：模型直接看到的工具只有 6 个，其余收进沙箱按需发现。
- **子代理分工**：执行用便宜的模型，复核用异构模型，规划用最强的模型。
- **分层记忆**：常驻事实每轮注入，历史与笔记按需检索，长会话自动归档。
- **Magpie 协同**：模型路由、生图、抓取兜底、技能与 MCP 路由都走 Magpie，连 `rtk` 都是它装的；装的时候按必装处理。

欢迎提 issue。

## 介绍

Pi 是个轻量的 coding agent harness。工具插件装多了之后，系统提示与工具 schema 会一起膨胀：首轮变慢，上下文被大量无用信息占掉，模型挑错工具的概率也跟着上升。

这套配置针对的就是这个。最直接的一条是把工具收进沙箱，模型直接看到的从 53 个降到 6 个，首轮提示从 25,522 token 降到 13,954（−45%）；代价是多步任务的总 token 约 +17%，因为它要靠脚本驱动工具。另外三条的取舍与实测数据见 [docs/decisions.md](docs/decisions.md)；模型分工与平台细节见 [docs/reference.md](docs/reference.md)。

### 适合谁 / 不适合谁

**适合**：
- 想降低 Pi 提示词开销、减少工具 schema 干扰。
- 想用多模型分工（廉价执行 + 异构复核 + 强力规划）协作。
- 需要跨会话持久记忆与长会话自动压缩，控制上下文膨胀。
- 用 macOS：macos 模块只在 darwin 提供，顺带拿到 herdr 状态面板与 ego 窗口回收。

**不适合**：
- 想一键安装、不愿配置模型与 API 凭据。
- 习惯工具 schema 全常驻、不习惯写脚本调用。
- 需要开发者对每个平台、桌面插件和原生依赖都给出验收保证。目前的实机记录是 macOS arm64 的全部模块，以及 WSL2 上的 core+memory。

## 安装

### 前置条件

| 项 | 要求 |
| --- | --- |
| Node | 24.22.3 |
| Git | 已安装（原生 Windows 用 Git for Windows） |
| Pi | 1.5.2 |
| Python | 3.9 以上（只有 pdf 模块需要） |
| 模型 | 任意 OpenAI 兼容供应商，至少一个主力模型和一个便宜的批量执行模型 |
| Magpie | 已安装并在运行 |

为什么是这几个版本、缺了会怎样、各平台还要补什么，见 [docs/reference.md](docs/reference.md)。

### 平台支持

| 平台 | 状态 | 可用模块 | 说明 |
| --- | --- | --- | --- |
| macOS arm64 | 已实测 | core、magpie、memory、macos、pdf | 基准平台 |
| WSL2（Ubuntu 24.04 x64） | core、memory 已实测；magpie、pdf 未实测 | core、magpie、memory、pdf | Windows 用户的默认推荐 |
| 原生 Windows x64 | 试验 | core、magpie、memory、pdf | 安装与探针通过；长时间运行、TUI、桌面能力未验 |
| Linux x64 glibc | 试验 | core、magpie、memory、pdf | 由 WSL2 推断，无原生实机 |

支持级别怎么定、Windows 上有哪些取舍、各平台还要补哪些依赖，见 [docs/reference.md](docs/reference.md)。

### 交给 AI 部署

把仓库交给你的 AI，按 [AGENTS.md](AGENTS.md) → [DEPLOY.md](DEPLOY.md) 执行，不要跳步。

装完让它贴两项检查结果：DEPLOY 第 12 节的 doctor 输出，和文末回环验收的抓包结论（工具面 6 个、常驻事实已注入）。只说「装好了」不算完成。

## 模块

| 模块 | 内容 | 安装建议 | 详细说明 |
| --- | --- | --- | --- |
| **core** | `settings.json`、全局 `AGENTS.md`、`APPEND_SYSTEM.md`、5 个子代理角色、2 个 prompt 模板、compact-tools 配置、pi-web-access 搜索配置、rtk bash 重写扩展 | 必装 | 基础运行面 |
| **memory** | Magic Context（项目记忆 + 压缩）、resident-memory 扩展、pi-knowledge 知识库及 4 个补丁（QML 可选） | **必装** | [modules/memory](modules/memory/README.md) |
| **macos** | herdr 状态面板扩展、ego-gc 窗口回收（`ego-browser` 本体各平台都有） | **darwin 必装**；其它平台拒绝选择 | [modules/macos](modules/macos/README.md) |
| **pdf** | 本地 PDF→Markdown 端点；launchd / systemd user / Windows 登录任务说明 | 可选，独立于 macos | [modules/pdf](modules/pdf/README.md) |
| **magpie** | Magpie 网关接入：本地 OpenAI 兼容 provider、MCP hub、生图/生视频、技能与 MCP 路由 | **必装**（模型路由、生图、抓取兜底与 rtk 都经它；只装 Pi 裸件就用不上这套配置） | [modules/magpie](modules/magpie/README.md) |

模块间依赖解耦：`settings.json` 中的 pi-knowledge 与 Magic Context 包归属 memory 模块；`APPEND_SYSTEM.md` 里关于 Magpie 与 `ctx_*` 的规则已标注适用模块。

## 限制与未验证

- **没有权限系统。** 工具直接用 Pi 进程的系统权限执行，不弹确认、也没有白名单；模板还把 `defaultProjectTrust` 设成 `always`，不再逐次询问项目配置。需要限制请自己加：写一个审批 `tool_call` 的扩展，或用容器 / 独立用户隔离。
- **实测范围有限**：macOS arm64 的全部模块、WSL2 的 core+memory 跑过实机；其余平台与模块按上文级别看。子代理改成 5 个角色后只在本机 macOS 验证过。
- **探针数字不是任务准确率**：首轮提示降 45% 只说明固定开销变小，那两次探针还同时改过引导提示，不能只算在 codemode 头上。
- **自检有边界**：`doctor.mjs` 只读 settings、node_modules 与 manifest，不调用 `pi list`、不安装包。
- **CLI 要单独装**：agent-browser 的 CLI 与浏览器不在包内；默认用普通 npm，不写 `npmCommand`。

## 升级与维护

这个仓库只负责初始配置。装好之后，升级、回滚、插件增删都是你自己环境的事：建议单独建一个维护项目，把当前版本、升级步骤、验收命令与回滚点记在里面，不要回头改这个包。

包里只给规则和工具：`manifest.json` 记着每个组件锁到哪个版本，[docs/upgrade.md](docs/upgrade.md) 是一份照着做就行的升级与回滚手册，`doctor.mjs` 用来验收。组件依赖是 Pi 本体 → 插件 → Magic Context → pi-knowledge 补丁 → 外部模块（Magpie 必装，ego / pdf 按需），一次只升一个。

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
│   ├── macos/       herdr 状态面板、ego-gc 窗口回收（仅 darwin）
│   ├── pdf/         PDF 唯一源码与各平台服务启动适配
│   └── magpie/      magpie.ts 扩展、mcp.json.example、路由说明
├── scripts/
│   ├── render.mjs   渲染配置至目标环境（默认 dry run，具备前置备份与 diff 输出）
│   └── doctor.mjs   只读健康体检脚本：PASS / WARN / FAIL
├── tests/
│   ├── windows/     原生 Windows 实机测试：宿主驱动 run.ps1 + 虚拟机内 guest-deploy.ps1
│   └── wsl/         WSL2 实机测试：run.sh 在一次性副本发行版内跑 POSIX 入口
└── docs/
    ├── reference.md  版本、依赖与平台支持背后的原因
    ├── decisions.md 参数背后的设计取舍与实测数据
    └── upgrade.md   组件升级顺序、验证判据与回滚手册
```
