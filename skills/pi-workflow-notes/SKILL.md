---
name: pi-workflow-notes
description: 写 pi-subagents 多步骤 workflow（subagent workflow:true / options.script）前必读：本机踩过的坑与可用的模型 id。
---

# pi-subagents workflow 本机注意事项

1. **脚本怎么传**：`subagent({workflow: true})` 依赖同一条回复里的 ```js 代码块；在部分宿主上代码块到不了会话。稳妥做法是把脚本源码放进 `options: { script: "..." }`，其他字段不变。
2. **脚本里别用模板字符串插值**：`${...}` 写在 JSON 字符串参数里容易触发 `Unexpected token`。拼提示词用数组 `.join('\n')`，子任务输出用 `String(run.output)` 拼接。
3. **角色能力不同**：`explore` 只有读工具，没有 bash，跑不了命令；`analyze` / `review` 有 bash 但不能写文件；`implement` 与 `lead` 才能改文件，`lead` 还能再派子代理（只允许 implement、explore）。需要复跑命令做验收，用 `review`。
   角色名不含模型：档位来自 `subagents.defaultModel`（explore / implement / lead）与 `agentOverrides`（analyze、review），任务需要别的档位时在调用上写 `model:`。
4. **模型 id（本机）**：默认档 `{{PROVIDER}}/{{MODEL}}`；`analyze` = `{{PROVIDER}}/{{MODEL}}`；`review` = `{{PROVIDER}}/{{MODEL}}`。astra 的响应名是 `apibasis/GPT-6-Astra`，需要 `~/.pi/agent/extensions/subagent/config.json` 的 `modelResponseAliases`，改完要重启 Pi 才生效。
5. **并行**：`await Promise.all([runs.run(...), ...])` 只用于互不写同一文件的任务；同一 worktree 只允许一个写者。
6. **子代理问问题**：会以 supervisor request 形式回到主会话，用 `subagent_supervisor({action:"reply", replyTo, message})` 回复；不回复它会一直等。
7. **完成通知**：async 运行结束会自动唤醒主会话，不要 sleep 或轮询；结果文件路径在通知里。
