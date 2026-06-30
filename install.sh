#!/usr/bin/env bash
#
# git-worktree-yolo installer
#
#   Default (skill + command, NO hook):
#     curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash
#
#   With the global auto-sync hook enabled:
#     curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash -s -- --with-hook
#
# Installs into ~/.claude (personal scope): the skill, the /worktree-yolo-hook command,
# and optionally the global post-checkout hook. Re-running updates in place.
#
set -euo pipefail

REPO="https://github.com/wiggleji/git-worktree-yolo"
BRANCH="main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
WITH_HOOK=0
[[ "${WT_YOLO_HOOK:-0}" == 1 ]] && WITH_HOOK=1
for a in "$@"; do [[ "$a" == "--with-hook" ]] && WITH_HOOK=1; done

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

command -v git  >/dev/null || { echo "git is required" >&2; exit 1; }
command -v perl >/dev/null || c_warn "perl not found — path rewriting will be skipped (copy still works)"

c_info "Installing git-worktree-yolo into $CLAUDE_DIR"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [[ -n "${WT_YOLO_SRC:-}" && -d "$WT_YOLO_SRC" ]]; then
  cp -R "$WT_YOLO_SRC" "$TMP/repo"          # install from a local checkout (offline / testing)
else
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP/repo" >/dev/null 2>&1 \
    || { echo "failed to clone $REPO" >&2; exit 1; }
fi

# skill
mkdir -p "$CLAUDE_DIR/skills"
rm -rf "$CLAUDE_DIR/skills/git-worktree-yolo"
cp -R "$TMP/repo/skills/git-worktree-yolo" "$CLAUDE_DIR/skills/git-worktree-yolo"
chmod +x "$CLAUDE_DIR/skills/git-worktree-yolo/"*.sh
c_ok "skill        → $CLAUDE_DIR/skills/git-worktree-yolo"

# slash command
mkdir -p "$CLAUDE_DIR/commands"
cp "$TMP/repo/commands/worktree-yolo-hook.md" "$CLAUDE_DIR/commands/worktree-yolo-hook.md"
c_ok "command      → /worktree-yolo-hook"

# optional global hook
if [[ "$WITH_HOOK" == 1 ]]; then
  bash "$CLAUDE_DIR/skills/git-worktree-yolo/git-worktree-yolo.sh" --install-global-hook
  c_ok "global hook  → ON (every 'git worktree add' self-heals)"
else
  c_info "global hook   → not installed (default). Turn on anytime with: /worktree-yolo-hook on"
fi

echo
c_info "Done. In Claude Code: say \"sync my worktree\" or run /worktree-yolo-hook to toggle auto-sync."
