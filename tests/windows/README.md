# Windows 实机测试脚本

这组脚本只做一件事：把 [DEPLOY.md](../../DEPLOY.md) 的 PowerShell 入口在一个**可回滚的 Hyper-V 虚拟机**里跑一遍，并把证据留在宿主上。原生 Windows 目前是**试验**路径：脚本本身没有做过实机验证，第一次真实执行应当按「一轮一步、逐步看证据」的方式进行。

仓库里只有脚本，没有机器名、没有检查点名、没有凭据路径，也没有代理端口之外的主机信息——这些全部通过参数传入，不写进仓库。

## 组成

| 文件 | 运行位置 | 作用 |
| --- | --- | --- |
| `run.ps1` | 宿主（管理员 PowerShell 5.1 / 7） | 一次调用做一件事：恢复检查点、开机、建桥、拷 payload、执行 guest 步骤、回收证据、撤桥、关机 |
| `guest-deploy.ps1` | 虚拟机内 | 装 Node 24.22.3 与 Git for Windows、装 Pi 1.5.2、渲染、构建 pi-knowledge、安装所选插件、无 key stub、doctor |
| `session.ps1` | 宿主 | 按 dev/smoke 场景执行完整一轮；finally 内独立收证据、撤桥、停机、恢复返回检查点 |
| `review-mocks.ps1` | 任意 Windows 终端 | 语法与隔离 mock 回归，不调用 Hyper-V、网络规则或 Pi |

所有 PowerShell 脚本都是 **ASCII-only**：Windows PowerShell 5.1 把无 BOM 的 `.ps1` 按系统 ANSI 代码页读取，非 ASCII 字面量会被破坏。要写非 ASCII 内容就用码点拼，或写进 JSON 证据文件。

## 前置条件

- 宿主机：Hyper-V、PowerShell 管理员会话（Hyper-V cmdlet 与 `portproxy` 需要提权）、可用的 SSH 或本地终端。
- 一台**专用**测试虚拟机，以及两个检查点名（例如「日常迭代检查点」和「干净基线检查点」）。
- 一个凭据脚本：`run.ps1 -CredentialScript <路径>` 会 dot-source 它并调用 `-CredentialFunction`（默认 `Get-VmCredential`），函数返回 `PSCredential`；函数若有 `-User` 参数，就传 `-CredentialUser`。口令只在内存里存在，只交给 `New-PSSession`，不打印、不落盘。仓库**不带**任何凭据实现，也不带默认路径。
- 出网代理（可选）：`-Action bridge` 在宿主上建一条 `netsh portproxy`（`-ProxyPort` → `127.0.0.1:-UpstreamPort`）和一条同名防火墙规则，然后给虚拟机设系统代理与 `HTTP(S)_PROXY`。宿主代理不存在时脚本以 5 退出，不会静默降级。不需要代理就加 `-NoProxy`。

## 回滚策略（不含复制磁盘）

| 场景 | 做法 |
| --- | --- |
| 日常迭代用的虚拟机 | 测完 `-Action restore -Checkpoint <迭代检查点>`，回到已知状态 |
| 干净基线用的虚拟机 | 先 `-Action protect` 对当前状态建保护检查点（默认名 `akis-pre-<yyyymmdd-hhmmss>`），再 `-Action restore -Checkpoint <干净基线>` 测试，测完 `-Action restore -Checkpoint <保护检查点>` 回到测前状态 |
| 检查点清理 | 保护检查点保留，删不删由使用者决定；脚本不删除任何检查点 |

`run.ps1` 从不复制、挂载或改写磁盘文件，只调用 `Checkpoint-VM` / `Restore-VMCheckpoint` / `Start-VM` / `Stop-VM`。

## 完整一轮（推荐）

在管理员 PowerShell 中先审阅脚本，再对当前终端设置 `Set-ExecutionPolicy -Scope Process RemoteSigned`；组策略阻止时停止，不用 Bypass。本路径用现有 VM 和检查点，不复制磁盘。

```powershell
$common = @{ VmName = '<虚拟机名>'; CredentialScript = '<凭据脚本>'; CredentialUser = '<管理员账户>'; Payload = '<工作区路径>'; CommitterName = '<Git 提交者名>'; CommitterEmail = '<Git 提交者邮箱>' }
# 日常迭代：baseline 是用户指定的开发检查点；测试后恢复同一个检查点。
./tests/windows/session.ps1 -Scenario dev -BaselineCheckpoint '<开发检查点>' @common
# 干净基线：先保护当前状态，再进入干净检查点；finally 恢复保护检查点并保留它。
./tests/windows/session.ps1 -Scenario smoke -BaselineCheckpoint '<干净检查点>' @common
```

每轮生成独立 RunDir，session.json 记录返回检查点与各项清理错误。中途失败和收证据失败仍分别尝试撤桥、停机、恢复；任何一步失败整轮返回非零。进程被强制终止、宿主断电时 finally 无法运行，按 session.json 与 protect.json 手动恢复。

## 逐步流程（排错）

一轮一步，每步一次调用；每步都把 `<action>.json` 与 `run.log` 写进运行目录（`-RunDir`，未指定时是 `%TEMP%\akis-pi-vm-runs\<时间戳>`，并记在 `current.txt` 里供后续调用复用）。

```powershell
# 0) 记录一次运行目录（后续不带 -RunDir 会自动复用）
$vm = '<虚拟机名>'
$common = @{ VmName = $vm; CredentialScript = '<凭据脚本路径>'; CredentialUser = '<管理员账户>' }

# 1) 保护检查点（仅干净基线那台需要）
./tests/windows/run.ps1 -Action protect @common -Checkpoint 'akis-pre-<时间>'

# 2) 回到基线并开机
./tests/windows/run.ps1 -Action restore @common -Checkpoint '<基线检查点>'
./tests/windows/run.ps1 -Action start   @common

# 3) 建桥（不需要代理就加 -NoProxy）
./tests/windows/run.ps1 -Action bridge @common

# 4) 把工作区拷进虚拟机（.git 与 node_modules 已排除，两端比对 sha256 清单）
./tests/windows/run.ps1 -Action copy @common -Payload '<工作区路径>'   # .git、node_modules、tests/results 都不进 payload

# 5) 在虚拟机里逐步执行（每步一次调用，默认单步上限 10 分钟）
./tests/windows/run.ps1 -Action exec @common -GuestStep prereq  -ActionTimeoutMinutes 12
./tests/windows/run.ps1 -Action exec @common -GuestStep render
./tests/windows/run.ps1 -Action exec @common -GuestStep knowledge -ActionTimeoutMinutes 12 -GuestCommitterName '<Git 提交者名>' -GuestCommitterEmail '<Git 提交者邮箱>'
./tests/windows/run.ps1 -Action exec @common -GuestStep packages -ActionTimeoutMinutes 12
./tests/windows/run.ps1 -Action exec @common -GuestStep stub
./tests/windows/run.ps1 -Action exec @common -GuestStep doctor
./tests/windows/run.ps1 -Action exec @common -GuestStep summary

# 6) 收证据 → 关机 → 撤桥（finally 撤桥；-KeepRunning 只保留 VM 运行）
./tests/windows/run.ps1 -Action collect @common

# 7) 回到测前状态
./tests/windows/run.ps1 -Action restore @common -Checkpoint '<保护检查点或迭代检查点>'
```

exec 默认部署到 `%USERPROFILE%\.pi\agent`；要验证别的目标目录（例如含中文与空格的路径）就每次 exec 都传同一个 `-GuestAgentDir '<目标目录>'`，guest 侧据此设置 `PI_CODING_AGENT_DIR`、渲染、装插件并自检。

只用 core 时每个 exec 都传 `-GuestModules core` 和 `-SkipKnowledge`。doctor 总是检查实际选择的模块；选 memory 但没构建成功必须失败，不能自动改查 core。git am 身份仅用命令级 -c 传入，不写 Git 配置。

## 每步的证据与判据

| 步骤 | 落盘文件 | 通过判据 |
| --- | --- | --- |
| `protect` / `restore` | `protect.json` / `restore.json`（含检查点前后清单） | 检查点存在或已恢复；`restore` 要求虚拟机为 Off |
| `start` | `start.json`（含虚拟机指纹：OS、PowerShell 版本、用户目录是否为纯 ASCII、node/git 是否存在） | PowerShell Direct 能连上 |
| `bridge` | `bridge.json` | 宿主机经桥访问 registry.npmjs.org 返回 HTTP 200，虚拟机内同样 200 |
| `copy` | `copy.json` + `payload.zip` | 两端 sha256 清单一致 |
| `exec` | `guest-<step>.txt`、`exec.json` | guest 脚本以 `RESULT=0` 结束 |
| `collect` | `guest/**`、`collect.json`、`unbridge.json` | 文件回收完毕、虚拟机回到 Off、`portproxy` 与防火墙规则清空 |

guest 侧每步都会写 `<OutDir>\<step>.json` 与 `guest-deploy.log`，所以即使宿主侧超时，也能从这些文件看出停在哪一步。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 未预期错误 |
| 2 | 前置条件不满足（虚拟机状态、检查点、缺参数、payload 路径） |
| 3 | guest 执行或拷贝失败 |
| 4 | 超过 `-ActionTimeoutMinutes`；finally 尝试撤桥，VM 可能还在，接着跑 `-Action stop`，再恢复返回检查点 |
| 5 | 代理桥失败（上游端口没监听、端到端不通、虚拟机内不通） |
| 6 | 清理不完整（portproxy 或防火墙规则仍有残留） |

## 已知边界

- PowerShell Direct 是**远程会话**，不是真实交互桌面。执行策略、Appx/winget、桌面交互（computer-use）必须另做验证；脚本把执行策略改成 `RemoteSigned` 是为了复现 DEPLOY 里的用户动作，不是「用 Bypass 掩盖问题」。
- 计划任务路线在该类镜像上不可靠（任务可能长期停在 Queued），所以 guest 步骤走 Direct 同步执行。
- 单次调用控制在约 12 分钟以内；`npm ci`、Git 与 Node 安装都可能接近这个上限，所以拆成独立步骤，失败可重入。
- `review-mocks.ps1` 在 PS 5.1/7 下验证失败清理与 dev/smoke 返回检查点；这是控制流验收，不能代替 VM 安装、真实代理或真实模型验收。
- 桥、防火墙规则与运行目录都带本任务的名字前缀，撤桥只按 bridge-state.json 里本轮拥有的精确地址/端口/规则名删除；遇到已有同地址规则直接失败，不删除它。collect 无论成功、失败或 KeepRunning 都会在 finally 撤桥。
