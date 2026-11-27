# 升级、静默触点与回滚手册（Upgrade & Rollback）

本仓库负责初始可复现配置；部署完成后建议在独立的本地维护项目中追踪日常升级与快照回滚。

**核心原则：一次只升一个组件（或按低风险小批次），升前备份，升完立即验收，异常即止损回滚。**

```sh
# 升级前保存基线状态与配置副本
node scripts/doctor.mjs --home "$HOME" --modules core,magpie,memory > "$TMPDIR/akis-pi-doctor-before.txt"
cp -p "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/settings.json.bak-$(date +%Y%m%d)"
```

---

## 1. 推荐升级顺序

1. **Pi 本体**（`pi update` 或 `npm install -g --ignore-scripts @earendil-works/pi-coding-agent@<ver>`）
2. **外部前置 CLI**（如 `agent-browser` CLI 须先升至扩展要求的下限，例如 `pi-agent-browser-native@0.9.46` 要求 `≥0.45.0`）
3. **普通插件**（`pi install npm:<pkg>@<ver>`；注意保留 `pi-atelier` 与 `pi-compact-tools` 的对象式 `extensions`/`themes` 过滤字段）
4. **Magic Context**（升级前必须读 release notes 的 database migration 说明，并先冷备或 SQLite online backup 整个 storage 目录再升级）
5. **`pi-knowledge` 补丁**（大版本跨架构升级如 `0.15.x → 0.16.x` 引入 daemon 与 schema v8 迁移，务必先评估补丁冲突与备份 `knowledge.db` 再决定是否跟进）
6. **外部模块**（Magpie、ego、pdf-parse）

---

## 2. 每次升级后必查的 5 个静默触点

常规 `doctor.mjs` 能查版本与文件存在性，但以下非公开契约失效时往往表现为**静默退化**，升级 Pi、插件或 Node 后建议逐项探针复核：

| # | 触点 | 失效后果 | 快速确认方式 |
| --- | --- | --- | --- |
| 1 | **`@gotgenes/pi-permission-system` AST 规则** | `web-tree-sitter` / `tree-sitter-bash` 异常导致危险命令静默放行 | 在新会话 `pi -p` 中尝试 `rm -r /path/to/nonexistent`，核对 `~/.pi/agent/extensions/pi-permission-system/logs/*.jsonl` 中有 `permission_request.waiting` 且 `matchedPattern` 非空 |
| 2 | **`extensions/rtk.ts` 改写与权限协同** | 命令被改写为 `rtk <cmd>` 后不再命中 `bash` 规则 | 在本地临时仓库测试高危 git 命令，确认日志中 `command` 带 `rtk` 前缀且仍命中对应 `matchedPattern` |
| 3 | **`pi-atelier` 编辑器与侧栏接管** | Pi 仅允许一个自定义编辑器；新版本可能改变底栏/侧栏布局 | 重启新 Pi 会话目视底栏/侧栏与 `Settings → Display` |
| 4 | **`@getpipher/vision` 贴图钩子** | `pi.on("input")` 变更导致贴图退化为纯路径文本 | TUI 中粘贴一张图片回车，确认显示原子标签且模型能识别图内容 |
| 5 | **`pi-knowledge` 补丁与 embedding 兼容** | 升上游丢补丁或 `dist/` 未重编，或破坏现有知识库索引 | `cd ~/.pi/vendor/pi-knowledge && npm test`，并在小库验证检索与行号准确 |

---

## 3. 各组件回滚方式

- **渲染配置回滚**：`render.mjs` 写入前均自动备份到 `<agent-dir>/backups/akis-pi-<时间戳>/targets/`，审阅 `diff` 后单文件 `cp` 还原（不要整目录盲盖）。
- **扩展 / 插件回滚**：先在 `settings.json` 用 `-path` 禁用故障扩展，再用 `pi install npm:<pkg>@<旧版本>` 精确回退。
- **Pi 本体回滚**：重装 `manifest.json` 基准版本（managed 安装通常保留旧 release 目录可切换）。
- **Magic Context 回滚**：退出所有 Pi 进程 → 降级 npm 包 → 将升级前备份的 `storage/`（含 `context.db` 与 WAL）还原回原路径。
- **`pi-knowledge` 回滚**：升级前记下打完 4 补丁后的 `git rev-parse HEAD`，回退时 `git checkout <sha> && npm ci && npm run build`。

---

## 4. 旧会话与新配置

- `settings.json` 在 **Pi 进程启动时**读取，升级核心插件或 MC 后请**退出并重启 Pi 进程**，不要仅依赖 `/reload`。
- `codemode.mode` 与工具面按当前设置动态重算；若旧会话历史中仍残留旧工具用法导致模型习惯性误调，直接新开会话或 `pi --fork` 即可。

---

## 5. 平台差异速查

| 项 | macOS | Linux / WSL2 | 原生 Windows（试验） |
| --- | --- | --- | --- |
| 入口 | POSIX | POSIX（WSL `/home` 内） | PowerShell 5.1/7（不用 `&&`） |
| 凭据 | `$VAR` 或 Keychain `!command` | `$VAR` | `setx` + `$VAR`；`!command` 走 Git Bash |
| `memory` 原生依赖 | 开箱即用 | 安装前设 `ONNXRUNTIME_NODE_INSTALL=skip` 与 `ONNXRUNTIME_NODE_INSTALL_CUDA=skip` | 管理员安装 VC++ 2015–2022 x64 运行库 |
| `onnx` 验收 | `node scripts/deploy-check.mjs onnx` | 同左 | 同左 |
| PDF 服务重启 | `launchctl kickstart -k gui/…` | `systemctl --user restart pi-pdf-parse.service` | 任务计划程序重启 |
