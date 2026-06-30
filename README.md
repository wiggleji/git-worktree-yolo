# git-worktree-yolo

> **YOLO — You Only Load Once.** Enter a git worktree, run it once, and its environment is
> healed. Re-runs are free no-ops, so it's safe to fire automatically on every agent/session start.

A Claude Code **skill** (and standalone bash script) that makes a freshly-created `git worktree`
actually runnable, compilable, and debuggable in your IDE — by mirroring the machine-local files
that `git worktree add` leaves behind, **without ever touching a tracked file** (zero `git status` diff).

## The problem

`git worktree add` only checks out **tracked** files. The gitignored, machine-local files your
app needs at runtime do **not** propagate into the new worktree:

- `.env`, `config/master.key`, datasource configs → the worktree can't connect to a DB or boot
- `.idea/workspace.xml`, JetBrains `.run/*`, `.vscode/*` → IDE run/debug configs are missing
- Files that *do* carry over sometimes hardcode the **origin's absolute path**
  (e.g. `/Users/you/api-server`), which is now wrong inside `/Users/you/api-server-feature`

So you `git worktree add api-server-feature`, open it in your IDE, hit Run… and it breaks.

## What it does

1. Finds the **origin (main) worktree** and the **current** worktree.
2. Copies origin's gitignored machine-local config into the worktree (only if absent or newer —
   never clobbers your local edits).
3. **Rewrites** the origin's absolute path → the worktree's path in text files — *boundary-aware*,
   so `…/api-server` is never corrupted inside the longer `…/api-server-feature`.
4. **Skips** what shouldn't travel: heavy/regenerable dirs (`node_modules tmp log coverage vendor
   target .gradle build dist public .claude/worktrees`), junk (`.DS_Store`, `*.log`), files >1 MiB,
   and JetBrains auto-managed module files (`*.iml`, `modules.xml`) that are per-worktree and
   name-specific — copying them would *break* the worktree's project structure.
5. **Safety invariant:** every file it writes must be gitignored in the target
   (verified with `git check-ignore`), so it can never create a `git status` diff.

Works with Rails, Spring/Gradle, and Node repos. Runs on macOS (bash 3.2+) and Linux; needs
`git` and `perl` (both standard).

## Install

**As a project skill (shared with your whole team, zero per-developer install):**

```bash
git clone https://github.com/wiggleji/git-worktree-yolo \
  .claude/skills/git-worktree-yolo
```
Commit `.claude/skills/git-worktree-yolo/` — anyone who clones the repo gets the skill
automatically (Claude Code auto-discovers `.claude/skills/`).

**As a personal skill (all your projects):**

```bash
git clone https://github.com/wiggleji/git-worktree-yolo \
  ~/.claude/skills/git-worktree-yolo
```

## Usage

```bash
S=".claude/skills/git-worktree-yolo/git-worktree-yolo.sh"   # or the ~/.claude path

bash "$S" --dry-run [WORKTREE_DIR]   # preview (do this first on a new repo)
bash "$S" [WORKTREE_DIR]             # sync current (or named) worktree — idempotent
bash "$S" --install-hook             # one-time: every future 'git worktree add' self-heals
```

Run from inside a worktree, or pass its path. In the main worktree it's a safe no-op.

Inside Claude Code you can also just say *"sync my worktree"* and the skill is invoked.

## Automatic invocation

For hands-off self-healing on every agent/session start, wire it to a Claude Code hook
(committed, no per-developer install) or a git `post-checkout` hook. See **[automation.md](automation.md)**.

## Tuning

The skip-list and size cap are arrays at the top of `git-worktree-yolo.sh`. Add project-specific
dirs there, or override the cap: `WTSYNC_MAX_BYTES=2097152 bash git-worktree-yolo.sh`.

## Proof / tests

`simulate.sh` builds a throwaway Rails-like repo, creates a worktree (which breaks), runs the
sync, and asserts 18 invariants — sync, boundary-aware path rewrite, binary-verbatim copy,
heavy-dir skip, `.iml` exclusion, **zero git diff**, and idempotency:

```bash
bash simulate.sh        # → RESULT: 18 passed, 0 failed
```

## How it works (internals)

See **[SKILL.md](SKILL.md)** for the skill contract and **[spec.md](spec.md)** for the design.

## License

MIT — see [LICENSE](LICENSE).
