#!/usr/bin/env bash
# hermes-chatgpt-web · macOS / Linux 安装器
#
#   一句话装：
#     curl -fsSL https://raw.githubusercontent.com/d2dmh/hermes-chatgpt-web/main/install.sh | bash
#
# 干什么：① 把 skill 装进你已有的 agent（Hermes 走 skills tap，Codex 走 skills 目录）
#         ② 把「只读 MCP 桥」（c2c）clone + 构建好 ③ 打印下一步（就剩登录 ChatGPT 了）
# 不干什么：不替你登录、不碰你已有的 skill（同名会先备份）、不索取任何凭据。
#
# 常用参数：
#   --workspace <路径>   要被网页端读的工程目录（默认：$HOME/codex，不存在则用当前目录）
#   --skills-only        只装 skill，不动桥
#   --no-bridge          同上
#   --no-hermes / --no-codex   跳过对应宿主
#   --dry-run            只打印将要执行的动作
# 环境变量覆盖：HERMES_HOME / CODEX_HOME / C2C_DIR / REPO_DIR
set -euo pipefail

OWNER="d2dmh"
REPO="hermes-chatgpt-web"
SKILL_NAME="chatgpt-web-planning"
REPO_URL="${REPO_URL:-https://github.com/${OWNER}/${REPO}.git}"
BRIDGE_REPO="${BRIDGE_REPO:-https://github.com/XiaoDuoYa/codex-with-chatgpt.git}"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
REPO_DIR="${REPO_DIR:-$HOME/$REPO}"
C2C_DIR="${C2C_DIR:-$HOME/codex-with-chatgpt}"
WORKSPACE=""
DO_BRIDGE=1
DO_HERMES=1
DO_CODEX=1
DRY_RUN=0

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$c_dim" "$c_off" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '%s  [dry-run]%s %s\n' "$c_dim" "$c_off" "$*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --skills-only|--no-bridge) DO_BRIDGE=0; shift ;;
    --no-hermes) DO_HERMES=0; shift ;;
    --no-codex)  DO_CODEX=0; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "不认识的参数：$1（--help 看用法）" ;;
  esac
done

say "hermes-chatgpt-web · 安装器（macOS / Linux）"
say "让网页版 ChatGPT 当你的规划与审查大脑；本机 agent 负责执行。"
say "${c_dim}本脚本只装依赖与 skill，不登录、不索取凭据。${c_off}"

# ---------------------------------------------------------------- 0. 体检
step "0/4 环境体检"
command -v git >/dev/null || die "缺 git。macOS：xcode-select --install；Debian/Ubuntu：sudo apt install git"
ok "git $(git --version | awk '{print $3}')"

if command -v node >/dev/null; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -lt 20 ]; then
    warn "Node $(node -v) 太旧，桥需要 ≥ 20"
    DO_BRIDGE=0
  else
    ok "node $(node -v)"
  fi
else
  warn "没装 Node.js（桥需要 ≥ 20）"
  DO_BRIDGE=0
fi
[ "$DO_BRIDGE" = 1 ] || warn "跳过桥的安装；装好 Node ≥ 20 后重跑本脚本即可"

if [ -z "$WORKSPACE" ]; then
  if [ -d "$HOME/codex" ]; then WORKSPACE="$HOME/codex"; else WORKSPACE="$PWD"; fi
fi
[ -d "$WORKSPACE" ] || die "工作目录不存在：$WORKSPACE"
ok "工作目录：$WORKSPACE"

# ---------------------------------------------------------------- 1. skill
backup_if_differs() {  # $1 = 目标目录
  local dst="$1"
  [ -d "$dst" ] || return 0
  if [ -f "$dst/SKILL.md" ] && cmp -s "$dst/SKILL.md" "$REPO_DIR/skills/$SKILL_NAME/SKILL.md"; then
    return 0
  fi
  local bak="${dst}.bak-$(date +%Y%m%d%H%M%S)"
  warn "已存在的 $SKILL_NAME 与本次安装的不同，先备份到：$bak"
  run mv "$dst" "$bak"
}

install_for_codex() {
  local dst="$CODEX_HOME/skills/$SKILL_NAME"
  mkdir -p "$CODEX_HOME/skills"
  backup_if_differs "$dst"
  run rm -rf "$dst"
  run cp -R "$REPO_DIR/skills/$SKILL_NAME" "$dst"
  ok "Codex skill → $dst"
}

step "1/4 取回 skill 源码"
if [ -d "$REPO_DIR/.git" ]; then
  run git -C "$REPO_DIR" pull --ff-only || warn "git pull 失败（本地有改动？），继续用现有副本"
else
  run git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi
[ "$DRY_RUN" = 1 ] || [ -f "$REPO_DIR/skills/$SKILL_NAME/SKILL.md" ] || die "克隆里没找到 skills/$SKILL_NAME/SKILL.md"

if [ "$DO_HERMES" = 1 ] && command -v hermes >/dev/null; then
  step "1a 装进 Hermes（走 skills tap，之后 hermes skills update 就能更新）"
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] hermes skills tap add ${OWNER}/${REPO}"
    say "  [dry-run] hermes skills install ${OWNER}/${REPO}/skills/${SKILL_NAME} -y --category autonomous-ai-agents"
  else
    hermes skills tap add "${OWNER}/${REPO}" >/dev/null 2>&1 || true
    if hermes skills install "${OWNER}/${REPO}/skills/${SKILL_NAME}" -y --category autonomous-ai-agents 2>&1 | tail -3; then
      ok "Hermes skill 已安装（来源：${OWNER}/${REPO}）"
    else
      warn "经 skills tap 安装失败，改用本地拷贝"
      dst="$HERMES_HOME/skills/autonomous-ai-agents/$SKILL_NAME"
      mkdir -p "$(dirname "$dst")"; backup_if_differs "$dst"; rm -rf "$dst"
      cp -R "$REPO_DIR/skills/$SKILL_NAME" "$dst"; ok "Hermes skill → $dst"
    fi
  fi
else
  [ "$DO_HERMES" = 1 ] && warn "没找到 hermes 命令（想装 Hermes：https://hermes-agent.nousresearch.com/docs 里的安装脚本）"
fi

if [ "$DO_CODEX" = 1 ]; then
  CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
  if [ -d "$CODEX_HOME" ]; then
    step "1b 装进 Codex（$CODEX_HOME/skills）"
    install_for_codex
  else
    warn "没找到 $CODEX_HOME，跳过 Codex 侧（要用 Codex 就先装它，或设 CODEX_HOME 后重跑）"
  fi
fi

# ---------------------------------------------------------------- 2. 桥
if [ "$DO_BRIDGE" = 1 ]; then
  step "2/4 装桥（只读 MCP 服务 + 隧道）"
  if ! command -v cloudflared >/dev/null; then
    if command -v brew >/dev/null; then
      say "  cloudflared 缺失，用 Homebrew 安装…"
      run brew install cloudflared || warn "brew 安装 cloudflared 失败，请手动安装后重跑"
    else
      warn "缺 cloudflared 且没有 brew：请自行安装（https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/）"
    fi
  else
    ok "cloudflared 已就绪"
  fi

  if [ -d "$C2C_DIR/.git" ]; then
    run git -C "$C2C_DIR" pull --ff-only || warn "桥的仓库 pull 失败，继续用现有副本"
  else
    run git clone "$BRIDGE_REPO" "$C2C_DIR"
  fi
  if [ "$DRY_RUN" = 0 ]; then
    ( cd "$C2C_DIR" && corepack pnpm install && corepack pnpm build ) || die "桥构建失败，把报错贴给 agent 让它修"
    node "$C2C_DIR/bin/c2c.js" --help >/dev/null && ok "桥已构建：$C2C_DIR"
  fi
else
  step "2/4 跳过桥的安装"
fi

# ---------------------------------------------------------------- 3. 下一步
step "3/4 下一步（只剩登录 ChatGPT 了）"
cat <<EOF

  把下面这段原样发给你的 agent（Hermes 或 Codex 都行）：

    我刚装好了 hermes-chatgpt-web。请按 skill「chatgpt-web-planning」里的
    references/bridge-setup.md 完成首次接入：
      1) 起一个带 --remote-debugging-port=9222 的专用 Chrome（独立 profile）
      2) c2c setup -w "$WORKSPACE" --json，按返回的 mcpUrl / connectorName
         在 ChatGPT 网页端建自定义连接器（认证选 OAuth）并完成配对
      3) 在工作区放一个校验文件，让网页端用连接器自己读回来，逐字符比对
    只有需要我登录 ChatGPT / Cloudflare 时才叫我，一次只给我一个动作。
    完成后把绑定关系写进 \$HOME/.hermes/handoffs/chatgpt-web-state.md

  ${c_dim}手动跑也行：
    node $C2C_DIR/bin/c2c.js tunnel status -w "$WORKSPACE" --json
    node $C2C_DIR/bin/c2c.js setup         -w "$WORKSPACE" --json
    node $C2C_DIR/bin/c2c.js doctor        -w "$WORKSPACE" --json   # 期望 repairs: []${c_off}

  之后日常就这么用：
    「让 GPT 看一下这个方案」「先让 GPT 出个方案」「让 GPT 审一下」「让 GPT 画张图」

EOF
step "4/4 装完了"
[ "$DRY_RUN" = 1 ] && warn "以上是 dry-run：没有真的克隆 / 安装 / 构建，路径是「将要」用的路径"
ok "skill：$REPO_DIR/skills/$SKILL_NAME"
[ "$DO_BRIDGE" = 1 ] && ok "桥：$C2C_DIR"
say ""
say "提醒：桥的地址默认是临时的（重启会变）。想一劳永逸就配固定域名——"
say "      ${c_dim}node $C2C_DIR/bin/c2c.js tunnel choose -w \"$WORKSPACE\" --mode named --zone <你的域名> --json${c_off}"
