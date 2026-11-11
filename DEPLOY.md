# 部署

每一步按「做什么 → 检查命令 → 期望结果 → 失败怎么办」执行。先读 [AGENTS.md](AGENTS.md)，版本依据在 [manifest.json](manifest.json)，理由见 [docs/decisions.md](docs/decisions.md)。core 必装，memory / macos / magpie 按需。联网安装前说明，不覆盖用户已有配置，doctor FAIL 时停止。

## 0. 前置检查与路径

在仓库根目录记录绝对路径与所选模块，后面不要丢掉这些变量：

```sh
export REPO="$(pwd)"
# 默认目录；使用自定义目录时改这行
export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
# 本文示例选择 core + memory；跳过 memory 就写 core，可追加 ,macos 或 ,magpie
export MODULES=core,memory
uname -sm; echo "HOME=$HOME"
command -v pi && pi --version
command -v node && node --version
command -v git && git --version
```

期望：macOS arm64 或 Linux x86_64/arm64，HOME 非空，Git 可用；Linux 未实测。已有 Pi 时记下版本，缺 Pi 则在第 2 步安装。已有 settings.json / AGENTS.md / APPEND_SYSTEM.md 必须先备份、审阅 diff、让用户确认再覆盖。

render 与 doctor 的 `--agent-dir` 都需显式传入 `"$PI_CODING_AGENT_DIR"`；不传时默认 HOME/.pi/agent。模板的 `{{AGENT_DIR}}` 会跟随此参数。本文提到的 `~/.pi/agent` 在自定义部署中均换成该目录。搜索配置仍写 `$HOME/.pi/web-search.json`，MC 写 `$HOME/.config/cortexkit/magic-context.jsonc`。使用自定义 XDG_CONFIG_HOME 时需自行备份并移动 MC 配置到实际读取位置（脚本不跟随它）。resident-memory 默认读 HOME/.pi/agent/memory/RESIDENT.md，自定义 agent-dir 时另设 `PI_RESIDENT_MEMORY_FILE="$PI_CODING_AGENT_DIR/memory/RESIDENT.md"`。pi-web-access 的自定义 agent-dir 查找差异见第 6 步。

## 1. Node 24.21.0、npmCommand 与 RTK

推荐使用 mise：

```sh
curl https://mise.run | sh       # 已有 mise 则跳过
mise use -g node@24.21.0
node --version
# 第 2 步前确认模板 npmCommand 的依赖
if command -v mise >/dev/null; then
  /usr/bin/env mise exec node@24.21.0 -- npm --version   # 用 mise：期望打印 npm 版本
else
  node --version && npm --version                          # 不用 mise：走下文「非 mise」分支
fi
```

用 mise 时期望 Node v24.21.0、npm 有版本输出；`command -v mise` 无输出说明你不用 mise，此时 mise 那条命令一定报 `env: mise: No such file or directory`，属于预期，按下面的非 mise 分支处理。模板 npmCommand 通过 mise 调用 npm；隔离 HOME 时 mise 可能重新下载 Node，先运行检查避免把下载误认为插件行为。非 mise 用户运行 `node --version && npm --version`，并在第 4 步 apply 后删除部署目标的 npmCommand（有明确命令），否则 pi install 会报 `env: mise: No such file or directory`。不要用会漂移的 node/24 别名代替精确版本。

安装 core bash rewrite 所需的 RTK，选择一种：

```sh
# Homebrew
brew install rtk
# 非 brew：有 Cargo 时，从 crates.io 安装（两种方式二选一）
cargo install rtk --version 1.1.0 --locked
# 均需检查
rtk --version
rtk rewrite --help
```

期望验证版本 1.1.0，至少支持 ≥0.23.0 的 rewrite。brew 可能给新版，记录差异；缺 RTK 时扩展会放行原 bash，doctor 给 WARN。非 brew / Linux 安装未实测，失败时查包管理器原始输出，不要报告已生效。

## 2. 装 Pi（二选一）

A：官方安装器，安装最新：

```sh
curl -fsSL https://pi.dev/install.sh | sh
pi --version
```

B：严格复现测试版本：

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.2
pi --version
```

期望 B 精确为 1.5.2；A 可能是新版，doctor 对普通偏差 WARN，对 major 变化 FAIL（兼容性需要重新评估）。不要混装 managed 安装与 npm 全局安装；命令缺失时检查 PATH 的 agent-dir/bin 或 npm prefix 的 bin。不要为新版 WARN 自动降级或替换 pinned 组件。

## 3. models.json 与无 key 检查

在 `$PI_CODING_AGENT_DIR/models.json` 新建供应商配置，不复制真实凭据，不替换已有文件。填好以下所有模型占位符；historian 可复用其中一个 id。

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

cost 必填（USD / 百万 token），按真实价格填写。凭据只用 `!command` 或环境变量引用（例如 `$PI_PROVIDER_KEY`）；不要写明文。API 类型要与供应商匹配，responses 风格接口不能直接照用 openai-completions。magpie 模块单独注册图片/分类模型，chat 仍由 models.json 提供。

检查模型目录与扩展加载（不请求模型）：

```sh
pi --list-models > /tmp/pi-models.txt 2> /tmp/pi-models.stderr
cat /tmp/pi-models.stderr
```

期望 exit 0、stderr 为空且目录有你填的模型。唯一允许的 stderr 是 rtk 未装时的一行 `[rtk] rtk binary not found in PATH — extension disabled`：说明 rtk 还没进 PATH，装好后再跑应为空。若报 no models / Failed to load extension，先修配置或扩展。有真实 key 时可额外执行：

```sh
pi --provider '<供应商 id>' --model '<主模型 id>' --print 'reply with the single word ok'
```

期望回 ok；没有 key 时用文末回环 stub 验证第 3、7、8 步。`--offline` 不阻止模型请求，不能用它保证离线。

## 4. 按实际所需模块渲染

先 dry run；MODULES 是第 0 步实际选择，选 memory 时必须包括 core,memory：

```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES" --strict \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'
```

期望每个文件打印 create / unchanged / diff，WARNINGS 为空。审阅所有外部路径与覆盖 diff，用户同意后写入：

```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES" --strict --apply \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'
```

strict 在任何写入前拒绝未解析占位符；非 strict 也警告并跳过含占位符的文件。JSON/JSONC 按字符串规则转义，凭据字段只接受引用。不要用手改导出模板绕过错误。

渲染器将完成模块记到 `<agent-dir>/.akis-pi-render.json`。后续只渲染新增模块，不重写已完成 core，不移除已有模块；后加 memory 时只合并其 packages 到已有 settings，保留其它设置与过滤对象。重复传 core 也不更新它；需要更新已部署模板时先在独立 agent-dir 生成，人工审阅合并，不要删除状态文件冒险覆盖。

写入范围、备份布局见 README；已有目标先备份到 `<agent-dir>/backups/akis-pi-<时间戳>/targets/<绝对目标路径去掉根斜杠>`。不替换 mcp.json、models.json、auth.json、RESIDENT.md。

非 mise 用户在 apply 后、装插件前执行（只改部署副本，不改模板）：

```sh
cp -p "$PI_CODING_AGENT_DIR/settings.json" "$PI_CODING_AGENT_DIR/settings.json.before-npm-command"
node -e 'const fs=require("fs"),p=process.env.PI_CODING_AGENT_DIR+"/settings.json",s=JSON.parse(fs.readFileSync(p));delete s.npmCommand;fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n")'
npm --version
```

检查目标 settings 没有 npmCommand；Pi 将使用普通 npm。若删除失败停止，不要继续插件安装。

## 5. 安装插件（必须先渲染）

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

pi install 在空 settings 中只写字符串条目；资源过滤来自第 4 步渲染，已有过滤对象才会被保留。pi-atelier 的 extensions 与 pi-compact-tools 的 extensions/themes: [] 不能丢。

core-only 且所有声明包均在磁盘上时运行 `pi list`：期望 11 项、路径在 agent-dir/npm/node_modules，pi-atelier 与 pi-compact-tools 显示 `(filtered)`。第 4 步已选 memory 时 settings 声明 13 项，此时只装好 11 项，**暂不运行 pi list**；它会安装缺包，本地 pi-knowledge 尚未构建。等 9.3 完成再检查 13 项。doctor 永远不调用 pi list。

npm 11 的 allowScripts 策略可能跳过 postinstall：警告 install-scripts 不等于安装完全可用。在实际执行 npm 的目录检查：

```sh
cd "$PI_CODING_AGENT_DIR/npm"
npm install-scripts --help
npm install-scripts ls
```

判据：被跳过脚本的包，只要下面的加载/可执行检查通过（多数自带 prebuilt，例如 better-sqlite3、sharp、tree-sitter），就**不需要** approve；不要 `approve --all`。只有检查失败的包才审阅后 approve，approve 不会自动重跑脚本，需要执行 `npm rebuild <包名>`（例如 `npm rebuild @injaneity/pi-computer-use`）。不支持该子命令时检查安装日志与 npm 自己的脚本策略。

至少核验 pi-computer-use：postinstall 实际为 `node scripts/setup-helper.mjs --postinstall`，负责安装 helper，跳过会影响桌面控制。下面只读检查本机 helper 可执行文件；失败则按包 README 审阅并重新运行安装步骤（可能下载/签名，先说明），不要把包已安装当作 helper 可用：

```sh
cd "$PI_CODING_AGENT_DIR/npm/node_modules/@injaneity/pi-computer-use"
node --input-type=module -e 'import fs from "node:fs";import os from "node:os";import path from "node:path";import {resolveMacosHelperAppPath} from "./src/platform/macos/helper-path.mjs";const p=process.platform==="darwin"?path.join(resolveMacosHelperAppPath(),"Contents/MacOS/bridge"):(process.env.PI_COMPUTER_USE_LINUX_HELPER_PATH||path.join(os.homedir(),".pi/agent/helpers/pi-computer-use/linux-bridge"));fs.accessSync(p,fs.constants.X_OK);console.log("helper executable exists:",p)'
```

此命令覆盖 macOS/Linux；未做权限授权与真实桌面操作仍记为未验证。MC（memory 模块）的 onnxruntime-node 检查放在 9.1 装完 MC 之后，见那里。仅 require 成功不代表模型下载或 embedding 推理已验证。tree-sitter 等依赖也可能被跳过，构建/运行检查需记录。安装失败先看原始日志，不要把缺包改成随意新版。

## 6. 搜索与密钥

key 放环境变量或钥匙串，只渲染引用。macOS 示例：

```sh
security add-generic-password -a "$USER" -s pi-web-access-brave -w
# --set BRAVE_KEY_REF='!security find-generic-password -a "$USER" -s pi-web-access-brave -w'
```

上面会交互输入 key，避免 shell 历史。环境变量引用可用 `!printenv BRAVE_API_KEY` / `!printenv BOCHA_API_KEY`。检查两个字段，不打印值：

```sh
node -e 'const c=require(process.env.HOME+"/.pi/web-search.json");console.log(Object.keys(c));for(const k of ["braveApiKey","bochaApiKey"])console.log(k,/^(?:!\S|\$(?:[A-Za-z_]|\{))/.test(c[k]||"")?"ref-ok":"MISSING-OR-LITERAL")'
```

期望 searchRouting/fetchRouting/pdf 存在、两个字段 ref-ok，无残留占位符。引用指向未设置变量时 pi-web-access 的行为**未验证**；不要当作有可用 key。没有 Brave/Bocha 时删掉对应字段与 providers 条目，保留 exa → gemini → degoog 回退。改变 routing 后重启 Pi。

pi-web-access 0.47.0 的源码明确：只要设置 PI_CODING_AGENT_DIR，就读该目录下 web-search.json（即使值等于默认 agent-dir）；未设置时才按 XDG / agent / legacy 查找。本文第 0 步已设置该变量，因此必须将渲染到 legacy 的文件同步到 agent-dir。先预览差异；已有目标确认后先备份，再复制：

```sh
src="$HOME/.pi/web-search.json"
dst="$PI_CODING_AGENT_DIR/web-search.json"
if [ -e "$dst" ]; then diff -u "$dst" "$src"; else echo "create: $dst"; fi
# 审阅且用户确认后执行（仅路径不同才复制）
if [ "$src" != "$dst" ]; then
  if [ -e "$dst" ]; then cp -p "$dst" "$dst.before-search-sync-$(date +%Y%m%d%H%M%S)"; fi
  cp "$src" "$dst"
fi
```

doctor 同时扫描这两个位置的占位符，部署目录变化必须重新验证搜索。第 6 步检查引用时也将路径换为实际读取的 agent-dir/web-search.json。

## 7. 子代理角色

core 渲染 8 个角色、subagent/config.json 和 prompts。检查：

```sh
grep -h '^model:' "$PI_CODING_AGENT_DIR"/agents/*.md | sort | uniq -c
grep -R '{{' "$PI_CODING_AGENT_DIR/agents" "$PI_CODING_AGENT_DIR/prompts"
# core-only 已安装完且有 key 时；选 memory 则等 9.3 完成后再执行：
pi --print 'delegate nothing; just list the subagent roles you can call'
```

期望无占位符，模型包含 inherit 与第 4 步填的角色 id；impl-sol 使用 MODEL_REVIEW，impl-flash 用 MODEL_EXEC，规划角色用 MODEL_PLAN。子代理模型 id 必须在 models.json 存在并使用正确 provider。角色不见时检查 agents/（不是 subagents/）。无 key 用 stub；这只验证请求配置，不验证真实委派质量。

## 8. 第一次启动验收

core-only 现在新开 Pi 会话（不要用旧会话或只看 /reload）。选 memory 时此步先记录命令，等 9.3 的所有包构建完成后再执行；此时启动 Pi 也可能解析/安装缺失包，不能提前用模型请求验收：

```sh
pi --print 'answer with the number of tools you can call directly, and nothing else'
```

期望 **3 个直接工具**：codemode / ask_user / tool_search。pi-compact-tools 把 grep/find 等放入按需发现通道，其余经 tools.<name>() 调用。模型自报数字可能有误，以 stub 捕获的请求 tools 为准。若有约 50 个工具，检查 codemode.mode=only；若为 0，回第 5 步检查插件与 Pi 版本。

## 9. memory 模块（可选，选了才做）

### 9.1 Magic Context

```sh
pi install npm:@cortexkit/pi-magic-context@0.49.50
node -e 'const fs=require("fs"),p=process.env.PI_CODING_AGENT_DIR+"/npm/node_modules/@cortexkit/pi-magic-context/package.json";console.log(JSON.parse(fs.readFileSync(p)).version)'
```

期望 0.49.50，MC 配置已在第 4 步由 core,memory 渲染。此时磁盘 12 个 npm 包、settings 声明 13 项；本地 pi-knowledge 未装，**不运行 doctor 或 pi list，等 9.3 完成再查**。检查第 5 步的 onnxruntime-node 加载。

三个参数：execute_threshold_tokens.default=400000（小窗口钳到 90%）、memory.injection_budget_tokens=3000、historian_timeout_ms=600000。理由见 decisions.md。MC 的 `pi.subagent_extensions: []` 保持 historian 子进程不加载普通扩展。

多入口时用 doctor 的 `--mc-profile <另一份magic-context.jsonc文件>`（文件，不是目录）逐份比较；单一配置 consistency WARN 是正常的。数据默认在 HOME/.local/share/cortexkit/magic-context，可用绝对路径 MAGIC_CONTEXT_STORAGE_DIR 覆盖；升级前读 database migration release notes，不能靠退包回滚数据库。


装完 MC 后核验 onnxruntime-node（本地 embedding 的运行时；MC 是纯 ESM，`require.resolve` 解析不了它的入口，所以从 package.json 建 require）：

```sh
node -e 'const {createRequire}=require("module");const r=createRequire(process.env.PI_CODING_AGENT_DIR+"/npm/node_modules/@cortexkit/pi-magic-context/package.json");console.log(r("onnxruntime-node").env.versions)'
```

期望打印 `{ common: "…", node: "…" }`。这只说明 native runtime 能加载，不代表 embedding 模型已下载或推理可用。tree-sitter 等依赖的跳过脚本按第 5 步的判据处理。

### 9.2 resident-memory

扩展只读 RESIDENT，默认预算 6000 字符。由用户写自己的文件，已存在则停止，不覆盖：

```sh
dst="$PI_CODING_AGENT_DIR/memory/RESIDENT.md"
if [ -e "$dst" ]; then
  echo "exists: $dst; 停止，不覆盖"
else
  cp -n "$PI_CODING_AGENT_DIR/memory/RESIDENT.template.md" "$dst"
fi
```

用户可自行编辑稳定、可核对的事实。检查用交互 TUI 的 `/resident-memory`，会显示实际注入文本和预算；`--print` 下该命令 stdout 为空。脚本验证用 stub 捕获请求，grep `<resident_memory>`。出现 truncated 应精简。PI_RESIDENT_MEMORY_OFF=1 关闭；仅 ENOENT 当空，其它读取错误要修。

### 9.3 pi-knowledge + 补丁

```sh
mkdir -p "$HOME/.pi/vendor" && cd "$HOME/.pi/vendor"
git clone https://github.com/nczz/pi-knowledge
cd pi-knowledge && git checkout 558e8dd
for p in "$REPO"/modules/memory/patches/*.patch; do git am "$p" || { git am --abort; break; }; done
npm ci && npm run build
ls "$HOME/.pi/vendor/pi-knowledge/dist/index.js"
node -e 'console.log(require(process.env.HOME+"/.pi/vendor/pi-knowledge/package.json").version)'
# 现在所有声明包都已安装，才运行
pi list
node "$REPO/scripts/doctor.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules core,memory
```

期望 dist/index.js 存在、版本 0.12.0、pi list **13 项**（11 core + MC + pi-knowledge），保留两个 filtered；此处仅检查 core,memory，doctor 应 0 FAIL；MODULES 中其它模块到第 12 步统一检查。现在再新开 Pi 完成第 7、8 步的动态验收（无 key 用回环 stub），此前的静态检查不能替代它。补丁为尾延迟优化、真实 source span、复核修复三份，作者已匿名化。git am 冲突则停止并检查 base，不要手工绕过。npm 脚本警告按第 5 步检查。真实小库还需建库检索确认命中行；这里仅构建不证明检索质量。不要将知识库指向 resident memory 目录。

## 10. macos 模块（可选）

### 10.1 追加渲染与 herdr

若第 4 步没选 macos，现在只追加 macos，不用重渲染 core/memory：

```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules macos --strict \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'
# 审阅后
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules macos --strict --apply \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='!printenv BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='!printenv BOCHA_API_KEY'
# 同步 MODULES（已含 macos 时不必重复追加）
export MODULES="$MODULES,macos"
```

herdr-agent-state.ts 由 herdr 管理，仅 HERDR_ENV、HERDR_SOCKET_PATH、HERDR_PANE_ID 都存在时工作。检查需在 herdr 中跑 Pi 看面板状态。manifest 的 herdr source 仅是扩展来源描述，没有公开下载 URL，本仓库无法提供经核实的获取链接。

### 10.2 ego 窗口回收

ego-gc.ts 只在 ego lite 已运行时清理窗口，不主动启动 app；PI_EGO_GC=off 关闭、PI_EGO_GC_DEBUG=1 输出日志。ego-browser/ego-search 技能由第三方 app 安装，不在本仓库分发。manifest 的 ego-lite source 是 `external app, not redistributed`，**没有可核实的获取 URL**；请向提供 app 的渠道获取，未取得则跳过该能力，不编造链接。不用时用 settings 的 -path 排除扩展，不删除用户文件。

### 10.3 本地 PDF→Markdown

```sh
# macos 渲染已写 server.py / requirements.txt / LaunchAgent，默认仅回环
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/com.example.pipdfparse.plist"
curl --noproxy '*' http://127.0.0.1:8791/health
```

期望 {"ok":true}。本地端点 → Gemini → unpdf，扫描 PDF 422 走 OCR。端口改动要同步 PI_PDF_PARSE_PORT 与 web-search.json 的 pdf.endpointUrl。停用用 launchctl bootout；launchd 不展开 ~，移动 HOME 后需审阅重装绝对路径 plist。

### 10.4 agent-browser

npx 成功不证明全局 CLI 安装；实际安装并检查：

```sh
npm install -g agent-browser@0.41.2
command -v agent-browser
"$(npm prefix -g)/bin/agent-browser" --version
```

期望 0.41.2 且路径在扩展解析的同一 Node 树。mise node/24 别名会漂移，新增 24.x 后重新确认，否则浏览器工具可能报 could not be validated。获取来源为 manifest 的 npm -g agent-browser。

## 11. magpie 模块（可选）

从 manifest 的 [Magpie source](https://github.com/yetone/magpie) 获取 app 并打开。确保第 4 步已选 magpie（若追加，沿用第 10.1 步完整参数，仅将 --modules macos 改为 magpie 并先 dry run），再将 modules/magpie/mcp.json.example 的两个服务器合并到 agent-dir/mcp.json，不整体替换。

```sh
pi mcp list
```

期望 Pi 看到 hub web_search/web_fetch 与独立 stdio 的 generate_image/generate_video/generation_result。hub 按 Sec-Fetch-Mode: cors / 浏览器 UA 过滤，Pi 的 Node fetch 自带头，所以 curl 看见 6 个工具不证明 Pi 可见。斜杠命令技能必须 direct，不能全部搬到 hub。新增 server 后重启 Pi，生图先 n:1 再轮询 generation_result，失败查 Magpie 日志。完整说明见 modules/magpie/README.md。

## 12. 收尾自检与回滚

只传实际已渲染且完成安装的模块，用第 0 步的 MODULES（core-only 为 core，memory 为 core,memory，追加模块时同步变量）：

```sh
node "$REPO/scripts/doctor.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES"
```

期望 0 FAIL，WARN 逐条解释。doctor 只读 settings/node_modules，**不调用 pi list、不安装包**。对照 manifest：版本相同 PASS；普通偏差 WARN；Pi/MC 的 major 偏差 FAIL；缺声明包 FAIL。settings 与磁盘一起改错仍会被发现。RTK 缺失或无 rewrite 为 WARN。core 11 个包、core+memory 13 个包，macos/magpie 不额外增加 packages。

FAIL packages resolve on disk 回第 5 步（memory 在 9），placeholders 回第 4 步，MC parameters 回 9.1。FAIL 清零才交付。回滚先用 -path 停用新增扩展，再退插件，最后退 Pi；已有文件备份按绝对路径镜像在 targets/ 下，先找到目标再人工恢复：

```sh
find "$PI_CODING_AGENT_DIR/backups" -path '*/targets/*/settings.json'
# 审阅后将找到的备份 cp -p 到 "$PI_CODING_AGENT_DIR/settings.json"
# 插件回滚示例（同时影响 settings）：
pi remove npm:pi-away@0.1.4
```

数据库回滚另看 docs/upgrade.md，不能用配置备份冒充数据恢复。

## 无 key 的本机回环验收

先跑第 3 步 pi --list-models，exit 0 且 stderr 为空，证明目录和扩展没有加载错误。再在**独立临时 HOME 与 agent-dir** 复制本次渲染/安装的非凭据配置，创建仅有 stub provider 的 models.json（不要修改真实配置）。示例内容：

```json
{"providers":{"stub":{"baseUrl":"http://127.0.0.1:8899/v1","api":"openai-completions","apiKey":"dummy","models":[{"id":"stub-model","name":"Stub","cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":200000,"maxTokens":1000}]}}}
```

这是回环 stub 的假值，不是真实凭据。隔离副本的 settings.enabledModels 若仍列出原供应商/其它角色模型，pi --list-models 会给模式未命中的 stderr。只在临时副本里将默认模型与 enabledModels 改成 stub，再运行目录检查：

```sh
# 此时 HOME 与 PI_CODING_AGENT_DIR 必须已经指向独立临时副本
node -e 'const fs=require("fs"),d=process.env.PI_CODING_AGENT_DIR;if(!/^\/(?:private\/)?tmp\//.test(d||""))throw Error("requires temporary agent-dir");const p=d+"/settings.json",s=JSON.parse(fs.readFileSync(p));s.defaultProvider="stub";s.defaultModel="stub-model";s.enabledModels=["stub/stub-model"];fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n")'
pi --list-models > /tmp/pi-stub-models.txt 2> /tmp/pi-stub-models.stderr
cat /tmp/pi-stub-models.stderr
```

期望 stderr 为空。复制的 packages 若含绝对本地路径，需在临时副本中指向隔离构建产物；不要复制 auth.json、真实 models.json 或会话/记忆。独立终端启动仅监听 127.0.0.1 的脚本（日志含系统提示，只保存在临时目录，别提交）：

```sh
node "$REPO/scripts/stub-provider.mjs" --port 8899 --log /tmp/pi-stub-requests.jsonl
# 另一终端，在隔离环境里，明确选 stub，避免调用真实供应商
pi --provider stub --model stub-model --print --no-session 'hi'
# 第 7、8 步的验收同样换成 stub：
pi --provider stub --model stub-model --print --no-session 'delegate nothing; list the subagent roles you can use'
pi --provider stub --model stub-model --print --no-session 'answer with the number of tools you can call directly'
node -e 'const fs=require("fs"),rows=fs.readFileSync("/tmp/pi-stub-requests.jsonl","utf8").trim().split("\n").map(JSON.parse);for(const r of rows){console.log((r.tools||[]).map(t=>t.function?.name));console.log((r.messages||[]).filter(m=>["system","developer"].includes(m.role)).map(m=>m.content).join("\n"))}'
grep '<resident_memory>' /tmp/pi-stub-requests.jsonl
```

期望 stdout stub-ok，tools 为 codemode/ask_user/tool_search，系统提示含已选模块注入（写过用户自己的 RESIDENT 才有 resident_memory）。Ctrl-C 关闭 stub。这只验证扩展、请求体、系统提示；不证明真实模型、桌面控制、embedding 推理、长会话压缩或 Linux 工作。隔离环境不要设置真实 provider key，也不要用 --offline 代替隔离。
