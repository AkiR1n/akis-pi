# macos 模块

四块互相独立的东西，都在 macOS 上验证过；Linux 不适用（除了 Keychain 那条有替代写法）。

| 组件 | 触发条件 | 不装的后果 |
| --- | --- | --- |
| `herdr-agent-state.ts` | 只在 `HERDR_ENV=1` 且 `HERDR_SOCKET_PATH` / `HERDR_PANE_ID` 存在时 | herdr 面板不显示 Pi 的工作状态 |
| `ego-gc.ts` | 只在 `ego lite` 已在运行时 | 中断/子代理留下的 ego 窗口会残留（每个 0.4–0.8 GB） |
| `pdf-parse/` | pi-web-access 的 `pdf.endpointUrl` | 扫描版/表格型 PDF 只能走远程 OCR |
| Keychain 引用 | 搜索类插件要 key 时 | 只能把 key 放环境变量 |

---

## herdr-agent-state.ts

由 herdr 生成并管理（文件头写明「重装 herdr 会覆盖」）。它通过 unix socket 向 herdr 报告 `working / blocked / idle` 与会话引用，**没有任何副作用**：环境变量不齐时 `enabled()` 直接返回 false，一个 socket 都不建。

自定义 hook 请放在这个文件旁边的新文件里，不要改它——下次 herdr 升级会覆盖。

装法：`~/.pi/agent/extensions/herdr-agent-state.ts`（自动加载）。

---

## ego-gc.ts

**为什么存在**：每个 ego-browser task space 都是一个真实浏览器窗口（实测 0.4–0.8 GB）。技能脚本会关自己的窗口，但脚本被杀、回合中断、子代理忘了关时没人收尾——那正是扩展能覆盖、而「写在 SKILL.md 里让模型记得」覆盖不到的路径。

行为：

- 只从 bash 命令里判断「这一轮碰过浏览器」，没碰过就不会去调 ego CLI。
- `agent_settled`（回合真的结束）时后台清扫，有节流，不阻塞回合结束。
- `session_shutdown` 会等待在飞的清扫，然后必要时再扫一次（最后一次机会）。
- `session_start` 清理上一次会话的残留（不阻塞启动）。
- 从不拉起 `ego lite`：`pgrep` 不命中就直接跳过。
- 只关 agent 创建的空间；用户自己的空间永不触碰，`keepSpace: true` 的窗口由 keep 文件保护。

开关：`PI_EGO_GC=off` 关闭；`PI_EGO_GC_DEBUG=1` 打日志到 `/tmp/pi-ego-gc.log`。

依赖一个 `~/.local/bin/ego-gc` wrapper 与 `~/.pi/agent/skills/ego-search/scripts/gc.js`。没有 ego 时这个扩展会自己失效（不报错），也可以直接删掉文件。

---

## ego-browser / ego-search：只写来源，不复制代码

这两个技能属于第三方 app（ego lite），**不在本仓库里**，也不应该复制过来：它们的正文与选择器随 app 版本变化，复制一份等于维护一个必然过期的分支。

- 安装：装 ego lite 并按它自己的 onboarding 完成，技能会安装到它管理的位置；Pi 侧只留一个指向它的符号链接。
- 本仓库只提供 `ego-gc.ts`：那是**回收**逻辑，属于配置而不是第三方代码。
- 依赖它们的路由（AGENTS.md 的「联网与浏览器路由」）写的是**能力**，不是路径。没装 ego 就不生效，其它路由不受影响。

---

## pdf-parse：本地 PDF → Markdown 端点

`server.py` 用 PyMuPDF 按视觉顺序抽文本、把检测到的表格转成 Markdown，纯离线、不调模型。**无可用文本层时返回 422**，让 pi-web-access 的 `pdf.provider: "auto"` 链自动落到 Gemini OCR；`/health` 返回 `{"ok": true}`。

```sh
node ../../scripts/render.mjs --home "$HOME" --modules core,macos --apply
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/com.example.pipdfparse.plist"
curl --noproxy '*' http://127.0.0.1:8791/health
```

**plist 里的路径是渲染时写死的绝对路径**（launchd 不展开 `~`）。移动目录后重装 plist。

**降级方案**：不想常驻就 `launchctl bootout`，保留 `pdf.provider: "auto"`——端点不可用时链会自己跳过。要更隔离可以改成系统级 LaunchDaemon + 低权限账号（本机就是这么跑的），但那需要 `sudo`，而且要把 venv、日志、TMPDIR 都挪到服务账号可写的位置；不属于「照抄即可」的范围，本仓库只给用户级 LaunchAgent 模板。

**换端口**：`PI_PDF_PARSE_PORT` 与 `web-search.json` 的 `pdf.endpointUrl` 必须一起改。

---

## Keychain 用法（搜索类插件的 key）

配置里**只有引用，没有值**。macOS 上两种合法写法：

```sh
# 1) 系统钥匙串：交互输入，不进 shell 历史
security add-generic-password -a "$USER" -s <服务名> -w
# 配置文件写： "braveApiKey": "!security find-generic-password -a \"$USER\" -s <服务名> -w"

# 2) 环境变量
export BRAVE_API_KEY=...
# 配置文件写： "braveApiKey": "!printenv BRAVE_API_KEY"
```

服务名自己起，**不要**在仓库、笔记或提交里出现任何真实 key。`render.mjs` 的 `--set BRAVE_KEY_REF=...` 只接受引用形式的字符串（以 `!` 开头），填明文会被可读性检查抓出来。

---

## agent-browser 与 mise 别名漂移

Pi 的 `npmCommand` 用 `mise exec node@24.21.0`，而扩展里解析 `node@24` 时，`node/24` 指向**最后一次安装的 24.x**。`agent-browser` 这个全局 CLI 必须装在同一个 node 树里，否则扩展报 `could not be validated`。

```sh
ls -d ~/.local/share/mise/installs/node/24*       # 看现在有哪些
readlink ~/.local/share/mise/installs/node/24     # 别名指向谁
~/.local/share/mise/installs/node/<ver>/bin/npm install -g agent-browser@0.41.2
~/.local/share/mise/installs/node/<ver>/bin/agent-browser --version
```

装完用 `tools.agent_browser({args:["doctor"]})` 确认。**mise 每次装新的 24.x 都要重做这一步**——这是本模块唯一会「静默坏掉」的地方。
