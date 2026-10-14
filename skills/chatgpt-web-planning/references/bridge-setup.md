# 首次接入：把桥装好，直到网页端能自己读你的文件

> 这份文件是给 **agent 读的**（一个具备终端 + 浏览器能力、能自己执行命令的 agent）。
> 人只需要做两件事：**登录 ChatGPT**、**登录 Cloudflare**（只有用固定域名时）。
> 其余步骤 agent 自己做；一次只向人要一个动作。

装完的标志只有一条：**网页 ChatGPT 在全新对话里，用它自己的连接器读到工作区里一个校验文件，
读回的值与本机文件逐字符一致**。看到"已连接""已授权"都不算。

---

## 0. 前置

| 项 | 要求 | 检查命令 |
|---|---|---|
| Node.js | ≥ 20 | `node --version` |
| pnpm（corepack 自带） | 随 Node | `corepack --version` |
| cloudflared | 任意版本 | `cloudflared --version`（macOS：`brew install cloudflared`；Windows：`winget install Cloudflare.cloudflared`） |
| git | 任意版本 | `git --version` |
| 浏览器 | Chrome / Edge，**能被 CDP 远程调试** | 见第 2 步的判定 |
| 账号 | ChatGPT 登录态（网页端额度充足） | 页面上不是登录墙 |
| 域名（可选） | 想做**固定地址**才需要 | 域名托管在 Cloudflare |

**代理**：若本机靠代理访问境外站点，记得给**本机地址**设 `NO_PROXY=127.0.0.1,localhost,::1`
（否则桥/本地端点的请求会被代理劫走而卡死）。curl / git / pip 通常只认 `https_proxy` 环境变量，
**不认系统代理**——代理开了却没导出环境变量时，git clone 会直接超时。

---

## 1. 装桥（把工作区安全地暴露给网页端）

桥是一个本地 MCP 服务（`c2c`）+ 一条隧道，负责：网页端 → OAuth → 隧道 → 本地只读工作区。

### 方式 A（推荐给人看的一句话）：把下面这段整个丢给你的 agent

```text
请帮我完整安装并配置 Codex with ChatGPT（c2c 桥），全程自动，我不懂技术：

1. 环境自检：需要 git 和 Node.js ≥ 20，缺什么自己装（macOS 用 Homebrew，Windows 用 winget），
   同时装好 cloudflared。
2. 把 https://github.com/XiaoDuoYa/codex-with-chatgpt 克隆到 ~/codex-with-chatgpt
   （已存在就 git pull 更新）。
3. 在该目录执行 corepack pnpm install && corepack pnpm build。
4. 跑 c2c setup -w <我的工程目录> --json，然后按返回的 mcpUrl / pairingCode / connectorName
   在 ChatGPT 网页端创建自定义连接器（认证选 OAuth）并完成配对，全程只用你自己的浏览器标签页。
5. 只有需要我登录（ChatGPT / Cloudflare）、验证码或两步验证时才叫我，一次只告诉我一个动作。
6. 完成后给我看 ✓ 清单，并确认「网页端自己读到工作区文件」的验证通过。
   我不懂 MCP、OAuth、隧道、端口这些词，不要向我解释；出了问题先自己修。
```

### 方式 B（人自己敲，或 agent 照着做）

```bash
git clone https://github.com/XiaoDuoYa/codex-with-chatgpt.git ~/codex-with-chatgpt
cd ~/codex-with-chatgpt
corepack pnpm install && corepack pnpm build
node bin/c2c.js --help            # 能打出帮助 = 装好了
```

Windows 同样可用（Node 20+），把 `~/codex-with-chatgpt` 换成 `%USERPROFILE%\codex-with-chatgpt` 即可。
更细的 Windows 说明（named tunnel 凭据、日志路径）见上游 `docs/troubleshooting.md`。

---

## 2. 起一个专用浏览器实例（登录态归它）

**不要**用自动化框架自带的方式启动浏览器去登录 Google/ChatGPT：那些实例带
`--use-mock-keychain` / `--password-store=basic`，页面里 `navigator.webdriver === true`，
Google 会判"此浏览器或应用可能不安全"。

macOS（原生启动，独立 profile + 调试端口）：

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir="$HOME/.hermes/browser-profiles/hermes-chatgpt" \
  --remote-debugging-port=9222
```

Windows（PowerShell）：

```powershell
& "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" `
  --user-data-dir="$env:USERPROFILE\.hermes\browser-profiles\hermes-chatgpt" `
  --remote-debugging-port=9222
```

**判定（机器可判定，别用"看起来打开了"）**：

```bash
curl -s http://127.0.0.1:9222/json/version     # 期望返回 JSON 且含 "Browser": "Chrome/…
```

再让 agent 连一次并检查页面里 `navigator.webdriver === false`。这个实例是**用户可见的窗口**，
**不要**用它做别的事；用户点击/切标签会把 agent 的"当前页"带偏，动手前先切到自己的标签。

Hermes 侧配置（让 `browser_exec` 指向这个实例）：

```yaml
# ~/.hermes/config.yaml
browser:
  use_real_profile: false
  headed: true
  cdp_url: http://127.0.0.1:9222
  allow_private_urls: true      # 本机 DNS 对 chatgpt.com 被污染时会误拦
security:
  allow_private_urls: true
```

Hermes 的环境变量文件（默认在 `~/.hermes/` 内，文件名由 `$HERMES_HOME` 决定）：

```bash
AGENT_BROWSER_PROFILE=<你的 home 目录>/.hermes/browser-profiles/hermes-chatgpt
```

Codex 宿主用内置浏览器（`iab`），不需要这一节；照 c2c 检出目录里的 `skill/SKILL.md` 走。

---

## 3. 生成桥 + 在 ChatGPT 里建连接器

```bash
node <c2c检出目录>/bin/c2c.js tunnel status -w <workspace> --json   # 看要不要选地址模式
node <c2c检出目录>/bin/c2c.js setup -w <workspace> --json
# → { mcpUrl, pairingCode, workspaceName, connectorName, ... }
```

地址模式两种（**第一次问一次，之后记住**）：

- 没有域名 / 不想折腾 → `c2c tunnel choose -w <ws> --mode quick --json`（**重启后地址会变**）
- 域名托管在 Cloudflare → `c2c tunnel choose -w <ws> --mode named --zone <你的域名> --json`
  （这一步会打开用户自己的浏览器去登录 Cloudflare，是唯一允许离开内置/协作浏览器的例外）

在 ChatGPT 里建连接器（**用页面 URL，不要点菜单找**）：

| 做什么 | URL |
|---|---|
| 打开开发人员模式（建连接器要求时） | `https://chatgpt.com/#settings/Security` |
| 管理已有连接器（只用来**删除**） | `https://chatgpt.com/plugins` |
| 新建连接器 | `https://chatgpt.com/plugins#settings/Connectors?create-connector=true&redirectAfter=%2Fplugins` |

连接器三个字段：**名称** = `connectorName`（一个工作区只有一个连接器，别改别的地方的）；
**描述** 随便写清用途；**Server URL** = `mcpUrl`；**认证** = OAuth。

**配对（最容易翻车的一步）**：

1. 先在页面上点到授权/配对输入框那一屏；
2. 再跑 `c2c pair -w <ws> --json` 取**一次性配对码**（约 5 分钟过期，过期就再取一次）；
3. **真实点击**输入框 + **逐字符真键**输入配对码 + **真实点击** Connect。
   —— 授权页**只能提交一次**：用 JS 直接写 `input.value` 会把这个一次性请求消耗掉却不带配对码，
   同页重试只会看到 `authorization request has expired`。真发生了就**删掉连接器重建**。

**连接器地址只有两种合法操作**：新建（首次）与**删除后重建**（地址变了）。
"重新连接 / Reconnect / 刷新"在旧地址已死时只会卡在"无法访问"。

---

## 4. 验证（不可跳过）

1. 在工作区里放一个校验文件，内容带一段随机串：

   ```bash
   printf 'Verification: %s\n' "$(openssl rand -hex 8)" > <workspace>/c2c-hello.txt
   cat <workspace>/c2c-hello.txt
   ```

2. 在**全新对话**里发（`<connectorName>` 换成实际名字）：

   ```text
   用「<connectorName>」这个连接器：先调用 workspace_info，再读工作区根目录下的 c2c-hello.txt，
   把 workspace 名字和文件里的 Verification 值原样回给我。
   ```

3. 比对：返回的 workspace 名 = `workspaceName`；Verification 值与本机 `cat` 出来的**逐字符一致**。
   **不接受**把文件内容粘贴进聊天冒充读取。

4. 把这次验证通过的对话 URL 记进状态文件（下一个 agent 从这里接着干）。

日常自检：

```bash
node <c2c检出目录>/bin/c2c.js doctor -w <workspace> --json     # 期望 repairs: []、chatgptRepair.needed: false
```

---

## 5. 可选：固定地址 + 开机自启（做一次，之后基本不用管）

- **固定地址**：`c2c tunnel choose --mode named`（见第 3 步）。之后重启只跑 `doctor`（`namedRepair`），
  **不用删连接器**——地址没变。没域名就只能留在 quick：重启机器 = 删连接器重建 + 重新配对。
- **自启动**：macOS 用 LaunchAgent（`~/Library/LaunchAgents/*.plist`），Windows 用任务计划程序
  （登录时触发 + 每 30 分钟一次）。跑的命令都是 `c2c doctor -w <workspace>`——**正常时它是 no-op**，
  不会造成地址漂移，所以可以定时跑当自愈。详见 `cross-platform.md`。

---

## 6. 收尾：写状态文件（交给下一个 agent）

写到 `${HERMES_HOME:-$HOME/.hermes}/handoffs/chatgpt-web-state.md`
（Windows `%USERPROFILE%\.hermes\handoffs\chatgpt-web-state.md`），至少包含：

- 绑定关系：工作区路径、`workspaceName`、连接器名、隧道模式与地址、Hermes 专用对话 URL
- 接入方式：浏览器 profile 目录 + 调试端口 + 启动命令；Hermes/Codex 侧的配置改动
- 验证结论：`doctor` 输出要点 + 校验文件读到的那一行
- 坑与处置：本次实际踩到的（现象 → 原因 → 怎么办）
