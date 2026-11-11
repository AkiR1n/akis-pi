# magpie 模块

Magpie 是一个本地网关：它提供 OpenAI 兼容的 chat 端点、MCP hub、以及生图/生视频模型。这个模块让它接管 Pi 的一部分能力，**但边界是刻意划过的**（见下）。

| 内容 | 说明 |
| --- | --- |
| `magpie.ts` | 用 Magpie 的 decision / image 模型注册 `models.classify()` / `generateImages()` 的 provider |
| `mcp.json.example` | 两个 MCP server 条目：hub（web_search/web_fetch）+ 独立 stdio（生图生视频） |
| 路由用法 | 什么时候用 Magpie、什么时候不用 |

---

## magpie.ts

这个文件**由 Magpie 自己生成**（文件头写着：把 Pi 从 Magpie 上摘掉，magpie 就不再管它）。所以它应该被当作产物：Magpie 升级后它可能被重写，你的本地改动会丢。

它做两件事：

1. 只有在宿主 Pi 支持 `typesafe.classify` 时才注册 `magpie-systemone` provider（decision 模型）。老的 Pi 拿不到任何东西，不会报错。
2. 注册 `magpie-images` provider 与 `magpie-images` 的 `generateImages` 实现，走 `POST /v1/images/generations`，支持用输入图片作参考。

Pi 的 `models.json` 只管 chat 模型，所以图片/分类模型必须由扩展注册——这就是这个文件存在的原因。

---

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

**合并，不要替换**：目标文件是 `~/.pi/agent/mcp.json`，通常已经有别的 server。`render.mjs` 不写这个文件，只打印指引——覆盖别人的 MCP 注册表不是渲染器该做的决定。

装完 **重启 Pi**（MCP 元数据在启动时缓存），然后：

```sh
pi mcp list
```

---

## 坑 1：hub 会按请求头过滤工具

同一个端点，用不同客户端看到的工具数不同：

| 客户端 | 看到的工具 |
| --- | --- |
| curl / Python 直连 | 6 个（browser、image×3、web_search、web_fetch） |
| Pi 的 Node fetch（带 `Sec-Fetch-Mode: cors`） | **2 个**（只有 web-search） |

结论：**核对一定要用 `pi mcp list`，不要用 curl**。想把生图工具拿进 Pi，就按模板配独立的 stdio server（`magpie mcp image`），不要指望 hub。

另：hub 的工具面是**服务器端配置**决定的。Magpie 里关掉的 server 在 Pi 侧也看不到，而且这个元数据在启动时缓存。

---

## 坑 2：需要斜杠命令的技能必须 direct

Magpie 的技能路由会把技能收进一份索引（`magpie-skills`），换来 Pi 的 `<available_skills>` 变短（实测 11,276 → 6,545 字符，-42%）。代价是：被路由的技能**不再有同名 `/skill:<name>` 命令**。

所以：

- 第三方通用技能（文档处理、绘图模板之类）交给路由，省索引。
- **自己的、需要明确斜杠调用的技能保持 direct**（保存话题、写个人笔记这类）。它们被路由之后，依赖 `/skill:<name>` 的流程会直接失效，而且报错方式很难懂（命令不存在）。

判断规则一句话：**如果某个流程里明确写了 `/skill:xxx`，那个技能就不能被路由。**

---

## 边界：Magpie 接管什么、不接管什么

- **接管**：搜索（第二跳反爬）、生图生视频、技能索引瘦身。
- **不接管**：记忆（那有 Magic Context）、浏览器自动化（那有 agent-browser / ego）。

理由：Magpie 只在「能减少 Pi 的模型面或维护负担」时接管。塞进第二套记忆或第二套浏览器状态，换来的是两个都要维护、且互相不知道对方存在。

---

## 没有 Magpie 怎么办

完全可用：

1. `models.json` 的 `baseUrl` 指向任意 OpenAI 兼容网关，删掉 `magpie.ts` 与 `mcp.json` 里的 magpie 条目。`settings.json` 本来就不含 Magpie 的包条目——本模块只提供扩展与 MCP 条目。
2. `APPEND_SYSTEM.md` 里所有 Magpie 相关行都标了「仅 Magpie 模块」，整段删掉不影响其余能力。
3. `AGENTS.md` 的联网路由第 3 条（403 第二跳）失效时，剩下的链路是 `web_search → fetch_content`，以及需要登录态时的浏览器技能。
