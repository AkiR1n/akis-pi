# 部署

每一步都是四段：**做什么 → 检查命令 → 期望结果 → 失败怎么办**。一步一验，不要跳步合并。
core 必装；memory / macos / magpie 按需，每块都能单独装、单独回滚。

先读 [AGENTS.md](AGENTS.md)：那里是给 AI 的硬规则（不覆盖已有配置、密钥只问用户、失败就停）。
版本依据在 [manifest.json](manifest.json)，参数理由在 [docs/decisions.md](docs/decisions.md)。

---

## 0. 前置检查

**做什么**：确认平台与已有安装。

```sh
uname -sm; echo "HOME=$HOME"
command -v pi && pi --version
command -v node && node --version
command -v git && git --version
```

**期望**：macOS arm64 或 Linux x86_64/arm64；`HOME` 非空。`pi` 可能不存在（那就是干净安装）；已有 `pi` 时记下版本。

**失败怎么办**：

- 已有 `pi` 但版本 ≠ 1.5.2：照第 2 步二选一，**不要**混装（见 2 的说明）。
- 已有 `~/.pi/agent/settings.json`：先 `cp -p ~/.pi/agent/settings.json ~/.pi/agent/settings.json.before-akis-pi`，并让用户确认可以改动。**不要**在没有备份的情况下继续。

---

## 1. Node 24.21.0（推荐 mise）

**做什么**：

```sh
curl https://mise.run | sh          # 已有 mise 就跳过
mise use -g node@24.21.0
node --version
```

**期望**：`v24.21.0`。

**失败怎么办**：用任意包管理器装到 24.21.x 也可以，但要把 `config/settings.json` 里 `npmCommand` 的 `mise exec node@24.21.0` 改成你的实际路径，或者整段删掉 `npmCommand`（回退到普通 npm）。**注意**：mise 的 `node/24` 别名会指向最后一次装的 24.x，不要依赖它——第 10 步的 agent-browser 就踩过这个坑。

---

## 2. 装 Pi（两种方式，选一个）

**做什么（A：官方安装器，装最新）**：

```sh
curl -fsSL https://pi.dev/install.sh | sh
pi --version
```

**做什么（B：严格复现 1.5.2，测试过的版本）**：

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.2
pi --version
```

**期望**：A 得到 ≥ 1.5.2 的最新版；B 精确得到 `1.5.2`。两者的后续步骤相同。

**失败怎么办**：

- A 装上的是更新的版本，而 `doctor.mjs` 报 `WARN pi version`：这是**预期**的。不要为此降级，先按新版跑一遍；真出问题再回到 B。
- 两种方式不要同时用：managed 安装（A）在 `~/.pi/agent/install/releases/` 下，全局 npm 在 node 的 `lib/node_modules` 下，`PATH` 会决定谁生效，混装时行为不确定。
- `pi --version` 找不到命令：检查 `PATH` 是否包含 `~/.pi/agent/bin`（A）或 `$(npm prefix -g)/bin`（B）。

---

## 3. models.json：任意 OpenAI 兼容供应商

**做什么**：新建 `~/.pi/agent/models.json`（**不要**提交进任何仓库，也不要从别处拷贝带 key 的文件）。最小示例：

```json
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "{{PROVIDER}}": {
      "baseUrl": "https://api.example.com/v1",
      "api": "openai-completions",
      "apiKey": "!printenv PI_PROVIDER_KEY",
      "models": [
        {
          "id": "{{MODEL}}",
          "name": "Main",
          "reasoning": true,
          "cost": { "input": 0.5, "output": 1.5, "cacheRead": 0.05, "cacheWrite": 0.5 },
          "contextWindow": 200000,
          "maxTokens": 32000
        },
        {
          "id": "{{MODEL_EXEC}}",
          "name": "Exec",
          "cost": { "input": 0.1, "output": 0.3, "cacheRead": 0.01, "cacheWrite": 0.1 },
          "contextWindow": 128000,
          "maxTokens": 16000
        },
        {
          "id": "{{MODEL_REVIEW}}",
          "name": "Review",
          "cost": { "input": 0.5, "output": 1.5, "cacheRead": 0.05, "cacheWrite": 0.5 },
          "contextWindow": 200000,
          "maxTokens": 32000
        },
        {
          "id": "{{MODEL_PLAN}}",
          "name": "Plan",
          "cost": { "input": 1, "output": 3, "cacheRead": 0.1, "cacheWrite": 1 },
          "contextWindow": 200000,
          "maxTokens": 32000
        }
      ]
    }
  }
}
```

`cost` 是必填项（USD / 百万 token），写成你的真实价格，否则用量统计是假的。`apiKey` 三种合法写法：字面值（不推荐）、`$ENV_VAR`、`!command` 输出。**只把 key 放在环境变量或钥匙串里**。

装了 magpie 模块时，`magpie.ts` 会自己注册图片与分类模型；chat 模型仍由 `models.json`（或 Magpie 自己写的目录）提供，两者不冲突。

**做什么（检查）**：

```sh
pi --models '*' --print 'reply with the single word ok' 2>&1 | head -5
```

**期望**：能列出模型并回 `ok`（或至少不报 “no models”）。

**失败怎么办**：`pi auth --help` 与 `pi --help` 里对 `--provider/--model` 的说明优先；`openai-completions` 不适用于 `responses` 风格接口时改 `api` 字段。仍然不行就先只配一个模型（`{{MODEL}}`），把其余占位符先填成同一个 id，等跑通再拆。

---

## 4. 渲染 core

**做什么**：先 dry run，把输出（会写哪些文件、哪些占位符还没填）给用户看，确认后再 `--apply`。

```sh
node scripts/render.mjs --home "$HOME" --modules core \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'

# 看清楚了再写
node scripts/render.mjs ... --apply
```

**期望**：dry run 打印每个文件的 `create` / `unchanged` / `differs from line N`，并且 `WARNINGS` 为空。`--apply` 之后目标文件出现在 `$HOME/.pi/agent/`（以及 `$HOME/.pi/web-search.json`）。

**失败怎么办**：

- 有 `unresolved {{PLACEHOLDER}}`：补 `--set`。**不要**手工编辑模板文件绕过（模板是导出脚本的产物）。
- 目标已存在且 diff 很大：先看 `<agent-dir>/backups/akis-pi-<时间戳>/` 里的备份，逐文件确认要哪个版本。`AGENTS.md` 与 `APPEND_SYSTEM.md` 会**替换**全局指令，覆盖前一定让用户读过。
- 想只装一部分：`--modules core` 之外的模块文件不会被写；反过来说，不要手工把别的模块文件拷进 `extensions/`。

---

## 5. 装插件

**做什么**：`config/settings.json` 里 `packages` 已经写好固定版本，装对应的包：

```sh
pi install npm:pi-web-access@0.47.0
pi install npm:pi-agent-browser-native@0.9.18
pi install npm:pi-atelier@0.18.0
pi install npm:pi-ask-user@0.17.2
pi install npm:pi-powerpoint@1.0.0
pi install npm:pi-subagents@0.88.0
pi install npm:pi-compact-tools@0.17.0
pi install npm:pi-mobile@0.4.0
pi install npm:@injaneity/pi-computer-use@0.5.1
pi install npm:pi-away@0.1.4
pi install npm:pi-prompt-suggestion@0.1.2
```

装出来的 `settings.json` 条目会与模板一致（`pi-atelier`、`pi-compact-tools` 的 `extensions` / `themes` 过滤要保留；`themes: []` 表示「这个包不加载主题」，不是冗余）。

**检查**：

```sh
pi list
```

**期望**：列出 11 个包，路径都在 `~/.pi/agent/npm/node_modules/` 下，没有 “(filtered)” 之外的异常。

**失败怎么办**：

- `pi list` 报缺包：**它会顺手安装**（1.5.2 实测）。所以自检脚本默认不跑它，见第 12 步。
- 版本与你装的不一致：`pi list` 显示的是 settings 里的声明；实际版本看 `~/.pi/agent/npm/node_modules/<包>/package.json`。两者不一致时以磁盘为准，并把 `settings.json` 改成磁盘版本（或反过来重装）。
- 某个包装不上（网络/私有源）：先跳过它，继续后面的步骤，但在交付里明确列出「缺哪个、影响什么」。

---

## 6. 搜索与密钥

**做什么**：把 key 放进环境变量或系统钥匙串，然后让 `web-search.json` **只引用、不含值**。

macOS 钥匙串写法：

```sh
security add-generic-password -a "$USER" -s pi-web-access-brave -w   # 交互输入 key，不进 shell 历史
# 模板里的引用形如：
# "braveApiKey": "!security find-generic-password -a \"$USER\" -s pi-web-access-brave -w"
```

环境变量写法：`export BRAVE_API_KEY=...`，模板里写 `!printenv BRAVE_API_KEY`。

**检查**：

```sh
node -e 'const c=require(process.env.HOME+"/.pi/web-search.json");console.log(Object.keys(c));console.log(/^\{\{|^!/.test(c.braveApiKey||"")?"ref-ok":"LITERAL-VALUE")'
```

**期望**：键包含 `searchRouting`、`fetchRouting`、`pdf`；凭据字段是 `!` 或 `{{` 开头（引用），不是明文。

**失败怎么办**：

- pi-web-access 读的是 `~/.pi/web-search.json`（没有设 `PI_CODING_AGENT_DIR` 时的 legacy 路径），**不是** `~/.pi/agent/` 下。放错位置表现为「搜索工具不可用」。
- 改完 `searchRouting` 必须重启 Pi（扩展进程内缓存），`/reload` 不一定够。
- 没有 Brave/Bocha 也能跑：删掉对应 key 字段即可，`searchRouting.providers` 会降到剩下的 provider（`exa → gemini → degoog`）。eyeball 一下顺序，别留一个永远失败的 provider 在第一位。

---

## 7. 子代理角色

**做什么**：core 已经渲染了 8 个角色到 `~/.pi/agent/agents/`，以及 `~/.pi/agent/extensions/subagent/config.json`。角色 md 的 `model:` 是第 4 步填的角色占位符，`extensions: {{AGENT_DIR}}/extensions/rtk.ts` 是同一个 rtk 扩展。

**检查**：

```sh
grep -h '^model:' ~/.pi/agent/agents/*.md | sort | uniq -c
pi --print 'delegate nothing; just list the subagent roles you can call' 2>&1 | tail -20
```

**期望**：`model` 只有 3–4 种值，且都不是 `{{...}}`；主会话能报出角色名。

**失败怎么办**：

- 看到 `{{MODEL_...}}`：第 4 步没填，回到第 4 步重新渲染（`doctor.mjs` 也会 FAIL 这一项）。
- 角色没被识别：确认文件在 `~/.pi/agent/agents/`（不是 `subagents/`）——pi-subagents 扫描的是 `agents/`。旧版目录名是历史遗留。
- 子代理跑不起来且报模型错：它的模型 id 必须在 `models.json` 里存在，**且**主会话的 provider 一致；换供应商时三个角色都要改。

---

## 8. 第一次启动验收

**做什么**：新开一个 Pi 会话（不要用旧会话验收）。

```sh
pi --print 'answer with the number of tools you can call directly, and nothing else'
```

**期望**：数字在 4–6 之间（codemode only 的模型面）；系统提示里不再有 50 多个工具声明。

**失败怎么办**：

- 数字是 50 上下：`codemode.mode` 没生效。确认 `~/.pi/agent/settings.json` 里有 `{"codemode":{"mode":"only"}}`，然后退出重启（`/reload` 会重建 runtime，但为对比干净请重启）。
- 0 个工具：插件没装上（第 5 步）或 Pi 版本过旧。

---

## 9. memory 模块（可选）

### 9.1 Magic Context

**做什么**：

```sh
pi install npm:@cortexkit/pi-magic-context@0.49.50
# 配置：modules/memory/magic-context.jsonc -> ~/.config/cortexkit/magic-context.jsonc
```

`settings.json` 里已经有这个包条目；`magic-context.jsonc` 由第 4 步的 `--modules core,memory` 渲染到 `$HOME/.config/cortexkit/magic-context.jsonc`。

三个关键参数（不要在没读理由的情况下改）：

| 参数 | 值 | 为什么 |
| --- | --- | --- |
| `execute_threshold_tokens.default` | 400000 | 绝对阈值；模型窗口更小时 MC 自己钳到 90% |
| `memory.injection_budget_tokens` | 3000 | 注入预算；1000 时几乎只剩标题 |
| `historian_timeout_ms` | 600000 | 压缩不是快任务；180000 会大量超时且白付两次重试 |

**检查**：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory
```

**期望**：`magic context parameters` 与 `magic context package` 都是 PASS；只有一个配置文件时 `magic context consistency` 是 WARN（正常，没有第二份可比）。

**失败怎么办**：

- 有多个入口（例如再挂一套 profile）：把每份配置都改到同样三个值，再用 `--mc-profile <dir>` 让医生脚本比对；不一致的配置会产生「有时记得有时不记得」的错觉。
- MC 存储位置默认在 `~/.local/share/cortexkit/magic-context`；要换目录用 `MAGIC_CONTEXT_STORAGE_DIR`（必须是绝对路径），在启动 Pi 的 shell 里设，不要写进仓库。
- 升级 MC 前**必须**读 release notes 的 database migration 段：它拥有项目记忆数据库，回滚不是换回旧包就完事。

### 9.2 resident-memory

**做什么**：第 4 步已经把 `modules/memory/resident-memory.ts` 渲染到 `~/.pi/agent/extensions/resident-memory.ts`（自动加载，无需 settings 条目）。它每轮注入 `~/.pi/agent/memory/RESIDENT.md`，硬上限 `PI_RESIDENT_MEMORY_BUDGET`（默认 6000 字符），文件不存在就什么都不注入。

**做什么（写你自己的一份）**：

```sh
cp "$HOME/.pi/agent/memory/RESIDENT.template.md" "$HOME/.pi/agent/memory/RESIDENT.md"
$EDITOR "$HOME/.pi/agent/memory/RESIDENT.md"   # 只写稳定的、可核对的事实
```

**检查**：会话里执行 `/resident-memory`，看它打印**实际注入**的文本与预算占用。

**期望**：几百到两三千字符；出现 `truncated` 说明你写得太长，删到只剩会改变行为的条目。

**失败怎么办**：`PI_RESIDENT_MEMORY_OFF=1` 可关闭注入（压缩任务就是用它避免自我注入）。读取失败会有 error 通知——那说明文件权限或编码坏了，不要当成「没有记忆」。

### 9.3 pi-knowledge + 补丁

**做什么**：

```sh
mkdir -p "$HOME/.pi/vendor" && cd "$HOME/.pi/vendor"
git clone https://github.com/nczz/pi-knowledge
cd pi-knowledge && git checkout 558e8dd
for p in /path/to/akis-pi/modules/memory/patches/*.patch; do git am "$p" || { git am --abort; break; }; done
npm ci && npm run build
```

补丁是 3 个提交：搜索/更新的尾延迟优化、markdown chunk 的真实 source span、以及针对前两个的复核修复。作者行已改写成通用身份。

**检查**：

```sh
ls "$HOME/.pi/vendor/pi-knowledge/dist/index.js"
node -e 'console.log(require(process.env.HOME+"/.pi/vendor/pi-knowledge/package.json").version)'
pi list | grep pi-knowledge
```

**期望**：`dist/index.js` 存在；版本 `0.12.0`；`pi list` 里有一行 `{{HOME}}/.pi/vendor/pi-knowledge`（模板已指向该路径）。

**失败怎么办**：

- `git am` 冲突：说明你的 base 不是 `558e8dd`，或者上游改了同样的行。`git am --abort` 后回到干净 checkout，**不要**手工解决后继续（补丁会越修越偏）。
- 想跳过补丁：可以，但要接受原本的 O(n³) 去重与「未变更文件也重算 embedding 输入」的开销。先跑一次大库索引再决定。
- 知识库数据不在这个仓库里。要建库按 pi-knowledge 自己的 README 做；不要把它指向 `~/.pi/agent/memory/`（那里是 resident 记忆，属于另一套）。

---

## 10. macos 模块（可选）

### 10.1 herdr 面板状态

```sh
node scripts/render.mjs --home "$HOME" --modules core,macos --apply   # 渲染 herdr-agent-state.ts 与 ego-gc.ts
```

`herdr-agent-state.ts` 由 herdr 生成并管理，重装 herdr 会覆盖它；它只在 `HERDR_ENV=1`、`HERDR_SOCKET_PATH`、`HERDR_PANE_ID` 都存在时才发消息，否则完全不活动。装完在 herdr 里跑一次 Pi，看状态是否随会话变化。

### 10.2 ego 窗口回收

`ego-gc.ts` 在会话结束/启动时清理 ego-browser 留下的 task space（每个都是真实浏览器窗口）。它只在 `ego lite` 已运行时才动手，绝不主动拉起 app；`PI_EGO_GC=off` 关闭，`PI_EGO_GC_DEBUG=1` 打日志到 `/tmp/pi-ego-gc.log`。

ego-browser / ego-search 技能属于第三方 app，**不在这个仓库里**。装 ego lite 后由它自己安装技能；本仓库只提供那个回收扩展。不装 ego 时把 `ego-gc.ts` 从 extensions 里删掉即可（对其它功能无影响）。

### 10.3 本地 PDF→Markdown 端点

```sh
node scripts/render.mjs --home "$HOME" --modules core,macos --apply  # 已写 server.py / requirements.txt / plist
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/com.example.pipdfparse.plist"
curl --noproxy '*' http://127.0.0.1:8791/health
```

**期望**：`{"ok": true}`。pi-web-access 的 `pdf.provider: "auto"` 链是「本地端点 → Gemini → unpdf」；本地端点返回 422（扫描版）时自动落到 OCR。

**失败怎么办**：

- 端口占用：改 `PI_PDF_PARSE_PORT` 与 `web-search.json` 的 `pdf.endpointUrl`，两处必须一起改。
- 不想常驻：`launchctl bootout gui/"$(id -u)"/com.example.pipdfparse`，并把 `pdf.provider` 改成 `auto` 保留——端点不可用时链会自动跳过它。
- plist 里的路径是 `{{HOME}}` 渲染的绝对路径；移动目录后要重装 plist（launchd 不展开 `~`）。

### 10.4 agent-browser 与 mise 别名漂移

```sh
npx --yes agent-browser@0.41.2 --version || npm install -g agent-browser@0.41.2
$(npm prefix -g)/bin/agent-browser --version
```

扩展经 `mise exec node@24` 解析 node，而 `node/24` 指向最后一次安装的 24.x。**CLI 必须装在同一个 node 树里**，否则报 `could not be validated`。装上新的 24.x 之后重新确认一次。这不是美观问题：漂移后浏览器工具直接不可用。

---

## 11. magpie 模块（可选）

**做什么**：装 Magpie app 并打开它，然后把 `modules/magpie/mcp.json.example` 里的两个 server **合并**进 `~/.pi/agent/mcp.json`（如果已经存在，只加缺的条目，不要整体替换）。

```sh
pi mcp list           # 用 Pi 自己的视图核对，不要用 curl
```

**期望**：Pi 侧能看到 `magpie-web-search__web_search` / `__web_fetch`（hub）与 `generate_image` / `generate_video` / `generation_result`（独立 stdio server）。

**两个必须知道的坑**（`modules/magpie/README.md` 有完整说明）：

1. **hub 按请求头过滤**：请求带 `Sec-Fetch-Mode: cors` 或浏览器 UA 时只列 web-search 两个工具。Pi 的 Node fetch 自带该头，所以经 hub 永远只有 2 个；用 curl/Python 直连看到的 6 个不代表 Pi 能用。需要图片工具就单独配 stdio server（模板已配）。
2. **需要斜杠命令的技能必须 direct**：`/skill:...` 一类手动技能（保存话题、写个人笔记那种）如果被路由进 hub 的技能索引，Pi 就不再注册对应命令。这类技能保持直连，不要图省事全部路由。

**失败怎么办**：

- `pi mcp list` 里没有 magpie：MCP 元数据在启动时缓存，装了新 server 要重启 Pi。
- 生图工具在但不出图：先 `n: 1` 试一张，再用 `generation_result` 轮询；失败信息通常在 Magpie 自己的日志里。
- 没有 Magpie 也不想装：把 `models.json` 的 `baseUrl` 指到你自己的网关即可；`APPEND_SYSTEM.md` 里 Magpie 相关行都标了「仅 Magpie 模块」，可以整段删。

---

## 12. 收尾自检与回滚点

**做什么**：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,memory,macos,magpie
```

**期望**：`0 FAIL`。WARN 允许存在，但每一条都要能解释（例如「pi 版本比测试版新」「只有一个 MC 配置」）。

**失败怎么办**：

- 先看 FAIL 的 label：`packages resolve on disk` → 回第 5 步；`placeholders resolved` → 回第 4 步；`magic context parameters` → 回 9.1；`<module> files` → 回对应模块。
- 直到 FAIL 清零再收工。WARN 写进交付说明。

**回滚**：

```sh
# 配置：渲染时自动备份
ls ~/.pi/agent/backups/akis-pi-*/
cp -p ~/.pi/agent/backups/akis-pi-<stamp>/.pi/agent/settings.json ~/.pi/agent/settings.json

# 插件：逐个移除（settings.json 里的条目也要删）
pi remove npm:pi-away@0.1.4

# Pi 本体（用 B 方式装的）
npm uninstall -g @earendil-works/pi-coding-agent
```

回滚顺序建议：先停掉新增扩展（把文件移出 `extensions/`），再退插件，最后退 Pi。升级路径与回滚点见 [docs/upgrade.md](docs/upgrade.md)。
