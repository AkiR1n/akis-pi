# macos 模块

本模块包含四项针对 macOS 环境验证的功能组件；除 Keychain 凭据规范在其它平台有对应替代语法外，其余组件均针对 macOS 系统特性设计。

| 组件 | 生效触发条件 | 未安装时的影响 |
| --- | --- | --- |
| `herdr-agent-state.ts` | 仅在检测到环境变量 `HERDR_ENV=1` 且存在 `HERDR_SOCKET_PATH` / `HERDR_PANE_ID` 时生效 | herdr 面板无法实时显示 Pi 的代理工作状态 |
| `ego-gc.ts` | 仅在后台检测到 `ego lite` 浏览器进程正在运行时介入 | 异常中断或子代理遗留的浏览器窗口无法自动回收（每个窗口约占用 0.4–0.8 GB 内存） |
| `pdf-parse/` | 提供本地端点，作为 pi-web-access 的 `pdf.endpointUrl` | 扫描件或复杂表格 PDF 只能回退至远程 OCR 解析 |
| Keychain 凭据规范 | 搜索及外部插件读取 API Key 时 | 只能将凭据置于纯环境变量中 |

---

## herdr-agent-state.ts

该扩展用于与多代理窗格管理工具 herdr 协同（源码文件头已注明「herdr 重新安装时会覆写此文件」）。它通过 Unix Domain Socket 向上层面板报告当前状态（`working` / `blocked` / `idle`）及关联会话 ID。当环境变量不齐全时，`enabled()` 检查直接返回 `false`，不会建立 socket 连接。

若需添加自定义钩子，建议在同级目录下建独立扩展文件，避免在更新时被覆盖。

安装路径：`~/.pi/agent/extensions/herdr-agent-state.ts`（由 Pi 自动加载）。

---

## ego-gc.ts

**设计背景**：每个 ego-browser 任务空间对应一个真实的 Chromium 浏览器窗口（内存开销约 0.4–0.8 GB）。脚本在异常终止、中途打断或子代理退出时容易残留窗口。该扩展在底层兜底清理此类遗留资源。

清理机制：
- 分析 bash 执行记录识别当轮对话是否调用过浏览器；未调用则不触发检测。
- 会话交互结束（`agent_settled`）时在后台异步执行轻量清扫，不阻塞交互。
- 会话关闭（`session_shutdown`）时等待清扫任务结束，并在必要时执行清理。
- 会话启动（`session_start`）时异步清理历史残留，不阻塞启动流程。
- 检测不到正在运行的 `ego lite` 进程时立即静默跳过，不主动拉起浏览器。
- 仅回收代理创建的任务空间；手动打开的和配置了 `keepSpace: true` 的窗口不会误关。

调试与控制：通过环境变量 `PI_EGO_GC=off` 禁用；设置 `PI_EGO_GC_DEBUG=1` 输出日志至 `/tmp/pi-ego-gc.log`。

环境依赖：依赖系统路径中的 `~/.local/bin/ego-gc` 脚本与 `~/.pi/agent/skills/ego-search/scripts/gc.js`。未安装 ego 时扩展会自动跳过，也可直接删除。

---

## ego-browser / ego-search：第三方技能引用说明

上述两项技能由第三方应用（ego lite）管理，不包含在本仓库源码内，也无需复制代码：内部逻辑随应用版本演进，复制代码容易脱节。

- 安装方式：启动 ego lite 完成初始化设置，技能自动部署至系统路径；Pi 侧只需保留符号链接。
- 本仓库职责：只提供 `ego-gc.ts` 负责资源回收，不分发技能源码。
- 路由兼容：`AGENTS.md` 中的浏览器路由基于环境能力探测。未安装时自动跳过，不影响常规搜索。

---

## pdf-parse：本地 PDF → Markdown 离线端点

`server.py` 用 PyMuPDF 在本地提取 PDF 排版文本并转为 Markdown，无外部调用成本。检测到文件无文本层（如扫描件）时返回 422 状态码，引导上层 pi-web-access 回退至远程 OCR；根路径 `/health` 返回 `{"ok": true}`。

部署与启动：

```sh
node ../../scripts/render.mjs --home "$HOME" --modules core,macos --apply
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/com.example.pipdfparse.plist"
curl --noproxy '*' http://127.0.0.1:8791/health
```

**服务说明**：.plist 配置文件路径由渲染脚本生成为宿主机绝对路径（launchd 默认不展开 `~`）。若移动了家目录或服务路径，需重新渲染并重载 plist。

**运行模式**：不想常驻后台可执行 `launchctl bootout` 注销服务，配置保留 `pdf.provider: "auto"`，本地不可用时自动改用云端解析。进阶场景可配置为系统 LaunchDaemon 配合独立低权限账户运行，需管理员权限（`sudo`）并调整目录权限，本仓库默认提供易于部署的用户级 LaunchAgent 模板。

**端口调整**：修改监听端口需同步调整环境变量 `PI_PDF_PARSE_PORT` 与 `web-search.json` 中的 `pdf.endpointUrl`。

---

## Keychain 凭据规范（搜索类插件调用 Key）

本配置仓库只保留凭据引用，不存储密钥明文。macOS 下推荐两种安全写法：

```sh
# 1) 写入系统钥匙串（交互式读取，避免在 shell 历史记录中泄露明文）：
security add-generic-password -a "$USER" -s <服务名> -w
# 配置文件中填入引用： "braveApiKey": "!security find-generic-password -a \"$USER\" -s <服务名> -w"

# 2) 通过环境变量提供：
export BRAVE_API_KEY=...
# 配置文件中填入引用： "braveApiKey": "$BRAVE_API_KEY"
```

钥匙串的服务名称由用户自行定义，不要在仓库提交、笔记或配置中粘贴真实密钥。渲染脚本 `render.mjs` 的 `--set BRAVE_KEY_REF=...` 仅接受以 `!` 开头的动态引用字符串，直接输入明文会被拦截拒绝。

---

## agent-browser 与 mise 版本别名一致性

Pi 的 `npmCommand` 默认通过 `mise exec node@24.21.0` 运行，而在部分扩展解析 Node 时，系统别名 `node/24` 会指向最后安装的 24.x 版本。全局 CLI 工具 `agent-browser` 必须装在当前 Node 运行树中，否则扩展会报 `could not be validated` 校验失败。

环境排查与安装：

```sh
ls -d ~/.local/share/mise/installs/node/24*       # 查看已安装版本
readlink ~/.local/share/mise/installs/node/24     # 查看别名指向的目标目录
~/.local/share/mise/installs/node/<ver>/bin/npm install -g agent-browser@0.41.2
~/.local/share/mise/installs/node/<ver>/bin/agent-browser --version
```

安装后可通过工具调用 `tools.agent_browser({args:["doctor"]})` 验证连通性。通过 mise 安装新的 Node 24.x 小版本后需重新核对，避免运行时路径产生偏移。
