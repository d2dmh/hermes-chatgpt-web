# hermes-chatgpt-web

> 让你的本机 agent 把**网页版 ChatGPT** 当"大脑"用：它出方案、做独立审查、出图出视频；
> 本机 agent 负责动手执行、取回产物、逐条核验。你已经在付的钱，别再闲置。

[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)](#一句话部署)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Skill](https://img.shields.io/badge/agent%20skill-chatgpt--web--planning-blue)](#仓库里有什么)

---

## 一句话部署

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/d2dmh/hermes-chatgpt-web/main/install.sh | bash
```

**Windows**（PowerShell）

```powershell
irm https://raw.githubusercontent.com/d2dmh/hermes-chatgpt-web/main/install.ps1 | iex
```

**不想碰终端**：把下面这一行原样发给你的 agent（Hermes 或 Codex 都行）——

```text
帮我装 https://github.com/d2dmh/hermes-chatgpt-web ：读它的 README，按里面的说明把 skill 装进我的 agent，
按 skill 里的 references/bridge-setup.md 把桥（c2c）装好并完成首次接入，全程你自己做，
只有需要我登录 ChatGPT / Cloudflare 时才叫我，一次只给我一个动作。
```

装完你就多了一句口令：**「让 GPT 看一下」「先让 GPT 出个方案」「让 GPT 审一下」「让 GPT 画张图」。**
（装的过程会 clone 两个仓库、装 cloudflared、构建一次；大约 3–5 分钟。**不改动你已有的 skill**，
同名会先自动备份。）

---

## 为什么会有这个仓库

先说清楚它解决的是什么问题，否则你只会看到一堆命令。

**我们这边的工作方式是：agent 干活，但方案不该由 agent 拍脑袋定。** 实测过一次很典型的翻车：
让 agent 做一份技术分享用的 PPT，它自己估字号、自己翻模板库、自己从头手搓版式——
交了五轮，全被否。换一条路立刻就好了：**把材料给网页端 ChatGPT，只要它给一份"可实现的方案"，
agent 照着做**。它一次就把"先核对数据 → 按研究背景/框架/结果/局限组织"规划好了，
还自己发现"五页拼版不符合一页一张完整图"。

问题在于把材料交给它这件事本身很痛：以前只能把文件内容、日志、代码**复制粘贴**进聊天框，
又慢又容易失真，还常常把上下文撑爆。

**这个仓库就是那件事的成品化**：用一条只读的 MCP 连接（`c2c` 桥）把你**当前工程目录**
暴露给网页端 ChatGPT，它自己按需读文件——**没有人需要粘贴任何代码、diff 或日志**。
登录态、隧道、配对码这些麻烦事，第一次由 agent 带着你做完（你只需要在浏览器里点两下登录），
之后随开机自启，跟重启机器无关。

一句实话：**这套东西的价值不在"能连上"，而在"知道什么时候会栽"。**
所以仓库里除了安装脚本，主要篇幅是流程、判据和坑表——那些是几十轮真实使用换来的。

---

## 它是怎么工作的

### 名词表（每个都用上了，都不难）

| 名词 | 是什么 | 在这里干什么 |
|---|---|---|
| **Hermes / Codex** | 你本机的编码/自动化 agent（能开终端、能点浏览器） | 负责执行：改文件、跑测试、取回产物 |
| **skill** | 一份 Markdown 操作手册（`SKILL.md` + 参考文件 + 脚本），agent 开工前读它 | 把"老师傅的手艺"固化下来：流程、判据、坑 |
| **MCP** | 模型与工具之间的标准接口 | 让网页端 ChatGPT 能调用你本机的工作区读取工具 |
| **c2c 桥** | 一个第三方开源小工具（[codex-with-chatgpt](https://github.com/XiaoDuoYa/codex-with-chatgpt)，MIT） | 在本机起一个**只读** MCP 服务，并把它通过隧道暴露成一个网址 |
| **隧道（cloudflared）** | 把本机端口映射到一个公网网址 | 让网页端 ChatGPT 能访问到你本机的桥，不用公网 IP |
| **OAuth / 配对码** | 一次性的授权流程 | 只有你把配对码填进 ChatGPT 的授权页，它才能读你的工作区 |
| **连接器（自定义 MCP 服务器）** | ChatGPT 侧的一个"插件"配置项 | 指向那个网址；一个工作区一个连接器 |
| **CDP** | Chrome 调试协议（浏览器自动化接口） | agent 用它**真的去点页面**：开新对话、打字、点发送 |
| **专用浏览器实例** | 一个独立 profile、带调试端口的 Chrome | 登录态归它；agent 在里面操作，不影响你平时用的浏览器 |

### 一次真实调用的完整时序

```
你说：「让 GPT 看一下这版方案，然后按它的意见改」
  │
  ├─ 1. 本机 agent 跑 c2c doctor        → 桥/隧道/连接器都正常？（不绿就先修，不发消息）
  ├─ 2. 找到协作浏览器里**自己的**标签  → 在网页端开一个**全新对话**（一个任务一个对话）
  ├─ 3. 发一条短任务说明（约 1 KB）      → 目标 / 范围 / 限制 / 成功标准；不粘贴任何文件内容
  │      └─ 网页 ChatGPT 用它自己的连接器读工作区：workspace_info → read_file → git_diff …
  ├─ 4. 它回一份可实现的方案（PLAN）
  ├─ 5. agent 在本机执行：改文件、跑测试，并把执行摘要用 c2c record 写进工作区
  ├─ 6. agent 发 EXECUTED               → 「请你自己读 diff 和测试输出，给独立审查意见」
  ├─ 7. 它回审查意见（可能指出真缺陷）    → agent 改，再回第 5 步；直到通过
  └─ 8. 通过后 agent 才向你汇报，并核验产物（图片走 sha256 + C2PA 验真）
```

关键分工（这套东西的地基）：**网页大模型出主意和挑毛病，本机 agent 动手且负责核验。**
所以 skill 里写死了两条规矩：**只传背景与需求，不要替它下限定**（版式/字号/字数这类规格是它的专业范围），
以及**发任务时就要求它以"独立审查专家"身份自审一遍**（实测它会自己驳回 3 批引入虚构组件的架构图）。

---

## 装完之后：第一次怎么用

1. 装之前先确认你的 agent 里至少有 **Hermes** 或 **Codex** 一个（教程见仓库顶部那句"丢给 agent"）。
2. 跑安装脚本（或把那句话丢给 agent）。
3. **只有两步需要你亲自做**：在浏览器里登录 ChatGPT；如果你要用固定域名，再登录一次 Cloudflare。
4. agent 会给你看一张 ✓ 清单，并让网页端**自己读**一个校验文件来验证——读回的值要和本地逐字符一致。
5. 然后就正常干活：`让 GPT 出个方案` / `让 GPT 审一下` / `让 GPT 画张图`。
6. 想一劳永逸（重启机器也不用重新配对）：给桥配个**固定域名**（`c2c tunnel choose --mode named`），
   详见 `skills/chatgpt-web-planning/references/bridge-setup.md`。

---

## 仓库里有什么

```
hermes-chatgpt-web/
├── install.sh / install.ps1          一句话部署的两半（macOS/Linux · Windows）
├── skills/chatgpt-web-planning/      技能本体（Hermes 与 Codex 通用同一个目录）
│   ├── SKILL.md                      流程、判据、口令触发、坑表
│   ├── references/
│   │   ├── bridge-setup.md           首次接入：装桥 → 建连接器 → 配对 → 验证（给 agent 读）
│   │   ├── cross-platform.md         macOS / Windows 差异对照 + 开机自启配方
│   │   ├── browser-pitfalls.md       浏览器操作坑：输入法、坐标、多标签、发送判据
│   │   ├── media-export.md           取回它生成的图/视频/PDF 并验真（C2PA）
│   │   └── uploading-files-to-web-chatgpt.md   把文件挂进输入框（含 Windows 做法）
│   ├── scripts/verify_asset_origin.py  验真：字节数 / sha256 / 容器结构 / 出处签名
│   └── templates/agent-runbook.md    给"别人的 agent"看的复现说明骨架
└── docs/                             原理与实测记录（人读的）
```

---

## 路上的坑（精选，完整的在 skill 里）

| 现象 | 为什么 | 怎么办 |
|---|---|---|
| 网页端调用报 401，但本地自检说一切正常 | 本地自检比较的是自己记录的地址，会漂移；ChatGPT 上的连接器其实还指着**已死的旧地址** | 别信自检结论，用一次真实的 `workspace_info` 验证；不行就**删掉连接器重建**（"重新连接"对死地址无效） |
| 授权页显示 `authorization request has expired`，重试也没用 | OAuth 授权请求**只能提交一次**，用脚本直接写输入框的值会把它消耗掉却不带配对码 | 必须真实点击输入框 + 逐字符真键输入配对码 + 真实点击 Connect；过期就重新生成配对码 |
| 重启机器后每次都要重新配对 | 默认的**临时隧道地址**每次重启都变，连接器就跟丢了 | 配固定域名（named tunnel）；或者接受"重启 → 删连接器重建" |
| 自动化启动的浏览器登录 Google 被拒："此浏览器或应用可能不安全" | 自动化实例带 `navigator.webdriver = true` 指纹 | 用**原生**启动的 Chrome（独立 profile + 调试端口）承载登录态 |
| 给输入框打字"成功了"但发送按钮不出现 | 页面里历史消息的提示词块也是可编辑区域，脚本把字打进了旧块 | 输入框必须用 `form div[contenteditable="true"]` 精确定位，并用**逐字符真键事件**输入 |
| 点了下载按钮，下载目录里没有新文件 | 那个控件走系统保存对话框，自动化环境不落盘 | 改从页面里直接取原文件字节（与页面上的图逐字节相同），落盘后跑 `verify_asset_origin.py` |
| 它生成的图看着像"模型的产出"，其实是截图 | 截图也是 PNG，肉眼看不出 | 验真看三样：与页面字节数一致、PNG 容器结构、**C2PA 出处签名**（`OpenAI OpCo` / `gpt-image`），截图不会带 |
| 一个对话聊久了它开始变糊 | 上下文太长（原话："上下文太长会降智"） | 一个任务一个对话；同任务的复审留在同一对话 |
| 挂着代理，本地端点请求卡死 | 系统代理把 `127.0.0.1` 的请求也劫走了 | 设 `NO_PROXY=127.0.0.1,localhost,::1`；注意 `curl/git/pip` 只认 `https_proxy` 环境变量，不认系统代理 |

---

## 常见问题

**要花 API 的钱吗？** 不要。走的是你**已经付费的网页版 ChatGPT**，没有 API key，没有逆向代理。

**我的代码会被上传吗？** 不会。连接器是**只读**的：ChatGPT 按需读你工作区里它要的那几个文件；
skill 里明令禁止把文件内容粘贴进聊天、禁止把仓库加进 Project 的 sources。

**团队里有人只有 Windows？** 支持。一份流程、两套外壳（安装脚本 + 差异对照表）。诚实说明：
macOS 那一列是本机实测过的，Windows 那一列按官方文档与 PowerShell 语义写的、**没在真机跑过**——
第一次装完把实际结果回填到 `cross-platform.md` 里，这份文档才算完整。

**安装时被 Hermes 的安全扫描拦了（被判 DANGEROUS）？** 这是**内容型误报**，安装脚本已经带 `--force` 处理。
原因：这套文档逐字记录了 launchd/任务计划程序自启、`pnpm install`、base64 分块读字节这些命令，
扫描器按关键词把它们当成"持久化 / 供应链 / 混淆"风险。本仓库里除了
`scripts/verify_asset_origin.py`（只读一个 PNG 的字节，打印哈希与 C2PA 标识）**没有任何可执行代码**，
你可以在 GitHub 上逐行核对；想更保守就只装 Codex 那一份（纯本地拷贝，不过扫描器）。

**换机器 / 换工作区会怎样？** 换工作区 = 新连接器（一个工作区一个）；换机器要重做一次首次接入。
绑定关系都写在 `~/.hermes/handoffs/chatgpt-web-state.md`（Windows：`%USERPROFILE%\.hermes\handoffs\`），
下一个 agent 读它就能接着干。

**更新怎么弄？** 重跑安装脚本即可（它会 `git pull` 并重装 skill）；
Hermes 侧也可以直接 `hermes skills update`。

---

## 致谢与许可

- 桥（`c2c` / codex-with-chatgpt）是 [@XiaoDuoYa](https://github.com/XiaoDuoYa) 的开源项目（MIT）——
  本仓库只**调用**它，不包含它的源码；安装脚本会把它 clone 到你本机。
  **注意**：桥的 skill 与文档是给 **Codex** 宿主写的；本仓库的 skill 是同一套能力在
  **Hermes** 宿主上的实现，并补了跨平台与判据。
- 本仓库内容以 MIT 许可发布，见 [LICENSE](LICENSE)。
- 文中的实测数字（速度、字节数、几轮通过）都来自一台 Apple M5 / 16GB / macOS 的笔记本，
  配合中国网络环境（家用宽带 + 本地代理）。你的机器上不会完全一样，**但判据是一样的**。
