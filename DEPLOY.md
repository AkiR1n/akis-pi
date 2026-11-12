# 部署

按「做什么 → 检查命令 → 期望结果 → 失败怎么办」执行。先读 [AGENTS.md](AGENTS.md)，版本见 [manifest.json](manifest.json)，理由见 [docs/decisions.md](docs/decisions.md)。core 必装，memory / macos / magpie 按需。联网安装前先说明，不覆盖已有配置，doctor FAIL 时停止。

## 0. 前置检查与路径

在仓库根目录记录绝对路径与所选模块，后续不要丢失变量：
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
期望：macOS arm64 或 Linux x86_64/arm64，HOME 非空，Git 可用；Linux 未实测。已有 Pi 记下版本，缺 Pi 则步骤 2 安装。已有 settings.json / AGENTS.md / APPEND_SYSTEM.md 必须备份、审阅 diff，确认后再覆盖。

render 与 doctor 的 `--agent-dir` 需显式传入 `"$PI_CODING_AGENT_DIR"`；默认 HOME/.pi/agent。模板 `{{AGENT_DIR}}` 跟随此参数。文中 `~/.pi/agent` 在自定义部署中均换为该目录。搜索配置写 `$HOME/.pi/web-search.json`，MC 写 `$HOME/.config/cortexkit/magic-context.jsonc`。自定义 XDG_CONFIG_HOME 需自行备份并移到实际读取位置（脚本不跟随）。resident-memory 默认读 HOME/.pi/agent/memory/RESIDENT.md，自定义 agent-dir 设 `PI_RESIDENT_MEMORY_FILE="$PI_CODING_AGENT_DIR/memory/RESIDENT.md"`。pi-web-access 查找差异见步骤 6。

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
用 mise 期望 Node v24.21.0、npm 有输出；`command -v mise` 无输出说明不用 mise，报 `env: mise: No such file or directory` 属预期，按非 mise 分支处理。模板 npmCommand 通过 mise 调 npm；隔离 HOME 时 mise 可能重下 Node，先跑这条检查，免得把下载当成插件行为。非 mise 运行 `node --version && npm --version`，在步骤 4 apply 后删部署目标的 npmCommand（见对应命令），否则 pi install 报 `env: mise: No such file or directory`。不要用 node/24 别名代替精确版本。

安装 core bash rewrite 所需 RTK，任选其一：
```sh
# Homebrew
brew install rtk
# 非 brew：从 GitHub release 下载 v1.1.0 对应平台的压缩包，解压后把 rtk 放进 PATH
#   https://github.com/rtk-ai/rtk/releases/tag/v1.1.0
# 不要用 cargo install rtk：crates.io 上的 rtk 是另一个同名项目
# 均需检查
rtk --version
rtk rewrite --help
```
期望验证版本 1.1.0，至少支持 ≥0.23.0 的 rewrite。brew 若给新版记录差异；缺 RTK 扩展放行原 bash，doctor 报 WARN。非 brew / Linux 未实测，失败查原始输出，不要报告已生效。

## 2. 装 Pi（二选一）

A：官方安装器，装最新：
```sh
curl -fsSL https://pi.dev/install.sh | sh
pi --version
```
B：复现测试版本：
```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.2
pi --version
```
期望 B 精确为 1.5.2；A 为新版时 doctor 对普通偏差 WARN，对 major 变化 FAIL（需重评兼容性）。不要混装 managed 与 npm 全局；命令缺失检查 PATH 的 agent-dir/bin 或 npm prefix 的 bin。不要因新版 WARN 自动降级或替换 pinned 组件。

## 3. models.json 与无 key 检查

在 `$PI_CODING_AGENT_DIR/models.json` 新建配置，不复制凭据，不替换已有文件。填好所有模型占位符；historian 可复用其一。
```json
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "{{PROVIDER}}": {
      "baseUrl": "https://api.example.com/v1",
      "api": "openai-completions",
      "apiKey": "$PI_PROVIDER_KEY",
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
cost 必填（USD / 百万 token），按真实价格填写。凭据只用 `!command` 或环境变量引用（如 `$PI_PROVIDER_KEY`），不写明文。API 类型要与供应商匹配，responses 接口不可套用 openai-completions。magpie 模块单独注图模，对话仍由 models.json 提供。

检查模型目录与扩展加载（不请求模型）：
```sh
pi --list-models > /tmp/pi-models.txt 2> /tmp/pi-models.stderr
cat /tmp/pi-models.stderr
```
期望 exit 0、stderr 空且目录有填写的模型。唯一允许的 stderr 是未装 rtk 时的 `[rtk] rtk binary not found in PATH — extension disabled`（装好后为空）。报 no models / Failed to load extension 时先排查配置。有 key 时可额外执行：
```sh
pi --provider '<供应商 id>' --model '<主模型 id>' --print 'reply with the single word ok'
```
期望回 ok；没有 key 时用文末回环 stub 验证步骤 3、7、8。`--offline` 不阻止模型请求，不可用它保证离线。

## 4. 按实际所需模块渲染

先 dry run；MODULES 为步骤 0 所选（选 memory 必须含 core,memory）：
```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES" --strict \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='$BOCHA_API_KEY'
```
期望打印 create / unchanged / diff，WARNINGS 为空。审阅路径与 diff，确认后写入：
```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES" --strict --apply \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='$BOCHA_API_KEY'
```
strict 遇未解析占位符拒绝写入；非 strict 警告并跳过。JSON/JSONC 按字符串转义，凭据只接引用，不要手改模板绕过。

渲染器将已完成模块记入 `<agent-dir>/.akis-pi-render.json`。后续只渲染新增模块，不重写已完成 core，不移除旧模块；后加 memory 只合并 packages 到 settings，保留其它设置与过滤项。重复传 core 不更新；需更新模板时在独立目录生成审阅合并，不要删状态文件覆盖。

写入范围与备份见 README；已有目标先备份到 `<agent-dir>/backups/akis-pi-<时间戳>/targets/<绝对目标路径去掉根斜杠>`。不替换 mcp.json、models.json、auth.json、RESIDENT.md。

非 mise 用户在 apply 后、装插件前执行（只改部署副本）：
```sh
cp -p "$PI_CODING_AGENT_DIR/settings.json" "$PI_CODING_AGENT_DIR/settings.json.before-npm-command"
node -e 'const fs=require("fs"),p=process.env.PI_CODING_AGENT_DIR+"/settings.json",s=JSON.parse(fs.readFileSync(p));delete s.npmCommand;fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n")'
npm --version
```
检查目标 settings 无 npmCommand；Pi 将用默认 npm。删除失败则停止，不要装插件。

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
pi install 在空 settings 只写字符串条目；资源过滤来自步骤 4 渲染，已有过滤对象才会被保留。pi-atelier 的 extensions 与 pi-compact-tools 的 extensions/themes: [] 不能丢。

core-only 且所有包在磁盘时运行 `pi list`：期望 11 项、路径在 agent-dir/npm/node_modules，pi-atelier 与 pi-compact-tools 显示 `(filtered)`。选了 memory 时声明 13 项而磁盘仅 11 项，**暂不运行 pi list**（会触发下包，本地 pi-knowledge 未构建）。等 9.3 完成再查 13 项。doctor 不调用 pi list。

npm 11 的 allowScripts 可能跳过 postinstall：警告 install-scripts 不等同损坏。在执行目录检查：
```sh
cd "$PI_CODING_AGENT_DIR/npm"
npm install-scripts --help
npm install-scripts ls
```
判据：被跳过脚本的包，只要加载与执行检查通过（多数自带 prebuilt，如 better-sqlite3、sharp、tree-sitter），就**无需** approve，不要 `approve --all`。仅检查失败才审阅 approve，approve 后需运行 `npm rebuild <包名>`（如 `npm rebuild @injaneity/pi-computer-use`）。不支持该命令查日志与 npm 策略。

核验 pi-computer-use：postinstall 实际为 `node scripts/setup-helper.mjs --postinstall`，负责装 helper，跳过影响桌面控制。下面只读检查 helper 二进制；失败按说明重新安装（涉及下载需先说明），不要把包已安装当成可用：
```sh
cd "$PI_CODING_AGENT_DIR/npm/node_modules/@injaneity/pi-computer-use"
node --input-type=module -e 'import fs from "node:fs";import os from "node:os";import path from "node:path";import {resolveMacosHelperAppPath} from "./src/platform/macos/helper-path.mjs";const p=process.platform==="darwin"?path.join(resolveMacosHelperAppPath(),"Contents/MacOS/bridge"):(process.env.PI_COMPUTER_USE_LINUX_HELPER_PATH||path.join(os.homedir(),".pi/agent/helpers/pi-computer-use/linux-bridge"));fs.accessSync(p,fs.constants.X_OK);console.log("helper executable exists:",p)'
```
此命令覆盖 macOS/Linux；未做授权与桌面操作仍记为未验证。MC 的 onnxruntime-node 检查留在 9.1 装完后。require 成功不代表模型下载或 embedding 可用。tree-sitter 等依赖若跳过脚本按相同判据核查。失败先查日志，不要换随意版本。

## 6. 搜索与密钥

key 放环境变量或钥匙串，只渲染引用。macOS 示例：
```sh
security add-generic-password -a "$USER" -s pi-web-access-brave -w
# --set BRAVE_KEY_REF='!security find-generic-password -a "$USER" -s pi-web-access-brave -w'
```
交互输入 key 免留 shell 历史。环境变量引用形如 `$BRAVE_API_KEY` / `$BOCHA_API_KEY`。检查字段：
```sh
node -e 'const c=require(process.env.HOME+"/.pi/web-search.json");console.log(Object.keys(c));for(const k of ["braveApiKey","bochaApiKey"])console.log(k,/^(?:!\S|\$(?:[A-Za-z_]|\{))/.test(c[k]||"")?"ref-ok":"MISSING-OR-LITERAL")'
```
期望 searchRouting/fetchRouting/pdf 存在、两字段 ref-ok，无占位符。引用指向未设变量时 pi-web-access 行为**未验证**，不要当成有可用 key。没 Brave/Bocha 删对应字段与 providers，保留 exa → gemini → degoog 兜底。改 routing 后重启 Pi。

pi-web-access 0.47.0 源码：只要设了 PI_CODING_AGENT_DIR，优先读该目录下 web-search.json（即使等于默认）；未设才按 XDG / agent / legacy 回退。步骤 0 已设该变量，必须将渲染在 legacy 的文件同步到 agent-dir。先看 diff；目标确认后备份再复制：
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
doctor 同时扫描两处占位符，agent-dir 变化须重测搜索。步骤 6 检查也将路径换为实际读取的 agent-dir/web-search.json。

## 7. 子代理角色

core 渲染 8 个角色、subagent/config.json 与 prompts。检查：
```sh
grep -h '^model:' "$PI_CODING_AGENT_DIR"/agents/*.md | sort | uniq -c
grep -R '{{' "$PI_CODING_AGENT_DIR/agents" "$PI_CODING_AGENT_DIR/prompts"
# core-only 已安装完且有 key 时；选 memory 则等 9.3 完成后再执行：
pi --print 'delegate nothing; just list the subagent roles you can call'
```
期望无占位符，模型含 inherit 与步骤 4 填的角色 id；impl-sol 用 MODEL_REVIEW，impl-flash 用 MODEL_EXEC，规划角色用 MODEL_PLAN。子代理模型必须在 models.json 注册且 provider 正确。角色缺失核对 agents/（非 subagents/）。无 key 用 stub；此步仅验配置解析，不验执行质量。

## 8. 第一次启动验收

core-only 现在开新会话（不要用旧会话或 /reload）。选 memory 先记录命令，等 9.3 依赖全构建完再执行；未装完前启动 Pi 会错误触发缺包安装，且不可做请求测试：
```sh
pi --print 'answer with the number of tools you can call directly, and nothing else'
```
期望 **3 个直接工具**：codemode / ask_user / tool_search。pi-compact-tools 收拢其余工具为按需发现，调用走 tools.<name>()。模型自报工具数不准，以 stub 捕获为准。若出约 50 个工具，核对 codemode.mode=only；若为 0，回步骤 5 查插件与 Pi 版本。

## 9. memory 模块（可选，选了才做）

### 9.1 Magic Context
```sh
pi install npm:@cortexkit/pi-magic-context@0.49.50
node -e 'const fs=require("fs"),p=process.env.PI_CODING_AGENT_DIR+"/npm/node_modules/@cortexkit/pi-magic-context/package.json";console.log(JSON.parse(fs.readFileSync(p)).version)'
```
期望 0.49.50，配置已在步骤 4 随 core,memory 渲染。此时磁盘 12 个 npm 包、settings 声明 13 项；本地 pi-knowledge 未装，**不运行 doctor 或 pi list，等 9.3 完成再查**。检查步骤 5 的 onnxruntime-node。

三参数：execute_threshold_tokens.default=400000（小窗口钳至 90%）、memory.injection_budget_tokens=3000、historian_timeout_ms=600000。理由见 decisions.md。MC 的 `pi.subagent_extensions: []` 保持 historian 子进程不载普通扩展。

多入口用 doctor `--mc-profile <另一份magic-context.jsonc文件>`（文件路径）逐份比对；单配置 consistency WARN 属正常。数据默认在 HOME/.local/share/cortexkit/magic-context，可用 MAGIC_CONTEXT_STORAGE_DIR 覆盖；升级前读 database migration 说明，退包无法回滚数据库。

装完 MC 后核验 onnxruntime-node（本地 embedding 运行时；MC 为 ESM，无法通过 `require.resolve` 查找，从 package.json 建 require）：
```sh
node -e 'const {createRequire}=require("module");const r=createRequire(process.env.PI_CODING_AGENT_DIR+"/npm/node_modules/@cortexkit/pi-magic-context/package.json");console.log(r("onnxruntime-node").env.versions)'
```
期望打印 `{ common: "…", node: "…" }`。仅说明 native runtime 可加载，不代表模型已下载或推理可用。tree-sitter 等依赖跳过脚本按步骤 5 判据处理。

### 9.2 resident-memory

扩展只读 RESIDENT，默认预算 6000 字符。由用户自备文件，存在则停止，不覆盖：
```sh
dst="$PI_CODING_AGENT_DIR/memory/RESIDENT.md"
if [ -e "$dst" ]; then
  echo "exists: $dst; 停止，不覆盖"
else
  cp -n "$PI_CODING_AGENT_DIR/memory/RESIDENT.template.md" "$dst"
fi
```
用户可编辑稳定事实。检查用交互 TUI 的 `/resident-memory`，显实际注入文本与预算；`--print` 该命令 stdout 为空。自动化用 stub 抓包 grep `<resident_memory>`。出现 truncated 需精简。PI_RESIDENT_MEMORY_OFF=1 关闭；仅 ENOENT 当空，其它读取错误需修。

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
期望 dist/index.js 存在、版本 0.12.0、pi list **13 项**（11 core + MC + pi-knowledge），保留两个 filtered；此处仅查 core,memory，doctor 应 0 FAIL；MODULES 其余模块步骤 12 查。启动新 Pi 会话做步骤 7、8 验收（无 key 用 stub），静态检查不可替代。补丁含尾延迟优化、真实 source span 行号对齐、复核修复三份，作者已去敏。git am 冲突停止查 base，不要手动绕过。npm 脚本警告按步骤 5 查。在小库实测检索行号；仅构建不证明检索可用。知识库目录不可指向 resident 目录。

## 10. macos 模块（可选）

### 10.1 追加渲染与 herdr

步骤 4 没选 macos 时，现在追加 macos，无需重渲染 core/memory：
```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules macos --strict \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='$BOCHA_API_KEY'
# 审阅后
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules macos --strict --apply \
  --set PROVIDER='<供应商 id>' \
  --set MODEL='<主模型 id>' \
  --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' \
  --set MODEL_PLAN='<规划模型>' \
  --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' \
  --set BOCHA_KEY_REF='$BOCHA_API_KEY'
# 同步 MODULES（已含 macos 时不必重复追加）
export MODULES="$MODULES,macos"
```
herdr-agent-state.ts 由 herdr 管理，仅 HERDR_ENV、HERDR_SOCKET_PATH、HERDR_PANE_ID 齐备时工作。检查在 herdr 中跑 Pi 看状态。manifest 的 herdr 仅为来源描述，无公开下载 URL，本仓库不提供未经核实的获取链接。

### 10.2 ego 窗口回收

ego-gc.ts 仅在 ego lite 运行时清理窗口，不主动启动；PI_EGO_GC=off 关闭、PI_EGO_GC_DEBUG=1 输出日志。ego-browser/ego-search 技能由第三方 app 安装，本仓库不分发。manifest 的 ego-lite 是 `external app, not redistributed`，**无核实获取 URL**；向提供 app 渠道获取，未取得则跳过，不编造链接。不用时 settings 用 -path 排除，不删文件。

### 10.3 本地 PDF→Markdown
```sh
# macos 渲染已写 server.py / requirements.txt / LaunchAgent，默认仅回环
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/com.example.pipdfparse.plist"
curl --noproxy '*' http://127.0.0.1:8791/health
```
期望 {"ok":true}。链路：本地端点 → Gemini → unpdf，扫描件 422 走 OCR。改端口需同步 PI_PDF_PARSE_PORT 与 web-search.json 的 pdf.endpointUrl。停用用 launchctl bootout；launchd 不展开 ~，迁移 HOME 需审阅重装 plist 绝对路径。

### 10.4 agent-browser

npx 成功不证明全局 CLI 安装；实际安装并检查：
```sh
npm install -g agent-browser@0.41.2
command -v agent-browser
"$(npm prefix -g)/bin/agent-browser" --version
```
期望 0.41.2 且路径在扩展解析的同一 Node 树。mise node/24 别名会漂移，装新 24.x 后需重新确认，否则浏览器工具报 could not be validated。来源参照 manifest 的 npm -g agent-browser。

## 11. magpie 模块（可选）

从 manifest 的 [Magpie source](https://github.com/yetone/magpie) 获取并打开。确认步骤 4 包含 magpie（若追加沿用步骤 10.1 参数将 --modules 改为 magpie 并先 dry run），将 modules/magpie/mcp.json.example 的两个服务合并到 agent-dir/mcp.json，不整体覆盖。
```sh
pi mcp list
```
期望 Pi 看到 hub web_search/web_fetch 与 stdio 的 generate_image/generate_video/generation_result。hub 按 Sec-Fetch-Mode: cors / 浏览器 UA 过滤，Node 原生 fetch 自带头，curl 见 6 个工具不证明 Pi 可见。斜杠命令技能必须 direct，不可接 hub。加 server 重启 Pi，生图先 n:1 再查 generation_result，失败查 Magpie 日志。详见 modules/magpie/README.md。

## 12. 收尾自检与回滚

只传实际已渲染且完成安装的模块，用步骤 0 的 MODULES（core-only 为 core，带 memory 为 core,memory，追加时同步更新）：
```sh
node "$REPO/scripts/doctor.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES"
```
期望 0 FAIL，WARN 逐条解释。doctor 只读 settings/node_modules，**不调用 pi list、不安装包**。对照 manifest：版本同 PASS；普通偏差 WARN；Pi/MC 的 major 偏差 FAIL；缺声明包 FAIL。两者改错仍会被查出。RTK 缺失或无 rewrite 为 WARN。core 11 包、core+memory 13 包，macos/magpie 不增包。

FAIL packages resolve on disk 回步骤 5（memory 查 9），placeholders 回步骤 4，MC parameters 查 9.1。确保 0 FAIL 方可交付。回滚：先用 -path 禁用扩展，次退插件，最后退 Pi；已有文件备份在 targets/，确认后手动还原：
```sh
find "$PI_CODING_AGENT_DIR/backups" -path '*/targets/*/settings.json'
# 审阅后将找到的备份 cp -p 到 "$PI_CODING_AGENT_DIR/settings.json"
# 插件回滚示例（同时影响 settings）：
pi remove npm:pi-away@0.1.4
```
数据库回滚详见 docs/upgrade.md，不要将配置备份冒充数据恢复。

## 无 key 的本地回环验收

先跑步骤 3 的 pi --list-models，exit 0 且 stderr 空，确认目录与扩展正常。随后在**独立临时 HOME 与 agent-dir** 复制本次生成的非凭据配置，创建仅含 stub provider 的 models.json（不要修改真实配置）。参考：
```json
{"providers":{"stub":{"baseUrl":"http://127.0.0.1:8899/v1","api":"openai-completions","apiKey":"dummy","models":[{"id":"stub-model","name":"Stub","cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":200000,"maxTokens":1000}]}}}
```
此为回环 stub 测试桩，非真实凭据。隔离副本的 settings.enabledModels 若残留原配置，pi --list-models 会报 stderr。在临时副本将默认模型与 enabledModels 改为 stub，再跑检查：
```sh
# 此时 HOME 与 PI_CODING_AGENT_DIR 必须已经指向独立临时副本
node -e 'const fs=require("fs"),d=process.env.PI_CODING_AGENT_DIR;if(!/^\/(?:private\/)?tmp\//.test(d||""))throw Error("requires temporary agent-dir");const p=d+"/settings.json",s=JSON.parse(fs.readFileSync(p));s.defaultProvider="stub";s.defaultModel="stub-model";s.enabledModels=["stub/stub-model"];fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n")'
pi --list-models > /tmp/pi-stub-models.txt 2> /tmp/pi-stub-models.stderr
cat /tmp/pi-stub-models.stderr
```
期望 stderr 为空。复制的 packages 含绝对本地路径需在临时副本指向隔离产物；不要复制 auth.json、真实 models.json 或旧会话。独立终端启动仅监听 127.0.0.1 脚本（日志含 prompt，仅留临时目录，禁止提交）：
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
期望 stdout 打印 stub-ok，tools 准确为 codemode/ask_user/tool_search，系统提示含所选模块注入（配了 RESIDENT 方有 resident_memory）。Ctrl-C 关闭 stub。此步仅验证扩展、请求体与系统提示；不证明真实模型、桌面操控、embedding 或长会话压缩。隔离环境不要设置真实 key，不可用 --offline 代替隔离。
