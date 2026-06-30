---
description: Toggle the git-worktree-yolo global git hook on/off (auto-syncs a worktree's machine-local env on creation)
argument-hint: "[on|off]  (no arg = toggle current state)"
allowed-tools: Bash(bash:*), Bash(git config:*)
---

Manage the **git-worktree-yolo** global `post-checkout` hook. When ON, every `git worktree add`
on this machine auto-syncs the new worktree's gitignored env (`.env`, IDE run configs) from the
main worktree. Do **not** ask for confirmation — just apply and report.

Script: `~/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh`

Interpret `$ARGUMENTS`:

- `on`  → run `bash ~/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh --install-global-hook`
- `off` → run `bash ~/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh --uninstall-global-hook`
- empty → **toggle**: read `git config --global core.hooksPath`. If it points at
  `${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks` (our hook is active), run `--uninstall-global-hook`;
  otherwise run `--install-global-hook`.

After running, report the resulting state in one line (ON or OFF, and the hooks path), and if it
was just turned ON, remind the user it applies to every repo via `core.hooksPath`.
