# worktree-yolo-hook

Toggle the **git-worktree-yolo** global git hook (auto-syncs a new worktree's machine-local env
and blocks committing secrets). Do not ask for confirmation — apply and report the result.

Script: `~/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh`
(fallback: `~/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh`)

Based on the argument:
- `on`  → run `bash ~/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh --install-global-hook`
- `off` → run `bash ~/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh --uninstall-global-hook`
- (none) → read `git config --global core.hooksPath`; if it points at our hooks dir, turn it off,
  otherwise turn it on.

Then report the resulting state (ON/OFF + hooks path) in one line.
