# AGENTS.md — git-worktree-yolo

Cross-agent instructions (read by OpenAI Codex, GitHub Copilot, Cursor, Zed, and others via the
[AGENTS.md](https://agents.md) standard; Claude Code reads `CLAUDE.md`, Gemini/Antigravity read
`GEMINI.md` — keep those as one-line pointers to this file).

## What this project is

A portable tool that makes a fresh `git worktree` runnable/debuggable by syncing the gitignored
machine-local files `git worktree add` leaves behind (`.env`, IDE run configs, keys, Android
`local.properties`, …) from the main worktree, rewriting baked-in absolute paths, and **never
touching tracked files** (zero `git status` diff). It detects the stack/IDE, guides dependency
bootstrap, and guards against committing secrets.

## How an agent should use it

When you start working inside a **non-main git worktree** (or a worktree won't build/run/debug):

1. Run the skill's script against the worktree, then **show the user its report** (detected
   stack/IDE, what was synced, what dependencies still need installing) before proceeding:
   ```bash
   bash ~/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh "$PWD"
   # (Claude Code: ~/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh)
   ```
2. If it reports missing deps, run them (or `--bootstrap` to auto-run).
3. **Never commit secrets.** The tool only writes gitignored files and ships a pre-commit guard
   (`--install-guard`) that blocks committing `.env`/keys/keystores. Do not work around it; if a
   file is wrongly flagged, add `allow <glob>` to `.worktree-yolo`.

## Automatic operation

The reliable, agent-agnostic automation is the git hook: `git-worktree-yolo.sh --install-global-hook`
installs a `post-checkout` hook (auto-sync on every `git worktree add`) plus a `pre-commit`
secret guard, machine-wide. This fires regardless of which agent is running.
