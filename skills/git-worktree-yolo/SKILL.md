---
name: git-worktree-yolo
description: Use when a git worktree won't run, compile, or debug because machine-local files are missing or paths are wrong — symptoms like ".env missing in the worktree", "DB won't connect in api-server-feature", "JetBrains/VSCode run config broken after git worktree add", or absolute paths still pointing at the origin checkout. Also use when starting work (as an agent or human) inside any non-main git worktree, to self-heal its environment and see which stack/IDE/dependencies it needs before proceeding. Multi-stack: server (Ruby/Rails, Python, Node, Go, Java/Kotlin, .NET, PHP), web (JS/TS), and mobile (iOS, Android, React Native, Flutter).
---

# git-worktree-yolo

**YOLO = You Only Load Once.** Entering a git worktree, run this once and its env is healed —
the run is idempotent, so re-runs are free no-ops. Agents and humans should run it the moment
they start working in any non-main worktree, before building/running/debugging.

## Overview

`git worktree add` only checks out **tracked** files. Gitignored machine-local files
(`.env`, `config/master.key`, `.idea/workspace.xml`, JetBrains `.run/*` configs, datasource
files) do NOT propagate, and some that carry over hardcode the origin's absolute path. The new
worktree then can't connect to a DB, run, or debug.

`git-worktree-yolo.sh` mirrors those files from the **origin (main) worktree** into the current
worktree and rewrites any baked-in origin path to the worktree's path — touching **only
gitignored files**, so it can never create a `git status` diff. It then **detects the repo's
stack(s) and IDE(s)** and reports what was synced and which dependency bootstrap the worktree
still needs (`npm ci`, `pod install`, `pip install`, …) — optionally running them with `--bootstrap`.

Supports server (Ruby/Rails, Python, Node, Go, Java/Kotlin, .NET, PHP), web (JS/TS: Next, Vite,
CRA, Nuxt, Svelte), and mobile (iOS/CocoaPods, Android/Gradle, React Native, Flutter); IDEs:
JetBrains, VSCode, Fleet, Zed, Nova, Xcode. Per-repo tuning via a committed `.worktree-yolo` manifest.

**Surface the report to the user.** When you (an agent) run this on entering a worktree, show
the user the printed stack/IDE/synced/next-steps summary before proceeding — it tells them what
environment the worktree has and what they must install.

## When to Use

- **First thing on entering a non-main worktree** (agent or human), before run/compile/debug
- A fresh worktree won't boot, or `.env`/`master.key`/IDE run configs are missing
- A config still points at the origin checkout path
- **Not** for tracked-file problems (those carry over already) — only the gitignored layer

## Quick Reference

```bash
S="$HOME/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh"

bash "$S" --dry-run [WORKTREE_DIR]   # preview (do this first on a new repo)
bash "$S" [WORKTREE_DIR]             # sync + report stack/IDE/next-steps — idempotent
bash "$S" --bootstrap [WORKTREE_DIR] # also RUN the dep installs (npm ci / pod install / …)
bash "$S" --install-hook             # per-repo post-checkout hook (this repo only)
bash "$S" --install-global-hook      # global hook: every repo on the machine self-heals
bash "$S" --uninstall-global-hook    # turn the global hook off
```

Run from inside the worktree, or pass its path. Running in the main worktree is a safe no-op.
The toggle command `/worktree-yolo-hook [on|off]` wraps the global hook install/uninstall.

The report looks like:

```
git-worktree-yolo · api-server-feature
  stack:  Rails · Node(npm) · iOS
  IDE:    JetBrains · VSCode
  done: 8 synced, 2 path-rewritten, heavy/oversized skipped
  next steps — this worktree still needs dependencies installed:
      npm ci         # node_modules (npm)
      pod install    # Pods (CocoaPods)
```

## Automatic invocation (no agent decision needed)

The skill is *available* once committed to a repo (`.claude/skills/git-worktree-yolo/`), but
availability ≠ auto-run. For true hands-off behavior, trigger the script from a hook so every
worktree self-heals:

- **Global git hook (recommended, install once):** `bash "$S" --install-global-hook` (or
  `/worktree-yolo-hook on`) sets `core.hooksPath` so every `git worktree add` in any repo
  self-syncs. Chains to existing per-repo `post-checkout` hooks.
- **Per-repo:** `bash "$S" --install-hook` wires the hook into just this repo's shared git dir.
- **Team-wide, zero-install:** a committed `.claude/settings.json` `SessionStart`/`SubagentStart`
  hook (shared on clone). See `automation.md` for the exact config and trade-offs.

## How It Works

Origin = parent of `git rev-parse --git-common-dir`; target = current worktree. It enumerates
origin's gitignored files, **skips** heavy/regenerable dirs (`node_modules tmp log coverage
vendor target .gradle build dist public .claude/worktrees`), junk (`.DS_Store *.log`),
auto-managed JetBrains module files (`*.iml`, `.idea/modules.xml`), and files over 1 MiB.
It **copies** survivors only if absent or origin is newer (never clobbers local edits), then
**rewrites** the origin path → target path in text files — boundary-aware so `…/api-server`
isn't corrupted inside `…/api-server-outbox` (binaries copied verbatim).

**Core invariant:** every write must be gitignored in the target (`git check-ignore`),
guaranteeing zero git diff. Tune the skip-list/size-cap arrays atop the script, or override
with `WTSYNC_MAX_BYTES`.

After syncing it detects per-repo dependency dirs that don't carry over (`node_modules`, `.venv`,
`Pods`, `vendor`, `.dart_tool`) and prints the right recreate command (lockfile-aware:
npm/yarn/pnpm, pip/poetry/uv, …). Globally-cached ecosystems (Gradle `~/.gradle`, Maven `~/.m2`,
Go `~/go`, NuGet) are *not* nagged — a worktree shares those caches.

**`.worktree-yolo` manifest** (committed at repo root) extends the defaults:

```
sync     config/local-overrides.yml      # force-sync a path the skip-list would drop
skip      data/fixtures                    # never sync this
recreate  node_modules -- pnpm install     # custom "missing dir → command" hint
```

## Common Mistakes

- **`cp -r origin/* worktree/`** — clobbers tracked files and copies `node_modules`, producing
  a huge git diff. Use the script; it touches only gitignored files.
- **Syncing `*.iml` / `modules.xml`** — JetBrains auto-generates per-worktree, name-specific
  module files; copying the origin's corrupts the worktree's project structure (excluded by design).
- **Skipping the dry-run on a new repo** — confirm the candidate list looks like config, not
  generated data, before the first real sync.

## Verification

Three isolated harnesses ship alongside this skill (none touch real repos or `~/.gitconfig`):

```bash
D="$(dirname "$0")"
bash "$D/simulate.sh"          # core sync/rewrite/skip/zero-diff/idempotency → 18 passed
bash "$D/test-global-hook.sh"  # global core.hooksPath install/chain/uninstall → 12 passed
bash "$D/test-multistack.sh"   # stack+IDE detection, report, manifest, --bootstrap → 19 passed
```
