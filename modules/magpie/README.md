# magpie 模块

Magpie 是一款本地服务网关：提供 OpenAI 兼容的对话端点、MCP 工具 Hub、以及本地图像与视频生成模型接口。本模块用于将 Magpie 的部分能力接入 Pi coding agent。

| 模块内容 | 功能说明 |
| --- | --- |
| `magpie.ts` | 利用 Magpie 的分类决策模型与生图模型，向 Pi 注册 `models.classify()` 与 `generateImages()` 提供商 |
| `mcp.json.example` | 提供两个 MCP 服务配置参考：Hub 端点（web_search / web_fetch）与独立 stdio 服务（生图生视频） |
| 路由集成策略 | 明确规范何时调用网关能力、何时保持本地原生链路 |


## magpie.ts

该文件在实际使用中由 Magpie 网关应用生成与维护（文件头注有自动生成声明）。当 Magpie 升级或重新接入时可能会被重写，手动修改可能会丢失。

扩展主要实现两项机制：
1. 检测宿主 Pi 是否支持 `typesafe.classify` 能力；若支持，则注册 `magpie-systemone` 提供商（用于本地小模型快速决策）。旧版 Pi 不支持该接口时静默跳过。
2. 注册 `magpie-images` 提供商及 `generateImages` 实现，对接 `POST /v1/images/generations` 接口，支持将输入图像作为参考图进行多模态生成。

Pi 的 `models.json` 仅管理文本对话模型，图像与分类能力需通过 TypeScript 扩展注册。


## mcp.json.example

```json
{
  "mcpServers": {
    "magpie-image": {
      "command": "/Applications/magpie.app/Contents/MacOS/magpie",
      "args": ["mcp", "image"]
    },
    "magpie": {
      "url": "http://127.0.0.1:3425/mcp/magpie/hub/pi",
      "description": "Tools of magpie-web-search (...)"
    }
  }
}
```

示例里的 `command` 是 macOS 应用内的可执行文件。其它平台换成该平台的实际路径或 PATH 上的可执行名：原生 Windows 用 magpie 的 `.exe`，Linux 用对应 CLI；`url` 仍是回环 HTTP，不需要改。不要把 macOS 路径照抄到别的平台。

**增量合并**：目标文件为 `~/.pi/agent/mcp.json`，用户环境中通常已有其他外部服务。`render.mjs` 不会自动写入该文件，按示例合并，不要覆盖现有配置。

配置后需重启 Pi 进程（MCP 工具元数据在启动时加载缓存），随后验证：

```sh
pi mcp list
```


## 常见注意事项 1：Hub 端点依据请求头过滤暴露工具

访问相同的 Hub 端点时，不同的请求头会导致返回不同的工具列表：

| 请求客户端 | 暴露的工具列表 |
| --- | --- |
| curl / Python 原生直连 | 6 个（browser、image×3、web_search、web_fetch） |
| Pi 底层 Node fetch（携带 `Sec-Fetch-Mode: cors`） | **2 个**（仅保留 web-search 与 web_fetch） |

排错以 `pi mcp list` 的输出为准，不要只凭 curl 结果判断。若要在 Pi 中调用生图工具，需配置独立的 stdio 本地进程（`magpie mcp image`），不要依赖 HTTP Hub 聚合。

另外，Hub 暴露的工具集取决于服务端的全局配置。若在 Magpie 界面中关闭了某个服务，Pi 同样无法感知。


## 常见注意事项 2：需斜杠调用的交互技能必须保持直接注册

Magpie 的技能聚合机制会将外部技能归集为统一索引文件（`magpie-skills`），将 Pi 的直接技能提示词从 11,276 字符降至 6,545 字符（降幅 -42%）。代价是：**被归集的技能在 Pi 终端中不再拥有专属的 `/skill:<name>` 命令**。

配置技能路由的原则：
- 通用型、模型自主调用的第三方技能（如格式转换等）可交给网关统一索引以节省提示词。
- 需要用户手动输入斜杠命令调用的私有技能，必须保持直接注册（direct）（如保存话题、记日记等），否则命令无法识别。

判据：需要通过 `/skill:xxx` 触发的技能，不要收入网关统一路由。


## 职责边界：接管范围与非接管范围

- **委托接管**：针对 403 反爬的第二跳网络正文抓取（`web_fetch`）、本地图像与视频生成模型、通用外部技能的提示词索引瘦身。
- **保留原生**：跨会话上下文记忆（由 Magic Context 管理）、浏览器自动化控制（由 agent-browser / ego 管理）。本地已有成熟实现，接入网关只会多一套状态。


## 无 Magpie 环境下的平替方案

未部署 Magpie 时，配置依然可用：
1. 将 `models.json` 的 `baseUrl` 指向任意 OpenAI 兼容地址，在 `settings.json` 与 `mcp.json` 中移除相关条目。`settings.json` 本身不含 Magpie 的 npm 依赖。
2. `APPEND_SYSTEM.md` 中关于 Magpie 的规则均标有模块作用域标签，删除该段落不影响其他能力。
3. 缺少 403 抓取兜底时，网络交互沿用默认的 `web_search → fetch_content` 链路；遇到反爬或需登录站点时，通过浏览器自动化技能处理。
