# 部署这套配置的规则（给 AI）

你在把 `akis-pi` 部署到用户自己的机器上。用户把这套配置交给你，是因为它省过很多 token、也踩过很多坑；
**你不是来重新设计的，你是来把它装对、并证明装对了。** 下面的规则优先于你的偏好。

## 0. 先做的三件事

1. 读完 `DEPLOY.md` 全文，再动手。分步顺序不是建议。
2. 读 `manifest.json`，知道每个组件的级别：`pinned` 不要换版本，`pinned-reason` 升级前先看理由，`float-ok` 可以随意。
3. 问用户三件事（一次问完，不要逐个挤牙膏）：
   - 用哪个供应商（`{{PROVIDER}}`）、哪几个模型 id 对应 `{{MODEL}}` / `{{MODEL_EXEC}}` / `{{MODEL_REVIEW}}` / `{{MODEL_PLAN}}`；
   - 要装哪些模块（core 必装；memory / macos / magpie 由他决定）；
   - 搜索密钥怎么给：走环境变量（`!printenv VAR`）还是系统钥匙串（`!security find-generic-password ...`）。

## 1. 不覆盖已有配置

- 渲染前一律先 dry run：`node scripts/render.mjs --home "$HOME" --modules ...`（不带 `--apply`）。把会写的文件、遇到的 diff、以及**未解析的占位符**念给用户看。
- 已有 `settings.json` / `AGENTS.md` / `APPEND_SYSTEM.md` 的目标文件，必须在用户确认后才覆盖；`render.mjs` 会自己备份到 `<agent-dir>/backups/akis-pi-<时间戳>/`，但这不构成「可以不问」。
- `mcp.json`、`RESIDENT.md`、`models.json`、`auth.json` **永远不要替换**。前两个按说明合并或留给用户；后两个由 Pi 与登录流程自己维护。
- 不删任何别人的文件。要停用而不是删除时，用 Pi settings 的 `-path` 排除写法，而不是 `rm`。

## 2. 密钥只问用户，不猜

- 不生成、不伪造、不「先填个占位符跑跑看」任何 key。
- 不要把 key 写进仓库、不要写进 `settings.json`、不要 echo 到会话里。合法的写法只有两种：引用环境变量（`!printenv VAR`）或引用系统钥匙串（`!security find-generic-password -a "$USER" -s <服务名> -w`）。
- 用户把 key 贴进对话时，提醒他这是明文，并建议放到钥匙串后重新用引用写法。
- 任何一步需要 `sudo`、破坏性 git 操作、或联网安装，都要先说明再执行。

## 3. 一步一验

每完成一个 DEPLOY.md 的步骤，就执行它写的**检查命令**，把真实输出贴给用户，再继续。没跑检查就等于没做这一步。

- 「装了」的判据是命令输出，不是文件存在；「生效」的判据是新开一个 Pi 会话的行为，不是 `/reload` 的返回。
- 全部装完后必须跑 `node scripts/doctor.mjs --home "$HOME" --modules ...` 并贴完整输出。WARN 要逐条解释，FAIL 必须修完才算交付。
- 不要把宿主机的构建、静态阅读、别人的成功记录说成「已验证」。没有输出就是没有证据。

## 4. 失败就停下报告

出现下列任一情况，**停止**，不要绕：

- `doctor.mjs` 出现 FAIL；
- 渲染后仍有 `{{PLACEHOLDER}}` 没填；
- 插件版本与 `manifest.json` 的 `pinned` 不符；
- `pi` 启动报错、模型列表为空、工具数为 0；
- 需要替换某个 pinned 组件才能继续（那是用户决策，不是你的）。

报告格式：**哪一步 / 期望什么 / 实际什么 / 原始输出 / 你打算怎么办 / 需要用户决定什么**。然后等回复。

## 5. 记忆与个人信息

- `~/.pi/agent/memory/` 下的文件（尤其 `RESIDENT.md`）属于用户，只读；除非用户明确要求，否则不创建、不改写。
- 不把用户的会话内容、笔记、知识库数据写进这个仓库或任何提交里。
- 本仓库的模板里只有`引用`（`{{BRAVE_KEY_REF}}` 之类），没有值。保持这样。

## 6. 交付时说什么

- 装了什么模块、装了哪些版本；
- `doctor.mjs` 的输出摘要（PASS/WARN/FAIL 计数 + 每条 WARN 的解释）；
- 还有哪些步骤需要用户自己做（登录、写 RESIDENT、装第三方 app）；
- 哪些地方与 `manifest.json` 不同，以及为什么。
