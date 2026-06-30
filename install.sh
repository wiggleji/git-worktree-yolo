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
# Installs into ~/.claude (personal scope): the skill, the /worktree-yolo-hook command,
# and optionally global git hooks (auto-sync and/or secret guard). Re-running updates in place.
#
set -euo pipefail

REPO="https://github.com/wiggleji/git-worktree-yolo"
BRANCH="main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
WITH_HOOK=0; WITH_GUARD=0
[[ "${WT_YOLO_HOOK:-0}" == 1 ]] && WITH_HOOK=1
for a in "$@"; do
  [[ "$a" == "--with-hook" ]]  && WITH_HOOK=1
  [[ "$a" == "--with-guard" ]] && WITH_GUARD=1
done

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

# optional global hooks
S="$CLAUDE_DIR/skills/git-worktree-yolo/git-worktree-yolo.sh"
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
c_info "Done. The skill audits for committable secrets on every run; say \"sync my worktree\"."
