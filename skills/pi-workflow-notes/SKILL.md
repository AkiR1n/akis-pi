---
name: pi-workflow-notes
description: 写 pi-subagents 多步骤 workflow（subagent workflow:true / options.script）前必读：本机踩过的坑与可用的模型 id。
---

# pi-subagents workflow 本机注意事项

1. **脚本怎么传**：`subagent({workflow: true})` 依赖同一条回复里的 ```js 代码块；在部分宿主上代码块到不了会话。稳妥做法是把脚本源码放进 `options: { script: "..." }`，其他字段不变。
2. **脚本里别用模板字符串插值**：`${...}` 写在 JSON 字符串参数里容易触发 `Unexpected token`。拼提示词用数组 `.join('\n')`，子任务输出用 `String(run.output)` 拼接。
3. **角色能力不同**：`planner` 只有 read/grep/find/ls，跑不了命令、不能写文件；要执行或修改用 `impl-flash`（普通）或 `impl-sol`（架构/后端关键）。验收者若需要复跑命令，让主会话来跑。
4. **模型 id**：执行 `{{PROVIDER}}/{{MODEL_EXEC}}`；复核 `{{PROVIDER}}/{{MODEL_REVIEW}}`；规划/验收 `{{PROVIDER}}/{{MODEL_PLAN}}`。
   这三个是**角色**，不是某个具体模型：换成你 `models.json` 里对应的三个模型 id。用便宜模型跑执行、用另一种模型复核、用更强的模型做规划，是整个委派体系的前提。
   若供应商返回的响应名与请求 id 不同，需要在 subagent 的 `config.json` 里配 `modelResponseAliases`，改完要重启 Pi 才生效。
5. **并行**：`await Promise.all([runs.run(...), ...])` 只用于互不写同一文件的任务；同一 worktree 只允许一个写者。
6. **子代理问问题**：会以 supervisor request 形式回到主会话，用 `subagent_supervisor({action:"reply", replyTo, message})` 回复；不回复它会一直等。
7. **完成通知**：async 运行结束会自动唤醒主会话，不要 sleep 或轮询；结果文件路径在通知里。
