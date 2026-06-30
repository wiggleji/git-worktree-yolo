#!/usr/bin/env bash
#
# git-worktree-yolo installer
#
#   Default (skill + command, NO hook):
#     curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash
#
#   With the global auto-sync hook + secret guard:
#     curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash -s -- --with-hook
#
#   With ONLY the secret-commit guard (no auto-sync):
#     curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash -s -- --with-guard
#
# Multi-agent: installs the skill to ~/.agents/skills (the open standard read by OpenAI Codex
# and Google Antigravity) and to ~/.claude/skills (Claude Code), plus slash-command/workflow
# wrappers, and optionally global git hooks (auto-sync and/or secret guard). Re-running updates
# in place. Target a specific agent with:  --agent claude|codex|antigravity|all  (default: auto).
#
set -euo pipefail

REPO="https://github.com/wiggleji/git-worktree-yolo"
BRANCH="main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
WITH_HOOK=0; WITH_GUARD=0; AGENT="auto"
[[ "${WT_YOLO_HOOK:-0}" == 1 ]] && WITH_HOOK=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-hook)  WITH_HOOK=1 ;;
    --with-guard) WITH_GUARD=1 ;;
    --agent)      AGENT="${2:-auto}"; shift ;;
    --agent=*)    AGENT="${1#--agent=}" ;;
    *) ;;
  esac
  shift
done

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

command -v git  >/dev/null || { echo "git is required" >&2; exit 1; }
command -v perl >/dev/null || c_warn "perl not found — path rewriting will be skipped (copy still works)"

# Which agents to install for. 'auto' = the open ~/.agents/skills standard (Codex +
# Antigravity IDE) always, plus Claude/Antigravity targets that already exist.
want() { case ",$AGENT," in *",all,"*|*",$1,"*) return 0 ;; *) return 1 ;; esac; }
auto() { [[ "$AGENT" == auto ]]; }

c_info "Installing git-worktree-yolo (agent: $AGENT)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [[ -n "${WT_YOLO_SRC:-}" && -d "$WT_YOLO_SRC" ]]; then
  cp -R "$WT_YOLO_SRC" "$TMP/repo"          # install from a local checkout (offline / testing)
else
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP/repo" >/dev/null 2>&1 \
    || { echo "failed to clone $REPO" >&2; exit 1; }
fi

SKILLSRC="$TMP/repo/skills/git-worktree-yolo"
install_skill_dir() {                 # $1 = a skills root dir
  local d="$1/git-worktree-yolo"
  mkdir -p "$1"; rm -rf "$d"; cp -R "$SKILLSRC" "$d"; chmod +x "$d"/*.sh
  c_ok "skill    → $d"
}
S=""   # path to one installed script, used for the optional hook install

# 1) Open cross-runtime standard: ~/.agents/skills  (OpenAI Codex + Antigravity IDE)
if want codex || want antigravity || auto; then
  install_skill_dir "$HOME/.agents/skills"
  S="$HOME/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh"
  c_info "           (read by OpenAI Codex and Google Antigravity from ~/.agents/skills)"
fi

# 2) Claude Code: its own skills dir + slash command
if want claude || { auto && [[ -d "$CLAUDE_DIR" ]]; }; then
  install_skill_dir "$CLAUDE_DIR/skills"
  mkdir -p "$CLAUDE_DIR/commands"
  cp "$TMP/repo/commands/worktree-yolo-hook.md" "$CLAUDE_DIR/commands/worktree-yolo-hook.md"
  c_ok "command  → /worktree-yolo-hook (Claude Code)"
  S="${S:-$CLAUDE_DIR/skills/git-worktree-yolo/git-worktree-yolo.sh}"
fi

# 3) Antigravity global workflow (the /-invokable command), if Antigravity is present/requested
if want antigravity || { auto && [[ -d "$HOME/.gemini" ]]; }; then
  WF="$HOME/.gemini/antigravity/global_workflows"
  if [[ -f "$TMP/repo/workflows/worktree-yolo-hook.md" ]]; then
    mkdir -p "$WF"; cp "$TMP/repo/workflows/worktree-yolo-hook.md" "$WF/worktree-yolo-hook.md"
    c_ok "workflow → /worktree-yolo-hook (Antigravity)"
  fi
fi

# fallback: ensure at least the open standard is installed
[[ -z "$S" ]] && { install_skill_dir "$HOME/.agents/skills"; S="$HOME/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh"; }

# optional global hooks (git-native — agent-agnostic, the reliable automation layer)
if [[ "$WITH_HOOK" == 1 ]]; then
  bash "$S" --install-global-hook
  c_ok "global hooks → ON: auto-sync worktrees + pre-commit secret guard (every repo)"
elif [[ "$WITH_GUARD" == 1 ]]; then
  bash "$S" --install-guard
  c_ok "secret guard → ON: blocks committing env/secret files (every repo)"
else
  c_info "global hooks  → not installed (default). Enable:"
  c_info "                /worktree-yolo-hook on   (auto-sync + secret guard)"
  c_info "                bash \"$S\" --install-guard   (secret guard only)"
fi

echo
c_info "Done. Works in Claude Code, OpenAI Codex, and Google Antigravity (shared ~/.agents/skills)."
c_info "The skill audits for committable secrets on every run; say \"sync my worktree\" to invoke it."
