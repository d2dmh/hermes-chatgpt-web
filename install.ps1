<#
  hermes-chatgpt-web · Windows 安装器

    一句话装（PowerShell）：
      irm https://raw.githubusercontent.com/d2dmh/hermes-chatgpt-web/main/install.ps1 | iex

  干什么：① 把 skill 装进你已有的 agent（Hermes 走 skills tap，Codex 走 skills 目录）
          ② 把「只读 MCP 桥」（c2c）clone + 构建好 ③ 打印下一步（就剩登录 ChatGPT 了）
  不干什么：不替你登录、不碰你已有的 skill（同名会先备份）、不索取任何凭据。

  用法（想传参数就别用 irm，直接下载后跑）：
    .\install.ps1 -Workspace "$env:USERPROFILE\codex"
    .\install.ps1 -SkillsOnly        # 只装 skill，不动桥
    .\install.ps1 -NoHermes -NoCodex # 只装桥
    .\install.ps1 -DryRun            # 只打印将要执行的动作
#>
[CmdletBinding()]
param(
  [string]$Workspace = "",
  [string]$Owner = "d2dmh",
  [string]$Repo  = "hermes-chatgpt-web",
  [string]$RepoDir = "",
  [string]$C2cDir = "",
  [string]$CodexHome = "",
  [switch]$SkillsOnly,
  [switch]$NoHermes,
  [switch]$NoCodex,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$SkillName = "chatgpt-web-planning"
$RepoUrl   = "https://github.com/$Owner/$Repo.git"
$BridgeUrl = "https://github.com/XiaoDuoYa/codex-with-chatgpt.git"
$RepoDir   = if ($RepoDir) { $RepoDir } else { Join-Path $HOME $Repo }
$C2cDir    = if ($C2cDir)  { $C2cDir }  else { Join-Path $HOME "codex-with-chatgpt" }
$CodexHome = if ($CodexHome) { $CodexHome } else { Join-Path $HOME ".codex" }
$DoBridge  = -not $SkillsOnly

function Say  { param($m) Write-Host $m }
function Step { param($m) Write-Host "`n==> $m" -ForegroundColor DarkGray }
function Ok   { param($m) Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "  [x]  $m" -ForegroundColor Red; exit 1 }
function Run  { param([Parameter(ValueFromRemainingArguments=$true)]$Args)
  if ($DryRun) { Say "  [dry-run] $($Args -join ' ')" } else { & $Args[0] @($Args[1..($Args.Count-1)]) } }
function Have { param($cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Say "hermes-chatgpt-web · 安装器（Windows / PowerShell）"
Say "让网页版 ChatGPT 当你的规划与审查大脑；本机 agent 负责执行。"
Say "本脚本只装依赖与 skill，不登录、不索取凭据。"

# ---------------------------------------------------------------- 0. 体检
Step "0/4 环境体检"
if (-not (Have git)) {
  Warn "缺 git，尝试用 winget 安装…"
  if (Have winget) { Run winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements }
  if (-not (Have git)) { Fail "请先装 git（winget install Git.Git）后重跑" }
}
Ok "git 就绪"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  $major = [int](& node -p 'process.versions.node.split(".")[0]')
  if ($major -lt 20) { Warn "Node $(& node -v) 太旧（桥需要 >= 20）"; $DoBridge = $false } else { Ok "node $(& node -v)" }
} else {
  Warn "没装 Node.js（桥需要 >= 20）"
  if (Have winget) { Warn "装它：winget install OpenJS.NodeJS.LTS" }
  $DoBridge = $false
}
if (-not $DoBridge) { Warn "跳过桥的安装；装好 Node >= 20 后重跑本脚本即可" }

if (-not $Workspace) {
  $candidate = Join-Path $HOME "codex"
  $Workspace = if (Test-Path $candidate) { $candidate } else { (Get-Location).Path }
}
if (-not (Test-Path $Workspace)) { Fail "工作目录不存在：$Workspace" }
Ok "工作目录：$Workspace"

function Backup-IfDiffers {
  param([string]$Dst)
  if (-not (Test-Path $Dst)) { return }
  $same = $false
  $srcSkill = Join-Path $RepoDir "skills\$SkillName\SKILL.md"
  $dstSkill = Join-Path $Dst "SKILL.md"
  if ((Test-Path $dstSkill) -and (Test-Path $srcSkill)) {
    $same = (Get-FileHash $dstSkill).Hash -eq (Get-FileHash $srcSkill).Hash
  }
  if ($same) { return }
  $bak = "$Dst.bak-$(Get-Date -Format yyyyMMddHHmmss)"
  Warn "已存在的 $SkillName 与本次安装的不同，先备份到：$bak"
  Run Move-Item -Path $Dst -Destination $bak
}

# ---------------------------------------------------------------- 1. skill
Step "1/4 取回 skill 源码"
if (Test-Path (Join-Path $RepoDir ".git")) {
  Run git -C $RepoDir pull --ff-only
} else {
  Run git clone --depth 1 $RepoUrl $RepoDir
}
if (-not $DryRun -and -not (Test-Path (Join-Path $RepoDir "skills\$SkillName\SKILL.md"))) {
  Fail "克隆里没找到 skills\$SkillName\SKILL.md"
}

if (-not $NoHermes) {
  if (Have hermes) {
    Step "1a 装进 Hermes（走 skills tap，之后 hermes skills update 就能更新）"
    Say "  说明：Hermes 的安全扫描会把这个 skill 判为 DANGEROUS —— 它按关键词命中了本套文档里"
    Say "  逐字记录的 launchd 自启、pnpm 安装、base64 分块读取等命令，属于内容型误报（本 skill 全是"
    Say "  Markdown + 一个只读的 PNG 校验脚本，可在 GitHub 上逐行核对）。所以这里带 --force 安装。"
    if ($DryRun) {
      Say "  [dry-run] hermes skills tap add $Owner/$Repo"
      Say "  [dry-run] hermes skills install $Owner/$Repo/skills/$SkillName -y --force --category autonomous-ai-agents"
    } else {
      try { hermes skills tap add "$Owner/$Repo" | Out-Null } catch { }
      $out = & hermes skills install "$Owner/$Repo/skills/$SkillName" -y --force --category autonomous-ai-agents 2>&1
      if ($LASTEXITCODE -eq 0) { Ok "Hermes skill 已安装（来源：$Owner/$Repo）" }
      else {
        Warn "经 skills tap 安装失败，改用本地拷贝"
        $dst = Join-Path $HOME ".hermes\skills\autonomous-ai-agents\$SkillName"
        Run New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Backup-IfDiffers -Dst $dst
        if ((Test-Path $dst) -and -not $DryRun) { Remove-Item -Recurse -Force $dst }
        Run Copy-Item -Recurse -Force (Join-Path $RepoDir "skills\$SkillName") $dst
        Ok "Hermes skill -> $dst"
      }
    }
  } else {
    Warn "没找到 hermes 命令（要装 Hermes 见 https://hermes-agent.nousresearch.com/docs ）"
  }
}

if (-not $NoCodex) {
  if (Test-Path $CodexHome) {
    Step "1b 装进 Codex（$CodexHome\skills）"
    $dst = Join-Path $CodexHome "skills\$SkillName"
    Run New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Backup-IfDiffers -Dst $dst
    if ((Test-Path $dst) -and -not $DryRun) { Remove-Item -Recurse -Force $dst }
    Run Copy-Item -Recurse -Force (Join-Path $RepoDir "skills\$SkillName") $dst
    Ok "Codex skill -> $dst"
  } else {
    Warn "没找到 $CodexHome，跳过 Codex 侧（要用 Codex 就先装它，或加 -CodexHome 后重跑）"
  }
}

# ---------------------------------------------------------------- 2. 桥
if ($DoBridge) {
  Step "2/4 装桥（只读 MCP 服务 + 隧道）"
  if (-not (Have cloudflared)) {
    if (Have winget) { Run winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements }
    else { Warn "缺 cloudflared 且没有 winget：请自行安装后重跑" }
  } else { Ok "cloudflared 已就绪" }

  if (Test-Path (Join-Path $C2cDir ".git")) { Run git -C $C2cDir pull --ff-only }
  else { Run git clone $BridgeUrl $C2cDir }

  if (-not $DryRun) {
    Push-Location $C2cDir
    try {
      & corepack pnpm install; if ($LASTEXITCODE -ne 0) { Fail "pnpm install 失败" }
      & corepack pnpm build;   if ($LASTEXITCODE -ne 0) { Fail "pnpm build 失败，把报错贴给 agent 让它修" }
    } finally { Pop-Location }
    & node (Join-Path $C2cDir "bin\c2c.js") --help | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "桥已构建：$C2cDir" } else { Fail "桥自检失败（c2c --help 没跑通）" }
  }
} else {
  Step "2/4 跳过桥的安装"
}

# ---------------------------------------------------------------- 3. 下一步
Step "3/4 下一步（只剩登录 ChatGPT 了）"
@"

  把下面这段原样发给你的 agent（Hermes 或 Codex 都行）：

    我刚装好了 hermes-chatgpt-web。请按 skill「chatgpt-web-planning」里的
    references/bridge-setup.md 完成首次接入：
      1) 起一个带 --remote-debugging-port=9222 的专用 Chrome（独立 profile）
      2) c2c setup -w "$Workspace" --json，按返回的 mcpUrl / connectorName
         在 ChatGPT 网页端建自定义连接器（认证选 OAuth）并完成配对
      3) 在工作区放一个校验文件，让网页端用连接器自己读回来，逐字符比对
    只有需要我登录 ChatGPT / Cloudflare 时才叫我，一次只给我一个动作。
    完成后把绑定关系写进 %USERPROFILE%\.hermes\handoffs\chatgpt-web-state.md

  手动跑也行：
    node "$C2cDir\bin\c2c.js" tunnel status -w "$Workspace" --json
    node "$C2cDir\bin\c2c.js" setup         -w "$Workspace" --json
    node "$C2cDir\bin\c2c.js" doctor        -w "$Workspace" --json   # 期望 repairs: []

  之后日常就这么用：
    「让 GPT 看一下这个方案」「先让 GPT 出个方案」「让 GPT 审一下」「让 GPT 画张图」

"@ | Write-Host

Step "4/4 装完了"
Ok "skill：$RepoDir\skills\$SkillName"
if ($DoBridge) { Ok "桥：$C2cDir" }
Say ""
Say "提醒：桥的地址默认是临时的（重启会变）。想一劳永逸就配固定域名——"
Say "      node `"$C2cDir\bin\c2c.js`" tunnel choose -w `"$Workspace`" --mode named --zone <你的域名> --json"
