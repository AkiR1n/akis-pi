# akis-pi

一份可以直接交给 AI 的 Pi 配置包：把 `config/` 和所选 `modules/` 渲染到你的机器，然后用 `scripts/doctor.mjs` 自检。
不是插件市场，也不是 dotfiles 备份——这里只有经过长期运行、并写出取舍理由的那部分配置。

作者：Aki。问题请直接开 issue；仓里不含任何个人数据，见文末「刻意不收录」。

## 这套配置在解决什么

1. **模型每轮看到的东西要少。** 工具走 codemode 单一通道，默认只声明 4–6 个工具；其余 50 多个经 `await tools.<name>()` 调用。首轮提示实测 **-45%**（探针 25,522 → 13,954 token）。
2. **主会话只做决策。** 发现、实现、复核分给不同角色、不同模型；便宜模型跑执行，另一种模型复核，更强的模型做规划。
3. **记忆分层。** 每轮只注入几百字符的「常驻事实」；其余靠检索。会话压缩（historian）有明确的触发阈值与超时。
4. **联网有回退链。** 搜索/抓取按顺序降级，403 反爬有第二跳，需要登录态才交给浏览器。

收益与代价都写在 [docs/decisions.md](docs/decisions.md)：例如 codemode only 首轮省 45%，但多步任务总 token 约 **+17%**（模型要写脚本）；这是刻意的交换，不是免费午餐。

## 模块

| 模块 | 内容 | 需要装吗 |
| --- | --- | --- |
| **core** | `settings.json`、全局 `AGENTS.md`、`APPEND_SYSTEM.md`、8 个子代理角色、2 个 prompt 模板、compact-tools 显示配置、pi-web-access 搜索配置、rtk bash 重写扩展 | 必装 |
| **memory** | Magic Context（项目记忆 + 压缩）、resident-memory 扩展、pi-knowledge 知识库与 3 个补丁 | 想跨会话记忆再装；只想要工具面就跳过 |
| **macos** | herdr 面板状态扩展、ego-browser 窗口回收、本地 PDF→Markdown 端点、Keychain 凭据用法 | 只在 macOS 上用；Linux 跳过 |
| **magpie** | Magpie 网关接入：本地 OpenAI 兼容 provider、MCP hub、生图/生视频 | 跳过也完全可用；跳过时把模型指向任意 OpenAI 兼容供应商 |

模块之间只有两处硬耦合，渲染脚本会处理：`settings.json` 里的 pi-knowledge 与 MC 包条目属于 memory 模块；`APPEND_SYSTEM.md` 里 Magpie 与 `ctx_*` 的相关行已标注「仅 X 模块」。

## 模型：三个角色，不是三个 id

模板里所有模型位置都是占位符，不是某个具体模型：

| 占位符 | 角色 | 怎么选 |
| --- | --- | --- |
| `{{MODEL}}` | 主会话默认模型 | 你日常用的那个 |
| `{{MODEL_EXEC}}` | 便宜执行：测试、脚手架、前端、批量改动 | 单价最低、能连续跑脚本的模型 |
| `{{MODEL_REVIEW}}` | 独立复核：读 diff、挑证据漏洞 | 与执行模型**不同族**，避免同源盲区 |
| `{{MODEL_PLAN}}` | 规划/架构/后端关键改动 | 你最信任的强模型 |
| `{{MODEL_HISTORIAN}}` | 会话压缩（memory 模块） | 长上下文 + 便宜，压缩质量要求不高 |

我自己是这样分工的：执行用最便宜的、复核换一个供应商、规划用最强的那档。换成你的三个 id 即可，角色边界不用动——它是整套委派体系的前提。

角色文件名（`impl-*`、`opus-*`、`planner`…）是历史命名，不代表只能用某个厂商的模型；真正生效的只有每个角色 md 里的 `model:` 字段。

## 测试过的版本

| 组件 | 版本 | 级别 |
| --- | --- | --- |
| Pi | 1.5.2 | pinned（严格复现命令见 DEPLOY.md） |
| Node | 24.21.0（mise） | pinned-reason（`node/24` 别名会漂移） |
| rtk | 1.1.0 | pinned-reason（需要 ≥ 0.23.0 的 `rewrite`） |
| Magic Context | 0.49.50 | pinned-reason（升级前查 database migration） |
| pi-knowledge | 0.12.0 + 3 补丁 | pinned |
| 验证环境 | macOS 27.2.1 / arm64 | 只在这台机器上实测 |

完整清单（每个插件的来源、版本、模块、级别、`lastVerified`）在 [manifest.json](manifest.json)，它由导出脚本从真实安装里读出来，不是手写的。

Linux 没有实测。core 与 memory 的组件都是纯 JS 包，理论上能装；macos 模块天然不适用。别把「理论上」当「已验证」。

## 目录

```
akis-pi/
├── AGENTS.md        给 AI 的部署规则（先读它，再读 DEPLOY.md）
├── DEPLOY.md        分步部署：做什么 → 检查命令 → 期望结果 → 失败怎么办
├── manifest.json    组件、版本、模块、级别、平台
├── config/          模板：settings、AGENTS、APPEND_SYSTEM、compact-tools、subagent、agents/*.md、prompts、web-search
├── extensions/      rtk.ts（bash 命令重写）
├── skills/          pi-workflow-notes（写多步 workflow 前必读）
├── modules/
│   ├── memory/      Magic Context 配置、resident-memory.ts、RESIDENT 模板、pi-knowledge 补丁
│   ├── macos/       herdr / ego-gc / pdf-parse / Keychain
│   └── magpie/      magpie.ts、mcp.json.example、路由说明
├── scripts/
│   ├── render.mjs   渲染到部署机（默认 dry run，写前备份并出 diff）
│   └── doctor.mjs   只读自检：PASS/WARN/FAIL
└── docs/
    ├── decisions.md 这些参数背后的取舍与实测数字
    └── upgrade.md   升级 Pi / 插件 / MC / 知识库补丁的顺序与回滚点
```

## 三步上手

```sh
# 1) 先把仓库交给你的 AI，让它读 AGENTS.md（部署规则）和 DEPLOY.md（分步步骤）
# 2) 自己跑一遍 dry run，看清它会写哪些文件、改了哪些行
node scripts/render.mjs --home "$HOME" --modules core \
  --set PROVIDER=your-provider --set MODEL=your-main-model \
  --set MODEL_EXEC=... --set MODEL_REVIEW=... --set MODEL_PLAN=...

# 3) 确认后写入，再自检
node scripts/render.mjs --home "$HOME" --modules core --apply
node scripts/doctor.mjs --home "$HOME" --modules core
```

`render.mjs` 不覆盖 `mcp.json`、不写 `RESIDENT.md`、不删任何文件；已有目标先备份到 `<agent-dir>/backups/akis-pi-<时间戳>/`。

## 刻意不收录

这份仓库的边界是有意的，不是因为忘了：

- **凭据**：没有 `auth.json`、`models.json`、`mcp-auth.json`、`secrets/`、任何 API key 或 Keychain 明文。模板里只有 `{{BRAVE_KEY_REF}}` 这类**引用**，形如 `!printenv VAR` 或 `!security find-generic-password ...`。
- **会话与记忆内容**：没有 sessions、没有 RESIDENT 正文、没有知识库数据。只给格式与取舍规则（`modules/memory/RESIDENT.template.md`）。
- **个人与本地组件**：具体见 [manifest.json](manifest.json) 的 `excluded` 段（本地清理工具、私有工作流引擎、显示层补丁、个人技能），以及 `neverCopied` 段（凭据、会话、机器 id、网关配置）。
- **维护体系本身**：那套「快照 + 检查 + 更新」脚本属于作者这台机器，不在包里。这里只包含它们的结论。

导出脚本内置两道闸：密钥形状与个人信息命中**任何一处**，整份导出都会被拒绝并且非零退出。所以这个仓库能被扫，也是因为它已经通过了扫描。

## 已知不足

- Linux 未实测；Windows 不在范围内。
- `scripts/doctor.mjs` 只在「所有包都已安装」时才调用 `pi list`。Pi 1.5.2 的 `pi list` 会顺手装缺失的包，只读自检不能有副作用。
- macos 模块的 Keychain 用法是「约定」而不是「配置」：服务名由你自己起，医生脚本只检查它有没有被模板引用。
- 这份配置假设你愿意接受 `defaultProjectTrust: "always"`（不再逐次询问项目信任）。不想要就改成 `ask`，代价是每次进新项目多点一次确认。
- 再跑一次导出脚本只会改动 `manifest.json` 的 `generatedAt`（其余文件逐字节相同）。那行 diff 就是「上次导出时间」，不需要处理。
- 首轮提示的节省有两个实测值（-39% 与 -45%，不同时间的探针），见 [docs/decisions.md](docs/decisions.md)；别把它们混用或线性外推。
