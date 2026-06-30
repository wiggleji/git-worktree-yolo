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

## Install (one line)

Installs the skill + the `/worktree-yolo-hook` command into `~/.claude`.

**Default — skill only, no hook** (you trigger it, nothing touches your git config):

```bash
curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash
```

**With the global auto-sync hook** (every `git worktree add` on your machine self-heals):

```bash
curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash -s -- --with-hook
```

Re-running updates in place. Override the target with `CLAUDE_CONFIG_DIR=...`.

<details><summary>Other install methods</summary>

**Project skill (shared with your team, zero per-developer install)** — clone the `skills/`
subtree into your repo and commit it:

```bash
git clone --depth 1 https://github.com/wiggleji/git-worktree-yolo /tmp/wty
cp -R /tmp/wty/skills/git-worktree-yolo .claude/skills/git-worktree-yolo
cp /tmp/wty/commands/worktree-yolo-hook.md .claude/commands/
```
Claude Code auto-discovers `.claude/skills/`, so anyone who clones the repo gets it.

</details>

## Usage

```bash
S="$HOME/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh"

bash "$S" --dry-run [WORKTREE_DIR]      # preview (do this first on a new repo)
bash "$S" [WORKTREE_DIR]                # sync current (or named) worktree — idempotent
bash "$S" --install-hook                # per-repo: this repo's 'git worktree add' self-heals
bash "$S" --install-global-hook         # global: every repo on the machine self-heals
bash "$S" --uninstall-global-hook       # turn the global hook back off
```

Run from inside a worktree, or pass its path. In the main worktree it's a safe no-op.

Inside Claude Code you can also just say *"sync my worktree"*, or use the toggle command:

```
/worktree-yolo-hook on      # enable global auto-sync hook
/worktree-yolo-hook off     # disable it
/worktree-yolo-hook         # toggle current state
```

## Automatic invocation

- **Global git hook** (above / `--with-hook` / `/worktree-yolo-hook on`) — fires on every
  `git worktree add`, machine-wide, via `core.hooksPath`. Chains to your existing per-repo
  `post-checkout` so nothing is lost. Reverse with `--uninstall-global-hook`.
- **Per-repo or committed Claude Code hooks** — see **[automation.md](skills/git-worktree-yolo/automation.md)**
  for `post-checkout` and `SessionStart`/`SubagentStart` recipes.

## Tuning

The skip-list and size cap are arrays at the top of `skills/git-worktree-yolo/git-worktree-yolo.sh`.
Add project-specific dirs there, or override the cap: `WTSYNC_MAX_BYTES=2097152 bash …`.

## Proof / tests

Two isolated harnesses (they never touch your real repos or `~/.gitconfig`):

```bash
bash skills/git-worktree-yolo/simulate.sh         # core sync → RESULT: 18 passed, 0 failed
bash skills/git-worktree-yolo/test-global-hook.sh # global hook → RESULT: 12 passed, 0 failed
```

`simulate.sh` builds a throwaway Rails-like repo, creates a worktree (which breaks), runs the
sync, and asserts sync, boundary-aware path rewrite, binary-verbatim copy, heavy-dir skip,
`.iml` exclusion, **zero git diff**, and idempotency. `test-global-hook.sh` proves the global
hook install/chain/uninstall in a sandboxed `HOME`.

## How it works (internals)

See **[SKILL.md](skills/git-worktree-yolo/SKILL.md)** for the skill contract,
**[automation.md](skills/git-worktree-yolo/automation.md)** for hook recipes, and
**[spec.md](skills/git-worktree-yolo/spec.md)** for the design.

## License

MIT — see [LICENSE](LICENSE).
