# pdf 模块

本地 PDF → Markdown 服务的唯一源码是本目录的 server.py 和 requirements.txt。使用 PyMuPDF 1.28.2，默认监听 127.0.0.1:8791；无文本层的扫描件返回 422，让 pi-web-access 回退到 OCR。本包只有 darwin-arm64 的服务实测记录；Linux、WSL2 与原生 Windows 的服务启动属试验，尚未实机验收。

从仓库根目录先 dry run：

~~~sh
node scripts/render.mjs --home "$HOME" --modules pdf --strict
# 审阅后追加 --apply。此模块不依赖 macos，也不会安装 Python 依赖或启动服务。
~~~

文件统一落在 <home>/.local/share/pi-pdf-parse。web-search.json 的 pdf.endpointUrl 由 core 提供；调整端口时同步 PI_PDF_PARSE_PORT 和该 URL。

## macOS：launchd

~~~sh
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/com.example.pipdfparse.plist"
curl --noproxy '*' http://127.0.0.1:8791/health
~~~

期望 {"ok":true}。停用用 launchctl bootout。plist 使用渲染后的绝对路径；移动 HOME 时需审阅并重新配置，launchd 不展开 ~。

## Linux / WSL：systemd --user

~~~sh
python3 -m venv "$HOME/.local/share/pi-pdf-parse/venv"
"$HOME/.local/share/pi-pdf-parse/venv/bin/pip" install -r "$HOME/.local/share/pi-pdf-parse/requirements.txt"
systemctl --user daemon-reload
systemctl --user enable --now pi-pdf-parse.service
curl --noproxy '*' http://127.0.0.1:8791/health
journalctl --user -u pi-pdf-parse.service
~~~

Ubuntu 可能需要先安装 python3-venv。unit 渲染至 XDG_CONFIG_HOME/systemd/user（未设置时为 HOME/.config/systemd/user），路径中的空格、百分号和美元符号由渲染器转义。WSL 需已启用 systemd；无用户会话时自行选择手动运行或按系统策略配置 linger。停用用 systemctl --user disable --now pi-pdf-parse.service。

## 原生 Windows：试验，登录计划任务

PowerShell 中从仓库根目录运行（$HOME 是当前用户配置文件目录）：

~~~powershell
node scripts/render.mjs --home $HOME --modules pdf --strict
# 审阅后追加 --apply
$pdfDir = Join-Path $HOME '.local\share\pi-pdf-parse'
py -3 -m venv (Join-Path $pdfDir 'venv')
$python = Join-Path $pdfDir 'venv\Scripts\python.exe'
& $python -m pip install -r (Join-Path $pdfDir 'requirements.txt')
$server = Join-Path $pdfDir 'server.py'
# 先在当前终端验证服务；另一个终端检查 /health，再按 Ctrl-C 停止
& $python -I -B -u $server
Invoke-RestMethod http://127.0.0.1:8791/health
~~~

手动服务验证通过后，在「任务计划程序」为当前用户创建登录触发的任务：程序填上述 python.exe 的完整路径，参数填 -I -B -u "<完整 server.py 路径>"，起始目录填 pdfDir，选择「仅当用户登录时运行」。设置失败时重启，并核对电源条件不会阻止任务。不要将密码写入脚本。手动运行任务，检查 /health、文本 PDF、扫描件 422、退出与再次登录后的恢复，才算完成任务验收。doctor 仅检查源码文件，不能证明任务正在运行。

## 旧状态迁移

v1 渲染状态中的 macos 曾包含 PDF。新渲染器把这一历史归属记录为 pdf，保留原来的目标路径、用户修改与服务配置，绝不删除或重新覆盖；不再生成第二份服务。v2 的新 macos 安装只写两个扩展，PDF 需显式选 pdf。现有模板升级仍应在独立目录生成后审阅合并。
