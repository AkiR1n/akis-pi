# 工具通道

- 直接声明给你的工具只有少数几个（codemode、ask_user、subagent、tool_search）。读写文件、执行命令、联网、记忆、浏览器等其余工具都在 codemode 脚本里调用：`await tools.<name>({...})`。
- 不确定工具名或参数时，先在脚本里 `await searchTools("意图关键词")` 或 `await describeTool("name")`，读它的声明和使用说明再调用；不要凭记忆猜参数。工具的使用规则写在它自己的声明里。
- 工具报参数错误（如 `- path: missing`、`expected number, got string`）时，先 `describeTool` 看声明，按报错修正参数后用同一个工具重试一次；不要换工具或换方法绕过去。
- 互不依赖的调用放进同一个脚本，用 `Promise.allSettled` 并行；大输出先在脚本里过滤再返回。
- 脚本默认没有总时限。会跑很久的命令（构建、测试、长等待）在脚本首行写 `// @options: {"timeout_ms": <毫秒>}` 给一个合理上限；生图生视频不要设短时限。

# 能力地图（意图 → 工具）

- 文件与命令：read / edit / write / bash / grep / find。读技能的 SKILL.md 也用 `tools.read`。
- 本项目的历史、决策、约定：ctx_search，命中后用 ctx_expand 看原文（ctx_* 仅记忆模块）。个人背景、旧对话、笔记：knowledge_search（选哪个库见 AGENTS.md）。
- 联网：web_search → fetch_content；抓取遇到 403/反爬再试 `mcp__magpie__magpie_web_search__web_fetch`（仅 Magpie 模块）；需要登录态的网站用 ego-search 技能。
- 生图/生视频：`mcp__magpie_image__generate_image` / `generate_video`（仅 Magpie 模块），先 `n: 1` 试一张。
- 浏览器自动化：agent_browser；macOS 桌面界面：find_roots → observe_ui → act_ui。
- 技能：任务命中 `<available_skills>` 里的描述时，先读对应 SKILL.md 再动手；magpie-skills 是另一份技能索引（仅 Magpie 模块）。

# 委派

- 何时委派以 AGENTS.md 开头的全局规则为准。长任务用 `async: true`，完成会自动唤醒你，不要轮询。
- 写多步骤 workflow 之前先读技能 pi-workflow-notes。
