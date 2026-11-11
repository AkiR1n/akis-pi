# 升级与回滚

原则：**一次只升一个组件，升完立刻验收，验收不过就回滚**。这套配置里多数组件之间有软依赖（Pi ↔ 插件 ↔ MC ↔ 知识库），同时升两个就分不清是谁坏的。

升级前一律先记录基线：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory,macos,magpie > /tmp/akis-pi-doctor-before.txt
cp -p "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/settings.json.bak-$(date +%Y%m%d)"
```

---

## 顺序

1. Pi 本体 → 2. 插件 → 3. Magic Context → 4. pi-knowledge 补丁 → 5. 可选模块（Magpie / ego / pdf-parse）

反过来升（先升底层）只会让中间态更难解释。

---

## 1. Pi 本体

**级别**：`pinned`（测试值见 [../manifest.json](../manifest.json)）。

```sh
pi --version
npm view @earendil-works/pi-coding-agent version    # 看最新
# 官方安装器（跟最新）
curl -fsSL https://pi.dev/install.sh | sh
# 或严格复现某个版本
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@<version>
```

**升级后必查**：

```sh
pi --version
pi --print 'answer with the number of tools you can call directly, and nothing else'
node scripts/doctor.mjs --home "$HOME" --modules core
```

- 工具数应仍在 4–6；如果跳到 50 上下，说明 `codemode.mode` 语义变了（读 release notes 的 codemode 段）。
- `doctor` 会报 `WARN pi version`（本地比 manifest 新），这是预期的。

**回滚**：装回 manifest 里的版本号即可；`npm uninstall -g` 之后重装。managed 安装保留旧 release 目录，可以直接切。

**已知脆弱点**：`pi list` 会**安装**缺失的包。自动化里不要随手跑它。

---

## 2. 插件

**级别**：大多 `pinned`。`pi-atelier`、`pi-compact-tools` 的对象条目里带 `extensions` / `themes` 过滤（`themes: []` 表示不加载主题），升级后要确认 Pi 没把这两个字段丢掉。

```sh
pi install npm:pi-web-access@<new>
pi list
```

**升级后必查**：

- `pi list` 里版本与 `settings.json` 一致；
- 该插件的**工具名**没变（工具名是 `APPEND_SYSTEM.md` 和 `AGENTS.md` 引用的契约；名字一变，路由说明就错了）；
- 显示类插件（compact-tools）升级后看一次实际渲染，折叠规则常常在小版本里变。

**回滚**：`pi install npm:<包>@<旧版本>`。不要用 `pi update` 一把梭：它会把所有包一起动，坏了分不清是谁。

---

## 3. Magic Context

**级别**：`pinned-reason`。

**升级前必须做**：读 release notes 的 **database migration** 段。MC 拥有项目记忆数据库，回滚不是「装回旧包」就完事——旧版本可能读不了新 schema。

```sh
cp -a "$HOME/.config/cortexkit/magic-context.jsonc" "$HOME/.config/cortexkit/magic-context.jsonc.bak"
# 存储目录默认在 ~/.local/share/cortexkit/magic-context；自定义时看 MAGIC_CONTEXT_STORAGE_DIR
cp -a <storage-dir> <storage-dir>.bak-$(date +%Y%m%d)
pi install npm:@cortexkit/pi-magic-context@<new>
```

**升级后必查**：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory
```

三个参数仍必须是 400000 / 3000 / 600000；多入口时每份配置都要一致。

**回滚**：装回旧版 + 恢复 `.bak` 存储目录。**先停 Pi 再动存储**，否则 WAL 会和副本打架。

---

## 4. pi-knowledge 补丁

**级别**：`pinned`（base + 3 个补丁）。补丁是「搜索/更新尾延迟」「markdown chunk 真实 source span」「复核修复」，作者行已改写为通用身份。

要跟随上游时：

```sh
cd "$HOME/.pi/vendor/pi-knowledge"
git fetch origin && git log --oneline 558e8dd..origin/main
# 逐个补丁 rebase 或重新生成；不要手工把冲突改到「能编译」就收工
npm ci && npm run build
```

**判据**：跑一次真实索引 + 一次查询，比较耗时与命中位置；补丁的价值就在这两处。冲突后手工改过的补丁等于新补丁，要在提交信息里写清改了什么。

**回滚**：`git checkout 558e8dd && npm ci && npm run build`（干净 base 一定可用）。知识库数据在补丁之外，不受影响；但索引格式若被新补丁改过，需要重建索引。

---

## 5. 可选模块

- **Magpie**：升级 app 后**重启 Pi**（MCP 元数据启动时缓存），`pi mcp list` 核对工具面。hub 只列 web-search 是正常的（请求头过滤），不是升级失败。
- **ego lite**：升级后跑一次需要登录态的搜索技能，确认窗口能正常关闭；`ego-gc` 只看 `pgrep 'ego lite'`，app 不运行时它什么都不做。
- **pdf-parse**：升级 PyMuPDF 后重启服务（`launchctl kickstart -k gui/"$(id -u)"/com.example.pipdfparse`），再 `curl --noproxy '*' http://127.0.0.1:8791/health`。
- **agent-browser**：mise 装了新的 24.x 之后**必须**重新确认它还在同一个 node 树里（见 DEPLOY.md 10.4）。这是最容易被静默破坏的一环。

---

## 6. 什么时候不要升级

- 手上正在做一个长链路任务：等它结束。
- MC 有 database migration 而你没有存储备份：先备份。
- 只有一个失败点没查清（例如某个工具时好时坏）：先查清，升级会把它藏起来。
- 版本 `pinned-reason` 且理由还成立（例如「升级前查 migration」）——理由没消失就不升。
