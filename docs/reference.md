# 参考：版本、依赖与平台

[README](../README.md) 只留表格，这里放表格背后的事实：为什么钉这些版本、各平台还要补什么、支持级别怎么定。装的时候照 [DEPLOY.md](../DEPLOY.md) 走，取舍理由见 [decisions.md](decisions.md)。

## 版本与依赖

### Node 24.22.3

**不要用 24.19.0–24.21.x。** 这几个版本给 `ObjectWrap` 补了 cleanup hook，却没带上配套的注册表（上游 nodejs/node#65446）。pi-knowledge 用的 better-sqlite3 在垃圾回收时释放 Statement，会在这个空档里断言失败，进程直接以 SIGABRT 退出。

实测：WSL2 上同时加载 Magic Context 与 pi-knowledge，24.21.0 跑 20 轮崩 9 轮、交互会话 3 次崩 2 次；只换成 24.22.3，20 轮与 TUI 10 次全部正常，崩溃轮次的数据库完整性检查也没坏。在 pi-knowledge 里持有 Statement 引用的补丁试过，无效，已丢弃。

macOS 的 better-sqlite3 预编译件不走这条路径，所以在 Mac 上不容易复现，但同样不要低于 24.22.0。Pi 与全局 CLI 用同一份 Node；`mise` 只是 render 的可选开关，不是要求。

### Pi 1.5.2

配的插件与扩展是按这一组版本测的。1.5.0 起工具参数校验换了实现（`@earendil-works/pi-schema`），1.5.1 改过 grep 扩展接口，1.5.2 修了会话 fork 与重复 import。跨版本混装时先读 [upgrade.md](upgrade.md)。

### Git

POSIX 系统自带。原生 Windows 必须装 Git for Windows：Pi 的 shell 与凭据的 `!command` 都走它的 bash，缺了这两块都不工作。部分镜像的默认执行策略是 Restricted，要按上游说明放开，不要用 Bypass 掩盖问题。

### Python 3.9+

只有 pdf 模块需要：它是本地 PDF→Markdown 端点，用 PyMuPDF 解析，无文本层的扫描件返回 422 让上游回退 OCR。不装 pdf 模块就不需要 Python。

### Magpie

**必装，不是可选。** 模型路由、生图与生视频、反爬时的抓取兜底（`web_fetch`）、技能索引与 MCP 路由都经它，`rtk` 也是它装的。少了它，`APPEND_SYSTEM.md` 里那几条规则没有对象，等于换了一套配置：Pi 裸件接任意 OpenAI 兼容服务仍然能用，但那已经不是这份配置。

### 模型分工与凭据

模板中所有模型位置均为占位符，不绑定特定供应商或商业模型：

| 占位符 | 角色定位 | 选取建议 |
| --- | --- | --- |
| `{{MODEL}}` | 主会话默认模型 | 日常主力交互 |
| `{{MODEL_EXEC}}` | 廉价执行：测试、脚手架、前端、批量改动 | 单价低、能稳定跑脚本的模型 |
| `{{MODEL_REVIEW}}` | `analyze`：读证据、比较方案、查根因 | 比执行档更强的通用模型 |
| `{{MODEL_PLAN}}` | `review`：验收完成声明、复核 diff | 最强的旗舰模型；也可给 `analyze` 处理路线评审 |
| `{{MODEL_HISTORIAN}}` | 会话压缩归档 | 窗口大、价格低，不要求强推理 |

分工原则：日常干活用执行档，分析用较强的通用模型，验收用最强模型。

**角色与模型解耦**：五个角色文件都不写 `model` 字段，档位只在 settings 里定义：

| 角色 | 工具面 | 默认档 |
| --- | --- | --- |
| `explore` | 读 + 联网，无 bash | `{{MODEL_EXEC}}` |
| `implement` | 读 + 联网 + bash + 写 + codemode | `{{MODEL_EXEC}}` |
| `lead` | implement 的全部 + subagent | `{{MODEL_EXEC}}` |
| `analyze` | 读 + 联网 + bash，无写 | `{{MODEL_REVIEW}}` |
| `review` | 同 analyze | `{{MODEL_PLAN}}` |

`subagents.defaultModel` 填 `{{MODEL_EXEC}}`，`agentOverrides` 只覆盖 analyze 与 review。这样主会话换成强模型时，`implement` / `explore` 仍走执行档，不会跟着变贵；主会话是执行档时，`analyze` / `review` 自动升档。

**需要别的档位就在调用上写**：`subagent({agent: "implement", model: "{{MODEL_PLAN}}", task})` 就是"强模型做执行"；`lead` 加同一句就是"强模型带队"。`{{MODEL_REVIEW}}` 允许等于 `{{MODEL_EXEC}}`，那时 `analyze` 不再强于执行模型，交叉检查只能靠换族而不是换档。

凭据只接受环境变量引用（`$VAR` / `${VAR}`）或 `!command`，明文会被 render 直接拒绝。macOS 可以走系统钥匙串，其它平台用环境变量。

## 平台支持

macOS arm64 与 WSL2（Ubuntu 24.04 x64）的 core+memory 已完成实机验收，其余平台与模块按 README 表格里的级别使用。上游支持不等于本包已验证：manifest 的 `platforms` 表示适用平台，`verified` 单独记录实测平台，doctor 在未实测平台会对每个组件报 `WARN`。

**Windows 默认选 WSL2 的 core+magpie+memory**：源码、`node_modules`、Magic Context 数据库与知识库都放在 WSL 的 `/home` 下，不要放 `/mnt/c`（跨文件系统访问慢一个数量级，权限与大小写语义也不同）。只有需要操作 Windows 桌面、或复用 Windows 登录态浏览器时才选原生 Windows。

**原生 Windows 是试验路径**：安装、doctor 与探针都过了，长时间运行、TUI 与桌面能力没验。launchd、钥匙串、herdr 与 tmux 面板在 Windows 上没有等价实现：服务改用计划任务，凭据改用环境变量。`ego-browser` 本体上游有 Windows 安装器，但本包没在 Windows 上实测；`ego-gc` 依赖 POSIX 路径，不提供。

**Linux 原生没有实机记录**，等级由 WSL2 的结果推断。

## 平台专属依赖

### 原生 Windows

- **Git for Windows**：见上，Pi 的 shell 与凭据命令都依赖它。
- **Microsoft Visual C++ 2015-2022 x64 可再发行组件**：onnxruntime-node 的原生绑定需要它。缺 `vcruntime140.dll`、`vcruntime140_1.dll`、`msvcp140.dll` 时报 Win32 126，这种情况 npm 的 approve / rebuild 修不好。
- **npm 11 的安装脚本审批**：npm 11 默认跳过未审批的安装脚本，onnxruntime-node 的 postinstall 属于这一类。用 `npm install-scripts` 查看与审批，再 rebuild。
- **`tree-sitter-qmljs` 没有预编译产物**：memory 的第 4 份补丁把它降级为可选依赖，装不上只影响 `.qml` 文件的解析粒度，其它语言不受影响。
- **浏览器控制**：`agent-browser` 按其上游自述属于 best-effort，会话锁、恢复与退出清理都要单独验收。

### WSL2 与 Linux

- **`ONNXRUNTIME_NODE_INSTALL=skip`**：onnxruntime-node 1.30.0 在 Linux x64 默认下载 CUDA 执行提供程序，下载器不跟随重定向，遇 302 会失败并可能让整个可选包被丢弃；CPU 绑定与运行库本来就在 npm 包里。
- **`ONNXRUNTIME_NODE_INSTALL_CUDA=skip`**：pi-knowledge 依赖链上的 1.21.0 用另一个变量名，`npm ci` 前两个都要设。
- **源码与 `node_modules` 放 `/home`**：跨 `/mnt/c` 访问慢一个数量级，权限与大小写语义也不同。

### macOS

不需要额外依赖，LaunchAgent 与系统钥匙串用它自带机制。

## 自查

装之前没法一条命令验完，装完可以：

```sh
node scripts/doctor.mjs --home "$HOME" --modules core,magpie
node scripts/deploy-check.mjs onnx   # 选 memory 时，确认 onnxruntime-node 能加载
```

doctor 的 0 FAIL 是装对了的判据；平台相关的 WARN 属正常，见 [upgrade.md](upgrade.md)。
