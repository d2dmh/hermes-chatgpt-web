# macOS 与 Windows 的差异（一套流程，两套外壳）

整套协作流程与判据是跨平台的，**agent 逻辑一字不用改**。差异只集中在五件事上：

1. **路径**（家目录、浏览器配置目录、c2c 状态目录）
2. **怎么把带调试端口的浏览器拉起来**
3. **怎么把"一个文件"放进剪贴板**（往网页输入框挂附件用）
4. **怎么让后台服务开机自启 / 定时自愈**
5. **脚本语言**（`bash` ↔ `PowerShell`）

> **诚实标注（2026-10-14 更新）**：下表 macOS 一列全部在本机实测过（含下面的 LaunchAgent 配方）。
> Windows 一列已有一台**真机**回填：按 README 走完安装 → skill 装好可用、`c2c` 构建成功、
> `cloudflared` 装好、**桥与公网连接健康检查通过**；唯一没走通的是"靠 agent 控制浏览器"那一步
> （该机器上启动专用浏览器被策略拒绝、也没有内置浏览器接口）——已用手动路径绕开并写进
> `bridge-setup.md`。所以 Windows 下表里**路径/命令/安装步骤可信**，
> 但"任务计划程序自启、剪贴板挂附件、缩略图替代方案"仍未经真机验证，第一次用到请回填。

## 1. 路径与命令对照

| 用途 | macOS | Windows |
|---|---|---|
| Hermes 家目录 | `~/.hermes` | `%USERPROFILE%\.hermes` |
| Codex 家目录 | `~/.codex`（或 `$CODEX_HOME`） | `%USERPROFILE%\.codex`（或 `%CODEX_HOME%`） |
| c2c 状态目录（别丢） | `~/Library/Application Support/codex-with-chatgpt` | `%LOCALAPPDATA%\codex-with-chatgpt` |
| 专用浏览器配置目录 | `~/.hermes/browser-profiles/hermes-chatgpt` | `%USERPROFILE%\.hermes\browser-profiles\hermes-chatgpt` |
| Chrome 可执行文件 | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` | `%ProgramFiles%\Google\Chrome\Application\chrome.exe` |
| Chrome 下载目录 | `~/Downloads` | `%USERPROFILE%\Downloads` |
| Chrome 下载历史库（SQLite，**被锁着，先复制再查**） | `<profile>/Default/History` | `<profile>\Default\History` |
| 随机串（校验文件用） | `openssl rand -hex 8` | `node -e "console.log(require('crypto').randomBytes(8).toString('hex'))"` |
| 看某个端口被谁占了 | `lsof -nP -iTCP:9222 -sTCP:LISTEN` | `netstat -ano \| findstr :9222` |
| 杀掉进程 | `pkill -f "<模式>"` | `taskkill /F /IM node.exe`（按 PID 更安全：`taskkill /F /PID <pid>`） |
| 打开文件/目录给人看 | `open <path>` | `explorer <path>` 或 `start "" <path>` |
| 缩略图 | `sips -Z 640 <原图> --out <缩略图>` | 用 **Python Pillow**（跨平台，最省事）：`python -c "from PIL import Image; im=Image.open(r'C:\a.png'); im.thumbnail((640,640)); im.save(r'C:\a.small.png')"` |
| 代理环境变量 | `export https_proxy=http://127.0.0.1:7892` | `$env:https_proxy="http://127.0.0.1:7892"` |
| 本地地址免代理 | `export NO_PROXY=127.0.0.1,localhost,::1` | `$env:NO_PROXY="127.0.0.1,localhost,::1"` |

## 2. 拉起带调试端口的专用浏览器

```bash
# macOS
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir="$HOME/.hermes/browser-profiles/hermes-chatgpt" \
  --remote-debugging-port=9222 --no-first-run --no-default-browser-check
```

```powershell
# Windows
& "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" `
  --user-data-dir="$env:USERPROFILE\.hermes\browser-profiles\hermes-chatgpt" `
  --remote-debugging-port=9222 --no-first-run --no-default-browser-check
```

两边都用同一个判定：`curl -s http://127.0.0.1:9222/json/version` 返回 JSON。
**不要**用自动化框架自带方式启动去登录 Google——那类实例 `navigator.webdriver === true`，
Google 会拒绝登录。

## 3. 把一个文件放进剪贴板（挂附件用）

macOS：剪贴板里放**文件引用**（`furl`），粘贴时才触发上传。

```bash
osascript -e 'set the clipboard to (POSIX file "/abs/path/to.png")'
osascript -e 'clipboard info' | head -1     # 期望看到 «class furl»
```

Windows：用 **Windows PowerShell 5.1**（`powershell.exe`，系统自带）的 `Set-Clipboard -Path`——
它放进去的是**文件拖放列表**（和资源管理器里复制文件等价），浏览器粘贴时会当成上传。
注意 **PowerShell 7 去掉了 `-Path`**，所以要走 `powershell.exe` 而不是 `pwsh.exe`：

```powershell
powershell.exe -NoProfile -Command "Set-Clipboard -Path 'C:\abs\path\to.png'"
```

之后两边一样：真实点击输入框，再用 CDP 发**粘贴编辑命令**（不是模拟物理按键）：

```python
for t in ('rawKeyDown', 'keyUp'):
    cdp('Input.dispatchKeyEvent', type=t, modifiers=4, key='v', code='KeyV',
        windowsVirtualKeyCode=86, nativeVirtualKeyCode=9, commands=['paste'],
        target_id=TID)      # target_id 必须带，不带会静默失败
```

校验：附件名会出现在「移除"<文件名>"」这类按钮的 `aria-label` 上。

## 4. 开机自启 + 定时自愈

### macOS：LaunchAgent（本机实测）

`~/Library/LaunchAgents/com.hermes.chrome-cdp-9222.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.hermes.chrome-cdp-9222</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/Google Chrome.app/Contents/MacOS/Google Chrome</string>
    <string>--user-data-dir=__HOME__/.hermes/browser-profiles/hermes-chatgpt</string>
    <string>--remote-debugging-port=9222</string>
    <string>--no-first-run</string>
    <string>--no-default-browser-check</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/hermes-chrome-cdp.log</string>
  <key>StandardErrorPath</key><string>/tmp/hermes-chrome-cdp.err</string>
</dict>
</plist>
```

`~/Library/LaunchAgents/com.hermes.c2c-bridge.plist`（每 30 分钟自愈一次；**正常时 doctor 是 no-op**）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.hermes.c2c-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string><string>node</string>
    <string>__C2C__/bin/c2c.js</string>
    <string>doctor</string><string>-w</string><string>__WORKSPACE__</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>__NODE_BIN_DIR__:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>__HOME__</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>/tmp/hermes-c2c-doctor.log</string>
  <key>StandardErrorPath</key><string>/tmp/hermes-c2c-doctor.err</string>
</dict>
</plist>
```

装载 / 卸载：

```bash
launchctl load  ~/Library/LaunchAgents/com.hermes.c2c-bridge.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.hermes.c2c-bridge.plist   # 卸载
launchctl list | grep hermes                                                       # 看状态
```

**坑**：LaunchAgent 的 `PATH` 是空的，必须显式写；`node` 常装在非标准位置（如 Hermes 自带的
`~/.hermes/tools/node-*/bin`），所以用 `/usr/bin/env node` + 显式 `PATH`。日志路径写 `/tmp` 下的
固定文件，别用 `~`。

### Windows：任务计划程序

```powershell
# 登录时拉起专用浏览器
schtasks /create /tn "hermes-chrome-cdp-9222" /sc onlogon /rl limited ^
  /tr "\"%ProgramFiles%\Google\Chrome\Application\chrome.exe\" --user-data-dir=\"%USERPROFILE%\.hermes\browser-profiles\hermes-chatgpt\" --remote-debugging-port=9222 --no-first-run"

# 每 30 分钟自愈一次（首跑在登录后 1 分钟）
schtasks /create /tn "hermes-c2c-doctor" /sc minute /mo 30 /delay 0001:00 ^
  /tr "node \"%USERPROFILE%\codex-with-chatgpt\bin\c2c.js\" doctor -w \"%USERPROFILE%\your-workspace\""
```

查看 / 删除：`schtasks /query /tn hermes-c2c-doctor /v /fo LIST`、`schtasks /delete /tn <名> /f`。

两条通用注意：**任务要在"用户已登录"的上下文里跑**（要能看到浏览器窗口、能读到用户的登录态）；
环境变量（`HOME` / `PATH` / 代理）在计划任务里默认不继承，必要时在命令里显式带上。

## 5. 写脚本时注意

- 别在脚本里写死 `/tmp`、`/proc`、`~` 之外的绝对路径；用 `mktemp` /
  Python 的 `tempfile.gettempdir()`，Windows 上才有活路。
- 需要跨平台时优先用 **Node 或 Python**（两边都能装），而不是 bash 脚本。
- 换行符：仓库里存 `.sh` 请用 LF（Git 配 `core.autocrlf=input`），`.ps1` 无所谓，
  但 Windows 上 clone 后 `.sh` 变成 CRLF 会导致 `bash: bad interpreter`。
- 路径里的空格一定要引起来：`%ProgramFiles%`、`C:\Users\Zhang San\...` 都会踩到。
