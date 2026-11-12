# 升级与回滚

原则：**一次只升一个组件，升完立即验收，未通过立即回滚**。组件间存在依赖与协作（Pi ↔ 插件 ↔ Magic Context ↔ 知识库），若同时升多个，出异常难定根因。

升级前先保存基线状态与配置文件（POSIX；Windows 把重定向换成 `Out-File`，`cp` 换成 `Copy-Item`，其余参数相同）：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory,macos,magpie > "$TMPDIR/akis-pi-doctor-before.txt"
cp -p "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/settings.json.bak-$(date +%Y%m%d)"
```


## 推荐升级顺序

1. Pi 本体 → 2. 插件 → 3. Magic Context → 4. pi-knowledge 补丁 → 5. 可选外部模块（Magpie / ego / pdf-parse）

建议从底层核心向上推进，避免底层不稳时排查上层问题。


## 平台差异

同一套判据，四个平台的差异只在下面几处，其余命令两端一致：

| 项 | macOS | Linux / WSL2 | 原生 Windows（试验） |
| --- | --- | --- | --- |
| 入口 | POSIX | POSIX（WSL 内） | PowerShell 5.1/7，不用 `&&` |
| 凭据 | `$VAR` 或 Keychain `!command` | 只有 `$VAR` | `setx` 后写 `$VAR`；`!command` 由 Git Bash 执行 |
| Pi 命令解析 | 直接执行 | 直接执行 | doctor 把 `pi.cmd` 解析为 `node.exe + CLI`，交互终端能跑不代表脚本能跑 |
| 数据位置 | `~/…` | WSL 内必须留在 `/home`，不要 `/mnt/c` | `%USERPROFILE%\…`，MC 配置仍在 `.config`，不是 APPDATA |
| memory native runtime | 包内预编译文件 | 安装前 `export ONNXRUNTIME_NODE_INSTALL=skip`（CPU，跳过默认 CUDA 下载） | 先装 VC++ 2015-2022 x64 可再发行组件（管理员） |
| 备份映射 | POSIX 相对路径 | 同左 | `drive-C/`、`unc/server/share`，跨盘不碰撞 |
| PDF 服务重启 | `launchctl kickstart -k gui/…` | `systemctl --user restart pi-pdf-parse.service` | 任务计划程序里重启当前用户任务 |
| 文本编码 | UTF-8 | UTF-8 | 读配置兼容 BOM；脚本一律 ASCII（PS 5.1 按 ANSI 读无 BOM 的 .ps1） |

memory 升级后先跑 `node scripts/deploy-check.mjs onnx`，再跑 doctor；两者都要求 native runtime 加载成功。Windows 包存在却报 Win32 126，先查 System32 的 `vcruntime140.dll`、`vcruntime140_1.dll`、`msvcp140.dll`，缺则按 [DEPLOY](../DEPLOY.md) 安装官方可再发行组件，approve/rebuild 不能替代它。Linux x64 缺包时，默认 CUDA 下载器可能因不跟随 302 失败并被 npm 丢弃；在 agent-dir/npm 运行 `ONNXRUNTIME_NODE_INSTALL=skip npm install --include=optional` 再检查，CPU 文件已在包中。GPU 路径未实测。

未实测平台跑 doctor 会对每个组件多出 platform verification WARN，这是标签，不要解释成故障，也不要为了消掉 WARN 改 manifest。当前实测范围是 macOS arm64 全部模块、WSL2 的 core+memory；Linux 原生、原生 Windows，以及各平台的 pdf 与 magpie 仍属未实测。


## 1. Pi 本体

**版本策略**：`pinned`（测试基线版本见 [manifest.json](../manifest.json)）。

```sh
pi --version
npm view @earendil-works/pi-coding-agent version    # 查看最新发布版本
# 官方安装器（更新到最新）
curl -fsSL https://pi.dev/install.sh | sh
# 或严格复现某个固定版本
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@<version>
```

**升级后检查**：

```sh
pi --version
pi --print 'answer with the number of tools you can call directly, and nothing else'
node scripts/doctor.mjs --home "$HOME" --modules core
```

- 直接可见工具数应在 4–6 个（若骤增到 50 左右，说明 `codemode.mode` 配置解析可能有变，需看对应版本的更新日志）。
- `doctor` 脚本若提示 `WARN pi version`（本地版本高于 manifest 记录），属于正常预期。

**回滚方案**：重装 manifest 中记录的指定版本；可通过 `npm uninstall -g` 后重装。若用官方 managed 目录安装，通常保留了历史 release 目录，可直接切换引用。

**注意事项**：运行 `pi list` 时若检测到配置声明了缺失插件，会自动触发安装。不要在未确认依赖的流水线中随意调用。


## 2. 插件

**版本策略**：多数标为 `pinned`。其中 `pi-atelier`、`pi-compact-tools` 在配置中包含 `extensions` / `themes` 过滤声明（例如 `themes: []` 用于禁用自带主题），升级后需确认配置中的过滤项未被重置覆盖。

```sh
pi install npm:pi-web-access@<new>
pi list
```

**升级后检查**：

- `pi list` 输出的安装版本需与 `settings.json` 保持一致；
- 插件导出的**工具名称**未变（工具名称属于 `APPEND_SYSTEM.md` 和 `AGENTS.md` 的调用契约；改名会导致路由失效）；
- 涉及 UI 渲染的插件（如 compact-tools）升级后需在终端看实际渲染效果，折叠规则可能随小版本变动。

**回滚方案**：执行 `pi install npm:<包名>@<旧版本号>`。不要用全局批量更新命令，一次升全部包会导致故障难以归因。


## 3. Magic Context

**版本策略**：`pinned-reason`。

升级前确认：仔细阅读新版本说明中关于 **database migration**（数据库结构迁移）的章节。Magic Context 拥有独立的持久化项目记忆数据库，一旦新版本有破坏性结构迁移，仅退回旧版 npm 包可能导致旧版无法解析新数据库。

```sh
cp -a "$HOME/.config/cortexkit/magic-context.jsonc" "$HOME/.config/cortexkit/magic-context.jsonc.bak"
# 存储目录默认位于 ~/.local/share/cortexkit/magic-context；若自定义了路径可查看 MAGIC_CONTEXT_STORAGE_DIR
cp -a <storage-dir> <storage-dir>.bak-$(date +%Y%m%d)
pi install npm:@cortexkit/pi-magic-context@<new>
```

**升级后检查**：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory
```

确认三大核心阈值参数依然生效（400000 / 3000 / 600000）；若有多处配置入口，均需同步核验。

**回滚方案**：降级装回原版本包，将备份的数据库目录还原回原路径。操作存储目录前先退出 Pi 进程，避免 SQLite WAL 模式并发写入冲突。


## 4. pi-knowledge 补丁

**版本策略**：`pinned`（固定上游 commit base + 4 份补丁：搜索与更新尾延迟优化、markdown chunk 真实 source span 行号对齐、边界复核修复、QML 可选依赖；提交身份已规范为通用格式）。

跟进上游仓库变更时的操作：

```sh
cd "$HOME/.pi/vendor/pi-knowledge"
git fetch origin && git log --oneline 558e8dd..origin/main
# 逐个补丁进行 rebase 或重新 cherry-pick 生成，遇到冲突需审阅代码逻辑，不要仅为编译通过而忽略改动语义
npm ci && npm run build
```

**验收判据**：在小代码仓库中实际跑一次全量索引与检索，验证耗时是否平稳、命中的代码行号是否准确。若因冲突手动调整了逻辑，需在变更记录中写明改动内容。

**回滚方案**：切回已验证的提交点：`git checkout 558e8dd && npm ci && npm run build`（验证过的 base 代码可随时复现）。本地知识库数据保存在源码仓库外，不受构建影响；但若新代码改了向量索引存储格式，可能需要重建索引。


## 5. 可选外部模块

- **Magpie 网关**：网关应用升级后需重启 Pi（MCP 工具元数据仅在 Pi 启动时加载缓存），运行 `pi mcp list` 核对工具面。注意：Hub 端点在 Node fetch 下仅列出搜索工具属于正常安全过滤，并非故障。
- **ego lite 浏览器**：升级后跑一次跨平台搜索技能，确认任务结束后浏览器窗口能正常回收；`ego-gc` 检测 `ego lite` 进程，未启动时扩展会自动跳过。
- **pdf-parse 服务**：服务属于独立 pdf 模块。macOS 用 `launchctl kickstart -k gui/"$(id -u)"/com.example.pipdfparse`，Linux/WSL 用 `systemctl --user restart pi-pdf-parse.service`，Windows 在任务计划程序中重启当前用户任务；然后检查回环 /health。具体步骤与旧状态迁移见 [modules/pdf](../modules/pdf/README.md)。
- **agent-browser**：若通过 mise 安装了新的 Node 24.x 版本，需重新核验全局 CLI 依然链接在当前 Node 解析树中（详见 DEPLOY.md 步骤 10b），避免路径偏移导致工具调用失败。


## 6. 暂缓升级的情形

遇到以下情况建议延后升级：
- 当前正在跑长任务或跨模块工作流：建议等当前任务全部交付归档后再升。
- Magic Context 发布了数据库底层迁移且尚未完成存储冷备份：先完成数据备份。
- 系统中尚有未定位原因的异常报错（如某项工具偶尔超时）：先查明当前问题，避免版本升级引入更多不确定性。
- 组件处于 `pinned-reason` 锁定状态，且对应的锁定理由依然有效（如特定原生依赖的版本兼容要求）。



<system-reminder>
58 spent tool outputs (~45k tokens) are reclaimable. Make a ctx_reduce pass now over the outputs you've already used, then continue.
oldest reclaimable: §1098§ subagent · §1100§ codemode · §1101§ subagent · §1103§ subagent_supervisor.
</system-reminder>

## Node 版本

本包钉 Node 24.22.3。不要用 24.19.0–24.21.x：这几个版本里，pi-knowledge 的 better-sqlite3 在垃圾回收时释放 Statement 会触发 Node 内部断言，进程以 SIGABRT 退出（上游 nodejs/node#65446，24.22.0 已修复）。WSL2 上启用 memory 时，24.21.0 跑 20 轮有 9 轮崩溃，24.22.3 为 0；数据库完整性检查在崩溃轮次也正常。macOS 上的 better-sqlite3 预编译件不走这条路径，所以 macOS 上不容易看到这个问题，但仍按同一版本钉。升级 Node 时先查该版本是否包含上游修复，再在 Linux 或 WSL2 上跑 memory 组合的回归（`tests/wsl/exit-probe.py --rounds 20 --variants memory`，每轮三条 `pi --print`，全部退出码为 0 才算通过）。
