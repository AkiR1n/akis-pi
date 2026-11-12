# 部署

按「做什么 → 检查命令 → 期望结果 → 失败怎么办」执行。先读 [AGENTS.md](AGENTS.md)，版本见 [manifest.json](manifest.json)，理由见 [docs/decisions.md](docs/decisions.md)。core、magpie、memory 必装（darwin 再加 macos），只有 pdf 可选。联网安装前先说明，不覆盖已有配置，doctor FAIL 时停止。

本文分两层：先按平台选一个**入口**（只有一个平台的差异写在这里），再走**共用步骤**。共用步骤里的检查尽量是 `node` 或 `pi` 命令，参数两端一致；只有安装前置和路径写法必须分平台。

## 平台入口

| 入口 | 适用平台 | 前置 | 状态 |
| --- | --- | --- | --- |
| POSIX 入口 | macOS、Linux、WSL2 | 系统 Bash、Node 24.22.3、Git | macOS、WSL2 已实测；Linux 原生试验 |
| PowerShell 入口 | 原生 Windows x64 | Windows PowerShell 5.1 或 7、Node 24.22.3、Git for Windows | **试验**：部署检查已通过，长时间运行与桌面能力未验收 |

Windows 用户默认选 WSL2（core+magpie+memory）：Linux 用户态下 Bash、路径和安装流程与本文的 POSIX 部分一致。只有需要操作 Windows 桌面、或复用 Windows 登录态的浏览器时，才选原生 Windows。

### POSIX 入口

```sh
export REPO="$HOME/akis-pi"          # 仓库绝对路径
export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
export MODULES=core,magpie,memory    # 三个必装；darwin 再加 ,macos；pdf 按需
# Linux / WSL2：必须在安装 memory（MC）之前设置；macOS 不需要。
export ONNXRUNTIME_NODE_INSTALL=skip        # MC: onnxruntime-node 1.30.0
export ONNXRUNTIME_NODE_INSTALL_CUDA=skip   # pi-knowledge: onnxruntime-node 1.21.0
```

onnxruntime-node@1.30.0 在 Linux x64 默认下载 CUDA 执行提供程序，下载器不跟随 HTTP 重定向，遇 302 会让 postinstall 失败并可能被 npm 丢弃为可选依赖。CPU 所需的绑定与运行库已随 npm 包发布，设置 `skip` 只跳过额外下载；pi-knowledge 的 1.21.0 安装器读取不同的 `ONNXRUNTIME_NODE_INSTALL_CUDA`，所以须同时设置两个变量。需要 GPU 的用户须另行处理，未实测。

### PowerShell 入口

PowerShell 5.1 与 PowerShell 7 都能执行本文的 PowerShell 片段，注意三点：

- 5.1 不支持 `&&`，用 `;` 或分行；
- 单引号内的 `$VAR` 保持字面量，凭据引用必须这样写：`--brave-key-ref '$BRAVE_API_KEY'`；
- 渲染器与 doctor 是 Node 脚本，参数与 POSIX 相同；检查代码放在 deploy-check.mjs 中，避免 5.1 向原生程序传递内嵌 JavaScript 时丢双引号。不要照抄 `export`、`command -v` 或 POSIX 路径变量。

```powershell
$Repo = 'C:\path\to\akis-pi'
$env:PI_CODING_AGENT_DIR = Join-Path $HOME '.pi\agent'
$Modules = 'core,memory'
Set-Location $Repo
# 仅当前终端；让 npm.ps1 和本地测试脚本可运行，不改变用户持久策略。
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
Get-ExecutionPolicy -List
node --version
```

如果组策略禁止运行脚本，停止并记录策略，不用 Bypass 绕过。Git clone 的本地脚本通常没有下载标记；ZIP 下载的脚本若被 RemoteSigned 拒绝，审阅来源与内容后再对明确的脚本使用 Unblock-File。Windows 测试 driver 在管理员终端运行，且此策略设置只影响当前终端。

选择 memory 的原生 Windows x64 还需要 **Microsoft Visual C++ 2015-2022 x64 可再发行组件**。缺少 System32 中的 `vcruntime140.dll`、`vcruntime140_1.dll` 或 `msvcp140.dll` 时，即使 onnx 的 .node/.dll 都在，加载也会报 Win32 126。官方地址：https://aka.ms/vs/17/release/vc_redist.x64.exe 。在管理员 PowerShell 安装：

```powershell
$Installer = Join-Path $env:TEMP 'vc_redist.x64.exe'
Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $Installer -UseBasicParsing
$Signature = Get-AuthenticodeSignature -LiteralPath $Installer
if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'Unexpected installer signature' }
$Install = Start-Process -FilePath $Installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
$Install.ExitCode    # 0 或 3010 成功；3010 表示需要重启
if ($Install.ExitCode -notin 0, 3010) { throw 'VC++ runtime installation failed' }
Remove-Item -LiteralPath $Installer
```

安装 MC 后检查：`node scripts/deploy-check.mjs onnx`；必须打印版本且 exit 0，不能靠 npm 审批与 rebuild 替代运行库安装。

### WSL2 入口（Windows 用户的默认选择）

```powershell
wsl --install -d Ubuntu-24.04    # 已装发行版则跳过；首次安装后需要重启并设置 Linux 用户
wsl -d Ubuntu-24.04
```

进入发行版后按 POSIX 入口操作。四条硬性约束：

1. **源码、`node_modules`、知识库与 Magic Context 数据都放在 WSL 的 `/home/<user>/...`**，不要放 `/mnt/c`。跨文件系统访问慢一个数量级，且大小写、权限位与符号链接语义不同，`npm ci` 与 SQLite 都可能出错。
2. 不要把同一个 `node_modules` 在 Windows 与 WSL 间共用，两边安装的平台包不同。
3. WSL 内没有 launchd 与 Keychain：macos 模块在 WSL 不适用，凭据用 `$VAR`。
4. WSL 访问 Windows 上的 Magpie / PDF 端点不能假定 `127.0.0.1`（默认 NAT 网络），先在发行版内用 `curl` 验证可达性。需要操作 Windows 桌面时不要留在 WSL：WSL 里装的是 Linux 后端，看不见 Windows UI。

## 0. 前置检查与路径

**做什么**：在仓库根目录记录路径与模块，确认 Node、Git 与已有 Pi 版本。

POSIX：

```sh
cd "$REPO"
uname -sm; echo "HOME=$HOME"
node --version; npm --version; git --version
command -v pi && pi --version
```

PowerShell：

```powershell
Set-Location $Repo
[System.Runtime.InteropServices.RuntimeInformation]::OSDescription
node --version; npm --version; git --version
(Get-Command node).Source; (Get-Command git).Source
Get-Command pi -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
```

**检查**：上面两组命令的输出。
**期望**：`Darwin arm64`、`Linux x86_64`/`aarch64`（WSL2 也显示 Linux）、`mingw`/`Windows` 之一；HOME 非空；Node 24.22.3；Git 可用（Windows 上应指向 Git for Windows 的 `git.exe`）；已有 Pi 记下版本，缺 Pi 走步骤 2。
**失败怎么办**：Node 版本不对先回步骤 1；`git` 缺失在 Windows 上装 Git for Windows；`pi` 缺失属正常，继续步骤 2。

已有 `settings.json` / `AGENTS.md` / `APPEND_SYSTEM.md` 必须先备份、审阅 diff，确认后再覆盖。

render 与 doctor 的 `--agent-dir` 需显式传入所选目录；默认 `<HOME>/.pi/agent`。模板 `{{AGENT_DIR}}` 跟随此参数，文中 `~/.pi/agent` 都换为该目录。搜索配置写显式 agent-dir 下的 `web-search.json`；没有显式目录时跟随 pi-web-access 的 XDG / agent / legacy 回退规则，dry run 会打印最终路径。MC 写绝对 `XDG_CONFIG_HOME` 下的 `cortexkit/magic-context.jsonc`，未设置时为 `<HOME>/.config/cortexkit/magic-context.jsonc`，Windows 也是这个默认值（不是 APPDATA）。render 与 doctor 共用同一解析器。resident-memory 默认读 `<HOME>/.pi/agent/memory/RESIDENT.md`，自定义 agent-dir 时设 `PI_RESIDENT_MEMORY_FILE`。

## 1. Node 24.22.3、npmCommand 与 RTK

**做什么**：装 Node 24.22.3、决定 npmCommand、装 RTK。

Node 24.22.3 可直接安装，mise 是可选版本管理器（仅 POSIX）：

```sh
curl https://mise.run | sh          # 已有 mise 则跳过
mise use -g node@24.22.3
node --version && npm --version
```

原生 Windows 用官方 MSI（nodejs.org/dist 的 24.22.3 x64），装完重开终端：`node --version` 应为 v24.22.3。不要依赖 winget 或 Appx：部分镜像不带 winget，远程会话里 Appx 部署也可能失败，MSI/EXE 更稳。

默认模板不写 npmCommand，Pi 使用普通 npm。只有 POSIX 上显式给 render 加 `--mise` 或 `--set USE_MISE=true` 才生成 `mise exec node@24.22.3 -- npm`；加之前先单独验证 `mise exec node@24.22.3 -- npm --version`。不要用 node/24 别名代替精确版本。

装 core 的 bash 重写所需 RTK，任选其一：

```sh
brew install rtk                     # macOS
# 非 brew：从 https://github.com/rtk-ai/rtk/releases/tag/v1.1.0 下载对应平台压缩包，
# 解压后把 rtk 放进 PATH。不要用 cargo install rtk：crates.io 上的 rtk 是另一个同名项目。
```

Windows 取同一 release 的 `rtk-x86_64-pc-windows-msvc.zip`，解压到 PATH 上的目录（例如 `%USERPROFILE%\bin`），再新开终端：

```powershell
rtk --version
rtk rewrite --help
```

**检查**：`node --version`、`npm --version`、`rtk --version`、`rtk rewrite --help`。
**期望**：Node v24.22.3；RTK 1.1.0 且支持 `rewrite`（至少 ≥0.23.0 才有该子命令）。
**失败怎么办**：brew 给的是更高版本就记录差异；RTK 缺失或没有 `rewrite` 时扩展放行原 bash，doctor 报 WARN，不要报告“已生效”。非 brew / Linux 安装未实测，失败查原始输出。

## 2. 装 Pi（二选一）

A：官方安装器，装最新（POSIX）：

```sh
curl -fsSL https://pi.dev/install.sh | sh
pi --version
```

B：复现测试版本（两个平台同一条命令）：

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.2
pi --version
```

原生 Windows 的 managed 安装器见上游 Windows 文档；本包尚未验收该路径，优先用 B 复现精确版本。

**期望**：B 精确输出 1.5.2；A 为新版时 doctor 对普通偏差 WARN，对 major 变化 FAIL（需重评兼容性）。
**失败怎么办**：不要混装 managed 与 npm 全局。命令缺失时检查 PATH 里的 agent-dir/bin 或 npm prefix 的 bin；Windows 上 `pi` 是 `pi.cmd` shim，doctor 会把它解析成 `node.exe + CLI 脚本`，不需要你手工改指向。不要因新版 WARN 自动降级或替换 pinned 组件。

## 3. models.json 与无 key 检查

**做什么**：在 `$PI_CODING_AGENT_DIR/models.json` 新建配置，填好所有模型占位符；historian 可复用其一。不复制凭据，不替换已有文件。

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

**检查**（不请求模型，两个平台相同）：

```sh
pi --list-models
```

**期望**：exit 0，终端没有 stderr 输出，列表含上面填写的模型。
**失败怎么办**：唯一允许的 stderr 是未装 rtk 时的 `[rtk] rtk binary not found in PATH — extension disabled`（装好后为空）。报 no models / Failed to load extension 时先查配置与扩展加载；`--offline` 不阻止模型请求，不能用它保证离线。有 key 时可额外执行 `pi --provider '<供应商 id>' --model '<主模型 id>' --print 'reply with the single word ok'`，期望回 `ok`；没有 key 用文末回环 stub 验证步骤 3、7、8。

## 4. 按实际所需模块渲染

**做什么**：先 dry run 看计划，再 apply。`MODULES` 为步骤 0 所选（至少 `core,magpie,memory`，darwin 加 `macos`）。

POSIX：

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

PowerShell（同样参数；审阅后追加 `--apply`）：

```powershell
node scripts/render.mjs --home $HOME --agent-dir $env:PI_CODING_AGENT_DIR --modules $Modules --strict --provider '<供应商 id>' --model '<主模型 id>' --model-exec '<执行模型>' --model-review '<复核模型>' --model-plan '<规划模型>' --model-historian '<压缩模型>' --brave-key-ref '$BRAVE_API_KEY' --bocha-key-ref '$BOCHA_API_KEY'
```

PowerShell 的单引号让 `$BRAVE_API_KEY` 保持引用文本，不会被当前会话展开；doctor 只报告变量 ok/missing，不打印值。

**检查**：dry run 的完整输出。
**期望**：打印 create / unchanged / diff，WARNINGS 为空。审阅路径与 diff，确认后以同样参数追加 `--apply`。
**失败怎么办**：strict 遇未解析占位符拒绝写入；非 strict 警告并跳过。JSON/JSONC 按字符串转义，凭据只接引用，不要手改模板绕过。

渲染器将已完成模块记入 `<agent-dir>/.akis-pi-render.json`。后续只渲染新增模块，不重写已完成 core，不移除旧模块；后加 memory 只合并 packages 到 settings，保留其它设置与过滤项。重复传 core 不更新；需更新模板时在独立目录生成审阅合并，不要删状态文件覆盖。

写入范围与备份：已有目标先备份到 `<agent-dir>/backups/akis-pi-<时间戳>/targets/<目标映射>`（POSIX 去根斜杠；Windows 用 drive-C / unc/server/share，跨盘不碰撞）。不替换 mcp.json、models.json、auth.json、RESIDENT.md。新部署无需删除 npmCommand：默认没有该字段；旧配置升级在独立目录生成、审阅合并。

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

**检查**：core-only 且所有包在磁盘时运行 `pi list`。
**期望**：11 项，路径在 `agent-dir/npm/node_modules`，pi-atelier 与 pi-compact-tools 显示 `(filtered)`。
**失败怎么办**：选了 memory 时声明 13 项而磁盘仅 11 项，**暂不运行 `pi list`**（它会触发下包，本地 pi-knowledge 未构建）；等 9.3 完成再查 13 项。doctor 不调用 pi list。

npm 11 的 `allowScripts` 安装脚本审批可能跳过 postinstall；`ignoreScripts` 设置也会阻止脚本运行。npm 10 及以下可跳过本段审批流程（仍需确认没有开启 `ignore-scripts`）。在执行目录检查：

```sh
# POSIX：cd "$PI_CODING_AGENT_DIR/npm"
# PowerShell：Set-Location (Join-Path $env:PI_CODING_AGENT_DIR 'npm')
npm install-scripts --help
npm install-scripts ls
```

判据：被跳过脚本的包，只要加载与执行检查通过（多数自带 prebuilt，如 better-sqlite3、sharp、tree-sitter），就**无需 approve**，不要 `approve --all`。仅检查失败才审阅 approve，approve 后需 `npm rebuild <包名>`（如 `npm rebuild @injaneity/pi-computer-use`）。不支持该命令查日志与 npm 策略。

选了 memory 时，步骤 9.1 安装 MC 后必须运行 `node scripts/deploy-check.mjs onnx`。审批是通用安装策略，不是本次两种 onnx 故障的修复：

- 原生 Windows：包与绑定都存在却报 Win32 126，是缺 VC++ 运行库；按 PowerShell 入口安装可再发行组件。实测 approve + rebuild 均 exit 0 仍无法加载，安装运行库后才打印版本。
- Linux x64 / WSL2：`Cannot find module 'onnxruntime-node'` 是默认 CUDA 下载遇 302、postinstall 失败后可选依赖未保留；CPU 安装按 POSIX 入口设置 `ONNXRUNTIME_NODE_INSTALL=skip`。已安装过且缺包时，在 agent-dir/npm 带此变量重装可选依赖：

```sh
cd "$PI_CODING_AGENT_DIR/npm"
ONNXRUNTIME_NODE_INSTALL=skip npm install --include=optional
node "$REPO/scripts/deploy-check.mjs" onnx
```

不删除锁文件，不用 `--omit=optional`；缺包不能仅靠 rebuild 恢复。成功标准是版本信息和 exit 0；GPU 安装未实测。

核验 pi-computer-use：postinstall 实际为 `node scripts/setup-helper.mjs --postinstall`，负责装 helper，跳过会影响桌面控制。先做只读检查：

```sh
node "$REPO/scripts/deploy-check.mjs" helper
```

上面这条覆盖 macOS/Linux；原生 Windows 的 helper 是 `windows-bridge.exe`，安装位置随上游版本变化，用 `Get-ChildItem "$env:PI_CODING_AGENT_DIR\helpers\pi-computer-use" -Recurse -Filter *.exe` 以实际输出为准。未做授权与桌面操作仍记为未验证；require 成功不代表 helper 可用。MC 的 onnxruntime-node 检查留在 9.1 装完后。tree-sitter 等依赖若跳过脚本按相同判据核查。失败先查日志，不要换随意版本。

## 6. 搜索与密钥

**做什么**：key 放环境变量或系统钥匙串，只渲染引用。三种后端：

| 后端 | 写法 | 适用 |
| --- | --- | --- |
| 环境变量 | `--set BRAVE_KEY_REF='$BRAVE_API_KEY'` | 全平台，默认选择 |
| 系统钥匙串 | `--set BRAVE_KEY_REF='!security find-generic-password -a "$USER" -s <服务名> -w'` | 仅 macOS |
| 用户环境变量 | `setx BRAVE_API_KEY ...`，渲染时仍写 `$BRAVE_API_KEY` | 原生 Windows |

macOS 交互输入 key 免留 shell 历史：

```sh
security add-generic-password -a "$USER" -s pi-web-access-brave -w
```

原生 Windows 用 `setx BRAVE_API_KEY "<key>"`（写入用户环境变量，不改仓库与配置）后重开终端；`setx` 的长度上限约 1024 字符。**`!command` 在 Windows 上由 Pi 找到的 Bash 执行**：装了 Git for Windows 就走 Git Bash，所以引用里的命令必须是 Git Bash 能执行的；bash 不可用时 Pi 才回退默认 shell，且 bash 执行失败不会改试 PowerShell。需要 PowerShell 读取时显式写 `!powershell -NoProfile -NonInteractive -File <脚本>` 并自行验证退出码。

**检查**（POSIX 与 PowerShell 都是这一条，路径作为参数传入）：

```sh
node "$REPO/scripts/deploy-check.mjs" web-search
```

检查脚本从 PI_CODING_AGENT_DIR 读取目录；POSIX 与 PowerShell 的入口均已设置该变量。

**期望**：searchRouting / fetchRouting / pdf 存在；两字段 `ref-ok`，无占位符。
**失败怎么办**：doctor 对 `$VAR` / `${VAR}` 真实读取一次环境变量，只输出 ok/missing；missing 是 WARN，不能当成可用 key。`!command` 不会被 doctor 执行，另行验证。没 Brave/Bocha 就删对应字段与 providers，保留 exa → gemini → degoog 兜底。改 routing 后重启 Pi。

pi-web-access 0.47.0 优先读取 `PI_CODING_AGENT_DIR/web-search.json`。render `--agent-dir` 与 doctor `--agent-dir` 跟随同一目录；运行 Pi 时保持相同环境变量。未显式指定 agent-dir 时按 XDG / 默认 agent-dir / legacy `~/.pi` 的存在性回退，与上游一致。

## 7. 子代理角色

core 渲染 8 个角色、subagent/config.json 与 prompts。

**检查**（列出角色与 `model:` 行，两个平台相同）：

```sh
node "$REPO/scripts/deploy-check.mjs" roles
```

```sh
node "$REPO/scripts/deploy-check.mjs" placeholders
```

**期望**：无占位符；模型含 `inherit` 与步骤 4 填的角色 id（impl-sol 用 MODEL_REVIEW，impl-flash 用 MODEL_EXEC，规划角色用 MODEL_PLAN）。
**失败怎么办**：角色文件缺失核对 `agents/`（不是 `subagents/`）；子代理模型必须在 models.json 注册且 provider 正确。core-only 且已装完、有 key 时可执行 `pi --print 'delegate nothing; just list the subagent roles you can call'`；选 memory 则等 9.3 完成后再执行。无 key 用 stub；此步仅验配置解析，不验执行质量。

## 8. 第一次启动验收

core-only 现在开新会话（不要用旧会话或 `/reload`）。选 memory 先记录命令，等 9.3 依赖全构建完再执行：未装完前启动 Pi 会错误触发缺包安装，且不可做请求测试。

```sh
pi --print 'answer with the number of tools you can call directly, and nothing else'
```

**期望**：Pi 1.5.2 + pi-subagents 0.88.0 下有 **6 个直接工具**：ask_user / codemode / contact_supervisor / subagent / subagent_supervisor / tool_search。模型自报工具数不准，以 stub 捕获并由 `deploy-check.mjs stub-requests` 校验的集合为准。
**失败怎么办**：出约 50 个工具核对 `codemode.mode = only`；为 0 回步骤 5 查插件与 Pi 版本。

## 9. memory 模块（必装）

### 9.1 Magic Context

```sh
pi install npm:@cortexkit/pi-magic-context@0.49.50
node "$REPO/scripts/deploy-check.mjs" mc-version
```

**期望**：0.49.50；配置已在步骤 4 随 core,memory 渲染。此时磁盘 12 个 npm 包、settings 声明 13 项；本地 pi-knowledge 未装，**不运行 doctor 或 pi list，等 9.3 完成再查**。

三参数：`execute_threshold_tokens.default=400000`（小窗口钳至 90%）、`memory.injection_budget_tokens=3000`、`historian_timeout_ms=600000`。理由见 [decisions.md](docs/decisions.md)。MC 的 `pi.subagent_extensions: []` 保持 historian 子进程不载普通扩展。

多入口用 doctor `--mc-profile <另一份 magic-context.jsonc 文件>` 逐份比对；单配置 consistency WARN 属正常。数据默认在 `<HOME>/.local/share/cortexkit/magic-context`，可用 `MAGIC_CONTEXT_STORAGE_DIR` 覆盖；升级前读 database migration 说明，退包无法回滚数据库。

装完 MC 后核验 onnxruntime-node（MC 为 ESM，从 package.json 建 require）：

```sh
node "$REPO/scripts/deploy-check.mjs" onnx
```

**期望**：打印 `{ common: "…", node: "…" }`。仅说明 native runtime 可加载，不代表模型已下载或推理可用。
**失败怎么办**：native 加载失败是本包 memory 验收的 FAIL，doctor 也会报 FAIL；即使 MC 上游可回退 WASM，也不视为通过。Windows 先按入口补 VC++ 运行库；Linux x64 缺包按步骤 5 带 `ONNXRUNTIME_NODE_INSTALL=skip` 重装。tree-sitter 等依赖跳过脚本按步骤 5 判据处理。

### 9.2 resident-memory

扩展只读 RESIDENT，默认预算 6000 字符。由用户自备文件，存在则停止，不覆盖：

```sh
node "$REPO/scripts/deploy-check.mjs" resident-init
```

**检查**：交互 TUI 的 `/resident-memory` 会打印实际注入文本与预算；`--print` 下该命令 stdout 为空。
**期望**：注入文本与统计正常，出现 truncated 需精简。
**失败怎么办**：自动化用 stub 抓包 grep `<resident_memory>`。`PI_RESIDENT_MEMORY_OFF=1` 关闭；仅 ENOENT 当空，其它读取错误需修。RESIDENT.md 是用户私有文件，不要替用户编内容。

### 9.3 pi-knowledge + 补丁

```sh
mkdir -p "$HOME/.pi/vendor" && cd "$HOME/.pi/vendor"
git clone https://github.com/nczz/pi-knowledge
cd pi-knowledge && git checkout 558e8dd
```

PowerShell 的 clone 入口（不含 `&&`）：

```powershell
$Vendor = Join-Path $HOME '.pi\vendor'
New-Item -ItemType Directory -Force -Path $Vendor | Out-Null
Set-Location $Vendor
git clone https://github.com/nczz/pi-knowledge
if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
Set-Location (Join-Path $Vendor 'pi-knowledge')
git checkout 558e8dd
if ($LASTEXITCODE -ne 0) { throw 'git checkout failed' }
```

先确认 Git 已有自己的提交者身份（git am 需要；本包不修改 Git 配置），再按顺序应用补丁（两个平台相同；失败会停止）：

```sh
node "$REPO/scripts/deploy-check.mjs" apply-patches
```

```sh
npm ci && npm run build
ls "$HOME/.pi/vendor/pi-knowledge/dist/index.js"
node "$REPO/scripts/deploy-check.mjs" knowledge-version
```

PowerShell 的构建入口：

```powershell
npm ci
if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
npm run build
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
node "$Repo/scripts/deploy-check.mjs" knowledge-version
```

knowledge-version 同时检查版本与 dist，两个平台用同一脚本。

现在所有声明包都已安装，才运行：

```sh
pi list
node "$REPO/scripts/doctor.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules core,memory,magpie
```

PowerShell：

```powershell
pi list
node "$Repo/scripts/doctor.mjs" --home $HOME --agent-dir $env:PI_CODING_AGENT_DIR --modules core,memory,magpie
```

**期望**：`dist/index.js` 存在、版本 0.12.0、`pi list` **13 项**（11 core + MC + pi-knowledge），保留两个 filtered；此处仅查 core,memory，doctor 应 0 FAIL；MODULES 其余模块步骤 12 查。启动新 Pi 会话做步骤 7、8 验收（无 key 用 stub），静态检查不可替代。
**失败怎么办**：补丁含尾延迟优化、真实 source span 行号对齐、复核修复和 QML 可选依赖四份。`git am` 冲突停止查 base，不要手动绕过。原生 Windows 上 `npm ci` 若卡在原生依赖（better-sqlite3、tree-sitter），先装 Python 3 与 VS Build Tools 的 C++ 工作负载；`tree-sitter-qmljs` 已由第 4 份补丁降级为可选依赖，它的编译或加载失败只会让 QML 文件退回文本分块，不影响其它语言——不要把它当成整体安装失败，也不要为此回退补丁。仍装不上就改用 WSL2 的全套（core+magpie+memory）。npm 脚本警告按步骤 5 查。仅构建不证明检索可用：在小库实测检索行号；知识库目录不可指向 resident 目录。

## 10. macos 模块（darwin 必装）

其它平台选择 macos 会在写入前被拒；Windows/Linux 的等价能力见 manifest 与 modules/macos/README.md（Herdr/Rex pane、tmux inspector、launchd、Keychain 均不提供）。

### 10.1 追加渲染与 herdr

步骤 4 没选 macos 时，现在追加渲染，无需重渲染 core/memory：沿用步骤 4 的参数，把 `--modules` 换成 `macos`，先 dry run 再 `--apply`，然后同步 MODULES：

```sh
node "$REPO/scripts/render.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules macos --strict \
  --set PROVIDER='<供应商 id>' --set MODEL='<主模型 id>' --set MODEL_EXEC='<便宜执行模型>' \
  --set MODEL_REVIEW='<复核模型>' --set MODEL_PLAN='<规划模型>' --set MODEL_HISTORIAN='<压缩模型>' \
  --set BRAVE_KEY_REF='$BRAVE_API_KEY' --set BOCHA_KEY_REF='$BOCHA_API_KEY'
export MODULES="$MODULES,macos"
```

herdr-agent-state.ts 由 herdr 管理，仅 HERDR_ENV、HERDR_SOCKET_PATH、HERDR_PANE_ID 齐备时工作；检查方式是在 herdr 中跑 Pi 看状态。manifest 的 herdr 仅为来源描述，无公开下载 URL，本仓库不提供未经核实的获取链接。

### 10.2 ego 窗口回收

`ego-gc` 依赖 `~/.local/bin/ego-browser` 与两个 shell 脚本，只在 macOS 与 Linux 上可用；Windows 部署跳过它（`ego-browser` 本体上游有 Windows 安装器，本包未实测）。ego-gc.ts 仅在 ego lite 运行时清理窗口，不主动启动；`PI_EGO_GC=off` 关闭、`PI_EGO_GC_DEBUG=1` 输出日志。ego-browser/ego-search 技能由第三方 app 安装，本仓库不分发。manifest 的 ego-lite 是 `external app, not redistributed`，**无核实获取 URL**；向提供 app 渠道获取，未取得则跳过，不编造链接。不用时 settings 用 `-path` 排除，不删文件。

## 10a. pdf 模块（跨平台可选）

从 core 或 macos 中独立选择 pdf：先 `node scripts/render.mjs --home "$HOME" --modules pdf --strict` 预览，审阅后加 `--apply`。唯一 server.py / requirements.txt 渲染到 `<HOME>/.local/share/pi-pdf-parse`，darwin 另写 LaunchAgent，Linux/WSL 写 systemd --user unit，Windows 使用登录计划任务说明。安装、health 与扫描件 422 验收见 [modules/pdf/README.md](modules/pdf/README.md)。

旧 v1 macos 状态自动接管为独立 pdf 归属，保留已有文件和用户修改；不会删除或重复部署。新的 macos 安装不再隐含 PDF。

## 10b. agent-browser（core 的通用前置依赖）

```sh
npm install -g agent-browser@0.41.2
agent-browser --version
agent-browser install
# Linux 系统库缺失时按上游说明选择 agent-browser install --with-deps
```

**期望**：CLI 0.41.2 且位于扩展解析的同一 Node 树。安装 CLI 不等于已下载浏览器。
**失败怎么办**：随后用 `tools.agent_browser({args:["doctor"]})` 验证 open/snapshot/close。mise 的 node/24 别名可能随新版本漂移。原生 Windows 的会话锁、恢复与 Electron 有上游限制（上游自述 best-effort），必须单独验收，并如实呈现 Electron unsupported 之类的结论，不能只以“能启动”当通过。

## 11. magpie 模块（必装）

从 manifest 的 [Magpie source](https://github.com/yetone/magpie) 获取并打开。确认步骤 4 包含 magpie（追加时沿用 10.1 的参数把 `--modules` 改为 `magpie`，先 dry run），将 `modules/magpie/mcp.json.example` 的两个服务合并到 agent-dir/mcp.json，不整体覆盖。原生 Windows 把示例里的 `command` 换成实际的 magpie `.exe` 路径或 PATH 上的 CLI 名。

```sh
pi mcp list
```

**期望**：Pi 看到 hub 的 web_search/web_fetch 与 stdio 的 generate_image/generate_video/generation_result。
**失败怎么办**：hub 按 Sec-Fetch-Mode: cors / 浏览器 UA 过滤，Node 原生 fetch 自带头；curl 见 6 个工具不证明 Pi 可见。斜杠命令技能必须 direct，不可接 hub。加 server 后重启 Pi；生图先 n:1 再查 generation_result，失败查 Magpie 日志。详见 [modules/magpie/README.md](modules/magpie/README.md)。

## 12. 收尾自检与回滚

只传实际已渲染且完成安装的模块，用步骤 0 的 MODULES（追加模块后同步更新）：

```sh
node "$REPO/scripts/doctor.mjs" --home "$HOME" --agent-dir "$PI_CODING_AGENT_DIR" --modules "$MODULES"
```

PowerShell 的收尾命令：

```powershell
node "$Repo/scripts/doctor.mjs" --home $HOME --agent-dir $env:PI_CODING_AGENT_DIR --modules $Modules
```

**期望**：0 FAIL，WARN 逐条解释。doctor 只读 settings/node_modules，**不调用 pi list、不安装包**。对照 manifest：版本同 PASS；普通偏差 WARN；Pi/MC 的 major 偏差 FAIL；缺声明包 FAIL。RTK 缺失或无 rewrite 为 WARN。未实测平台会对每个组件额外报 platform verification WARN，这是标签而非故障（实测范围见 README 的平台表）。core 11 包、core+magpie+memory 13 包，macos 不增包。

**失败怎么办**：FAIL packages resolve on disk 回步骤 5（memory 查 9）；placeholders 回步骤 4；MC parameters 查 9.1。确保 0 FAIL 方可交付。

回滚顺序：先用 `-path` 禁用扩展，次退插件，最后退 Pi。已有文件备份在 `targets/`，确认后手动还原：

```sh
node "$REPO/scripts/deploy-check.mjs" backups
# 审阅后复制回 agent-dir 的 settings.json；插件回滚示例（同时影响 settings）：
pi remove npm:pi-away@0.1.4
```

数据库回滚详见 [docs/upgrade.md](docs/upgrade.md)，不要将配置备份冒充数据恢复。

## 无 key 的本地回环验收

先跑步骤 3 的 `pi --list-models`，exit 0 且无 stderr。随后在**独立临时目录**里复制本次生成的非凭据配置，创建仅含 stub provider 的 models.json（不要修改真实配置）。路径全部用 Node 的 `os.tmpdir()` 拼，两个平台一致。

依次执行（一次一条，都是独立进程）：

```sh
node "$REPO/scripts/deploy-check.mjs" stub-init
```

记录 stub-init 打印的临时 home / agent。只在用于验收的两个新终端设置隔离目录；关闭终端后恢复原来的环境。POSIX 用 `export HOME='<临时 home>'; export PI_CODING_AGENT_DIR='<临时 agent>'`；PowerShell 不可改只读的 `$HOME`，用 `$env:HOME='<临时 home>'; $env:USERPROFILE=$env:HOME; $env:PI_CODING_AGENT_DIR='<临时 agent>'`。保留仓库路径变量 REPO/Repo。

把已渲染的 `settings.json`、`AGENTS.md`、`APPEND_SYSTEM.md`、`compact-tools.json`、`agents/`、`prompts/`、`extensions/` 复制进该 agent 目录（只复制这些非凭据文件），写 models.json：

```json
{"providers":{"stub":{"baseUrl":"http://127.0.0.1:8899/v1","api":"openai-completions","apiKey":"dummy","models":[{"id":"stub-model","name":"Stub","cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":200000,"maxTokens":1000}]}}}
```

把默认模型指向 stub，并拒绝在非临时目录执行：

```sh
node "$REPO/scripts/deploy-check.mjs" stub-config
```

隔离环境里启动 stub（只监听回环；日志含 prompt，只留临时目录，禁止提交）：

```sh
node "$REPO/scripts/stub-provider.mjs" --port 8899 --log "$PI_CODING_AGENT_DIR/stub-requests.jsonl"
```

PowerShell：

```powershell
node "$Repo/scripts/stub-provider.mjs" --port 8899 --log (Join-Path $env:PI_CODING_AGENT_DIR 'stub-requests.jsonl')
```

另一终端，在同一个隔离环境里（`PI_CODING_AGENT_DIR` 指向临时 agent 目录，`HOME` 指向临时 home）：

```sh
pi --list-models
pi --provider stub --model stub-model --print --no-session 'hi'
pi --provider stub --model stub-model --print --no-session 'delegate nothing; list the subagent roles you can use'
pi --provider stub --model stub-model --print --no-session 'answer with the number of tools you can call directly'
```

**期望**：`--list-models` exit 0 且无 stderr；三条 `--print` 打印 `stub-ok`。
**失败怎么办**：隔离副本的 settings.enabledModels 若残留原配置，`--list-models` 会报 stderr；复制的 packages 含绝对本地路径时需在临时副本指向隔离产物。检查抓到的请求体：

```sh
node "$REPO/scripts/deploy-check.mjs" stub-requests
node "$REPO/scripts/deploy-check.mjs" stub-resident
```

**期望**：tools 集合准确为 ask_user / codemode / contact_supervisor / subagent / subagent_supervisor / tool_search；`stub-requests` 逐条检查，缺项或多项时打印实际集合、缺项、多项并以非零码退出。系统提示含所选模块注入（配了 RESIDENT 方有 resident_memory）。Ctrl-C 关闭 stub。此步仅验证扩展、请求体与系统提示；不证明真实模型、桌面操控、embedding 或长会话压缩。隔离环境不要设置真实 key，不可用 `--offline` 代替隔离。
