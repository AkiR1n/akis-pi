# WSL2 实机测试脚本

在**已有 Hyper-V 测试虚拟机里的 WSL2** 中，把 [DEPLOY.md](../../DEPLOY.md) 的 POSIX 入口跑一遍：渲染 core,memory、按需构建 pi-knowledge、无 key stub 自证、doctor 自检。Windows 用户默认推荐的部署路线就是这条（WSL2 core+memory），但本仓库还没有它的实机验收记录。

## 使用现有测试虚拟机

不要复制 VHD 或导出、导入发行版，也不要使用宿主日常发行版。按 [Windows 测试回滚策略](../windows/README.md) 使用现有 Hyper-V 虚拟机：日常迭代 VM 测完恢复指定的开发检查点；干净基线 VM 先对当前状态建保护检查点，再进入干净基线，测完恢复保护检查点并保留它。WSL 的安装与全部测试都在该 VM 内完成；宿主的收证据、撤桥、停机和恢复必须放在 finally 中。

## 运行

脚本在**发行版内部**执行，一次一个 `--step`：

```powershell
# 在测试 VM 内，把工作区先复制到发行版的 /home 下；下面路径为 Linux 路径。
wsl -d Ubuntu-24.04 -- bash /home/<user>/akis-pi/tests/wsl/run.sh --step prereq --out /tmp/akis-wsl-evidence
```

如果仓库本身就在 WSL 的 `/home` 下（推荐），直接：

```sh
# 每一步复用同一个 --out；知识补丁身份只传给本次 git am，不改 Git 配置。
out=/tmp/akis-wsl-evidence
bash <仓库>/tests/wsl/run.sh --step prereq --out "$out"
bash <仓库>/tests/wsl/run.sh --step render --out "$out"
bash <仓库>/tests/wsl/run.sh --step knowledge --out "$out" --committer-name '<提交者名>' --committer-email '<邮箱>'
bash <仓库>/tests/wsl/run.sh --step packages --out "$out"
bash <仓库>/tests/wsl/run.sh --step stub --out "$out"
bash <仓库>/tests/wsl/run.sh --step doctor --out "$out"
bash <仓库>/tests/wsl/run.sh --step summary --out "$out"
```

只用 core 时每一步都加 `--modules core --skip-knowledge`。doctor 检查实际选择的模块，不会隐藏未构建成功的 memory。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--step` | `all` | `all` 会串行跑完全部步骤，容易超过单次调用预算，建议逐步执行 |
| `--repo` | 脚本上两级目录 | 发行版内的仓库根目录 |
| `--out` | `<tmp>/akis-pi-wsl-<时间戳>` | 证据目录：`<step>.json`、`run.log`、`doctor-raw.json`、`stub-requests.jsonl` |
| `--modules` | `core,memory` | 渲染的模块 |
| `--agent-dir` | `$HOME/.pi/agent` | Pi 配置目录 |
| `--stub-port` | `18899` | 回环 stub 端口（只监听 127.0.0.1） |
| `--skip-knowledge` | 关 | 跳过 pi-knowledge 的 clone/补丁/构建 |
| `--committer-name` / `--committer-email` | 无 | knowledge / all 步骤必须提供的临时 Git 身份 |

## 判据

- `prereq`：记录发行版、内核、架构、Node/npm/git/Pi 版本与 `$HOME` 所在文件系统类型。Node 不是 24.22.3 时从 nodejs.org 装（校验 `SHASUMS256.txt`），不覆盖系统包。
- `render`：dry run 有 create/unchanged/diff；`--apply` 后关键产物齐全（settings、AGENTS、APPEND_SYSTEM、compact-tools、rtk 扩展、subagent 配置，memory 另含 resident-memory 与 MC 配置），8 个角色文件都在；第二次 `--apply` 不再新建文件。
- `knowledge`：补丁按 `0001`→`0004` 顺序 `git am` 成功，`npm ci`、`npm run build` 通过，`dist/index.js` 存在。
- `packages`：从 manifest 安装所选模块的 npm 插件，失败即停止；不把渲染成功当成插件已安装。
- `stub`：三次 `pi --print` 都退出 0 并返回 `stub-ok`，每个请求的直接工具恰为 `ask_user,codemode,contact_supervisor,subagent,subagent_supervisor,tool_search`。memory 用独立 HOME 中的合成 RESIDENT，逐条断言 `<resident_memory>` 与合成标记；不会读取用户记忆。MC 配置从部署目录复制，XDG、存储与日志均隔离，避免切 HOME 后跑成上游默认配置。
- `doctor`：`--json` 解析后 FAIL 必须为 0；WARN 逐条解释（未实测平台的 platform verification WARN 属正常）。

## 退出期调查

在明确授权的可丢弃部署中使用 `exit-probe.py`；它不会重试，保存每次退出码、信号、stdout/stderr、请求、Linux 原生模块 maps 采样及每轮结束后的 SQLite `PRAGMA integrity_check`。它保留合成 HOME 和数据库，证据收集后再清理整个测试环境；不要在日常配置上运行。

```sh
python3 tests/wsl/exit-probe.py --repo "$PWD" --agent-dir "$PI_CODING_AGENT_DIR" \
  --mc-config "$HOME/.config/cortexkit/magic-context.jsonc" \
  --out /tmp/exit-matrix --config default --variants core,mc,knowledge,memory --rounds 5
python3 tests/wsl/exit-probe.py --repo "$PWD" --agent-dir "$PI_CODING_AGENT_DIR" \
  --mc-config "$HOME/.config/cortexkit/magic-context.jsonc" \
  --out /tmp/exit-gate --config deployed --rounds 20
```

`--config default` 专用于复现旧驱动遗漏 MC 配置的行为；放行用 `deployed` 保留渲染配置与全部 memory 包。核心、单一记忆包的变体仅供归因。`trace-lifecycle.cjs` 可作为单独诊断运行的 `NODE_OPTIONS=--require=<绝对路径>`，记录 abort 调用点、显式退出栈与 sharedObjects；它使用 `uncaughtExceptionMonitor`，不会吞异常。maps 为空不代表没载入原生模块，尤其 macOS 没有 /proc。

## 边界

- `wsl -d` 会写发行版数据，所以仅在已设返回检查点的测试 VM 中运行；测试后恢复检查点。
- **源码、`node_modules`、知识库与 Magic Context 数据必须放在 WSL 的 `/home`**，不要放 `/mnt/c`：跨文件系统访问慢一个数量级，权限与大小写语义也不同，`npm ci` 与 SQLite 都可能出错。
- WSL 里没有 launchd / Keychain，macos 模块不可选；凭据只能用 `$VAR`。
- 需要操作 Windows 桌面或复用 Windows 登录态浏览器时不要用 WSL：那里跑的是 Linux 后端。
- WSL 访问 Windows 侧服务（Magpie、PDF 端点）不能假定 `127.0.0.1`，先在发行版内验证可达性。
