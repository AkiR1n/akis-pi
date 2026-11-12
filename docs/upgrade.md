# 升级与回滚

原则：**一次只升级一个组件，升级后立即验收，验收未通过立即回滚**。这套配置中多数组件之间存在依赖或协作关系（Pi ↔ 插件 ↔ Magic Context ↔ 知识库），若同时升级多个组件，出现异常时将难以定位问题源头。

升级前务必先保存基线状态与配置文件：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory,macos,magpie > /tmp/akis-pi-doctor-before.txt
cp -p "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/settings.json.bak-$(date +%Y%m%d)"
```

---

## 推荐升级顺序

1. Pi 本体 → 2. 插件 → 3. Magic Context → 4. pi-knowledge 补丁 → 5. 可选外部模块（Magpie / ego / pdf-parse）

建议由底层核心向上层逐步推进，避免在底层状态不稳定时排查上层问题。

---

## 1. Pi 本体

**版本策略**：`pinned`（已测试基线版本详见 [manifest.json](../manifest.json)）。

```sh
pi --version
npm view @earendil-works/pi-coding-agent version    # 查看最新发布版本
# 官方安装器（更新到最新）
curl -fsSL https://pi.dev/install.sh | sh
# 或严格复现某个固定版本
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@<version>
```

**升级后必查**：

```sh
pi --version
pi --print 'answer with the number of tools you can call directly, and nothing else'
node scripts/doctor.mjs --home "$HOME" --modules core
```

- 直接可见工具数应保持在 4–6 个区间（若骤增至 50 左右，说明 `codemode.mode` 配置解析可能发生了变更，需查阅对应版本的更新日志）。
- `doctor` 脚本若提示 `WARN pi version`（本地版本高于 manifest 记录），属于正常预期提示。

**回滚方案**：重新安装 manifest 中记录的指定版本即可；可通过 `npm uninstall -g` 后重新安装。若使用官方 managed 目录安装，通常保留了历史 release 目录，可直接切换引用。

**注意事项**：运行 `pi list` 时若检测到配置声明了缺失插件，会自动触发安装。避免在未完成依赖确认的自动化流水线中随意调用。

---

## 2. 插件

**版本策略**：多数标为 `pinned`。其中 `pi-atelier`、`pi-compact-tools` 在配置中包含 `extensions` / `themes` 过滤声明（例如 `themes: []` 用于禁用自带主题），升级插件后需确认配置中的过滤项未被重置覆盖。

```sh
pi install npm:pi-web-access@<new>
pi list
```

**升级后必查**：

- `pi list` 输出中安装的版本需与 `settings.json` 中的配置保持一致；
- 插件导出的**工具名称**未发生变化（工具名称属于 `APPEND_SYSTEM.md` 和 `AGENTS.md` 的调用契约；工具更名会导致路由规则失效）；
- 涉及 UI 渲染的插件（如 compact-tools）升级后需在交互终端实际查看渲染效果，其折叠规则可能随小版本更新变动。

**回滚方案**：执行 `pi install npm:<包名>@<旧版本号>`。避免使用全局批量更新命令，一次性升级全部包会导致故障难以归因。

---

## 3. Magic Context

**版本策略**：`pinned-reason`。

**升级前必须确认**：仔细阅读新版本的更新说明中关于 **database migration**（数据库结构迁移）的章节。Magic Context 拥有独立的持久化项目记忆数据库，一旦新版本执行了破坏性结构迁移，仅退回旧版本 npm 包可能导致旧版本无法解析新数据库。

```sh
cp -a "$HOME/.config/cortexkit/magic-context.jsonc" "$HOME/.config/cortexkit/magic-context.jsonc.bak"
# 存储目录默认位于 ~/.local/share/cortexkit/magic-context；若自定义了路径可查看 MAGIC_CONTEXT_STORAGE_DIR
cp -a <storage-dir> <storage-dir>.bak-$(date +%Y%m%d)
pi install npm:@cortexkit/pi-magic-context@<new>
```

**升级后必查**：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory
```

确认三大核心阈值参数依然生效（400000 / 3000 / 600000）；若存在多个配置入口，所有配置均需同步核验。

**回滚方案**：降级安装回原版本包，并将已备份的数据库目录还原回原路径。**操作存储目录前务必先退出 Pi 进程**，避免 SQLite WAL 模式产生并发写入冲突。

---

## 4. pi-knowledge 补丁

**版本策略**：`pinned`（固定上游 commit base + 3 个性能与精确定位补丁）。补丁内容包含「搜索与更新尾延迟优化」「markdown chunk 真实 source span 行号对齐」以及「边界复核修复」，提交身份已规范为通用格式。

跟进上游仓库变更时的操作：

```sh
cd "$HOME/.pi/vendor/pi-knowledge"
git fetch origin && git log --oneline 558e8dd..origin/main
# 逐个补丁进行 rebase 或重新 cherry-pick 生成，遇到冲突需审阅代码逻辑，切勿仅为编译通过而忽略改动语义
npm ci && npm run build
```

**验收判据**：在一个小型代码仓库中实际执行一次全量索引与一次检索，验证耗时是否平稳、命中的代码行号是否准确。如果因代码冲突手工调整了逻辑，需在变更记录中明确写明改动内容。

**回滚方案**：切换回已验证的提交点：`git checkout 558e8dd && npm ci && npm run build`（验证过的 base 代码可随时复现）。本地已有知识库数据保存在源码仓库外部，不受构建影响；但如果新代码变更了向量索引存储格式，可能需要重新建立索引。

---

## 5. 可选外部模块

- **Magpie 网关**：网关应用升级后**需彻底重启 Pi**（MCP 工具元数据仅在 Pi 启动阶段加载缓存），运行 `pi mcp list` 核对工具面。注意：Hub 端点在 Node fetch 环境下仅列出搜索工具属于正常安全过滤机制，并非集成故障。
- **ego lite 浏览器**：升级后需运行一次跨平台搜索技能，确认任务结束后浏览器窗口能够正常触发回收；`ego-gc` 基于检测 `ego lite` 进程运行，应用未启动时该扩展会自动跳过。
- **pdf-parse 服务**：更新 PyMuPDF 等 Python 依赖后，需通过 launchctl 重启服务：`launchctl kickstart -k gui/"$(id -u)"/com.example.pipdfparse`，随后调用 `curl --noproxy '*' http://127.0.0.1:8791/health` 检查接口连通性。
- **agent-browser**：如果通过 mise 安装了新的 Node 24.x 版本，**必须**重新核验全局 CLI 依然链接在当前的 Node 解析树中（详见 DEPLOY.md 步骤 10.4），避免运行环境路径偏移导致工具调用失败。

---

## 6. 暂缓升级的情形

遇到以下情况时建议延后升级操作：
- 当前正在执行长任务或跨模块的大型工作流：建议等待当前任务全部交付归档。
- Magic Context 发布了数据库底层迁移且尚未完成存储冷备份：必须先完成数据备份。
- 系统中尚有未定位原因的异常报警（如某项工具偶尔超时）：应先查明当前问题，避免版本升级引入更多不确定性。
- 组件处于 `pinned-reason` 锁定状态，且对应的锁定理由依然有效（如特定原生依赖的版本兼容要求）。
