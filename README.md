# git-worktree-yolo

> **YOLO — You Only Load Once.** Enter a git worktree, run it once, and its environment is
> healed. Re-runs are free no-ops, so it's safe to fire automatically on every agent/session start.

**A cross-agent Agent Skill** for **Claude Code · OpenAI Codex · Google Antigravity** (and any
tool that follows the [Agent Skills](https://agentskills.io) `SKILL.md` standard and
[`AGENTS.md`](https://agents.md)). It makes a freshly-created `git worktree` actually runnable,
compilable, and debuggable — by mirroring the machine-local files that `git worktree add` leaves
behind, **without ever touching a tracked file** (zero `git status` diff).

Built on open standards, so one install works everywhere:
- **`SKILL.md` + `~/.agents/skills/`** — the shared skill spec read by Codex and Antigravity; Claude Code uses `~/.claude/skills/`.
- **`AGENTS.md`** — the shared cross-agent instructions standard.
- **git hooks** — the engine is a portable bash script + `post-checkout`/`pre-commit` hooks, so it works in **any** agent (or none) the moment git runs.

## Contents

- [Install](#install)
- [Usage](#usage)
- [The problem](#the-problem)
- [What it does](#what-it-does) — incl. [Supported stacks & IDEs](#supported-stacks--ides)
- [Safety — never commits secrets](#safety--never-commits-secrets)
- [Works across agents](#works-across-agents-claude-code--openai-codex--google-antigravity)
- [Automatic invocation](#automatic-invocation)
- [Tuning](#tuning)
- [Proof / tests](#proof--tests)
- [How it works](#how-it-works-internals)
- [License](#license)

## Install

Auto-detects your agents and installs the skill to the shared **`~/.agents/skills/`** (OpenAI
Codex + Google Antigravity) and to **`~/.claude/skills/`** (Claude Code), plus each agent's
slash-command/workflow wrapper. Target one explicitly with `--agent claude|codex|antigravity|all`.

**Default — skill only, no hook** (you trigger it, nothing touches your git config):

```bash
curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash
```

**With the global auto-sync hook + secret guard** (every `git worktree add` self-heals; commits with secrets are blocked):

```bash
curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash -s -- --with-hook
```

**With ONLY the secret-commit guard** (no auto-sync — pure safety):

```bash
curl -fsSL https://raw.githubusercontent.com/wiggleji/git-worktree-yolo/main/install.sh | bash -s -- --with-guard
```

Re-running updates in place. Override the target with `CLAUDE_CONFIG_DIR=...`. See
[Works across agents](#works-across-agents-claude-code--openai-codex--google-antigravity) for
Codex/Antigravity specifics.

<details><summary>Other install methods</summary>

**Project skill (shared with your team, zero per-developer install)** — commit the skill into
your repo at the standard project path so every agent auto-discovers it on clone:

```bash
git clone --depth 1 https://github.com/wiggleji/git-worktree-yolo /tmp/wty
# .agents/skills is the shared standard (Codex + Antigravity); .claude/skills for Claude Code
cp -R /tmp/wty/skills/git-worktree-yolo .agents/skills/git-worktree-yolo
cp -R /tmp/wty/skills/git-worktree-yolo .claude/skills/git-worktree-yolo
```
Then add an [`AGENTS.md`](AGENTS.md) (and one-line `CLAUDE.md`/`GEMINI.md` pointing to it) so
every agent shares one source of truth.

</details>

## Usage

```bash
# the script lives wherever it was installed (same on every agent):
S="$HOME/.agents/skills/git-worktree-yolo/git-worktree-yolo.sh"   # Codex / Antigravity
# S="$HOME/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh" # Claude Code

bash "$S" --dry-run [WORKTREE_DIR]      # preview (do this first on a new repo)
bash "$S" [WORKTREE_DIR]                # sync + report stack/IDE/next-steps + secret audit
bash "$S" --bootstrap [WORKTREE_DIR]    # also RUN the dep installs (npm ci / pod install / …)
bash "$S" --audit [WORKTREE_DIR]        # scan for committable secrets (exit 1 if any tracked)
bash "$S" --install-hook                # per-repo: post-checkout sync + pre-commit secret guard
bash "$S" --install-global-hook         # global: sync + secret guard for every repo
bash "$S" --uninstall-global-hook       # turn the global hooks back off
bash "$S" --install-guard               # global secret-commit guard ONLY (no auto-sync)
```

Run from inside a worktree, or pass its path. In the main worktree it's a safe no-op.

Inside Claude Code you can also just say *"sync my worktree"*, or use the toggle command:

```
/worktree-yolo-hook on      # enable global auto-sync hook
/worktree-yolo-hook off     # disable it
/worktree-yolo-hook         # toggle current state
```

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
6. **Detects the stack(s) + IDE(s)** and prints a report: what was synced and which dependency
   bootstrap the worktree still needs (`npm ci`, `pod install`, `pip install`, …) — or runs
   them with `--bootstrap`.
7. **Flags what it *can't* fix.** Some breakage lives outside the repo's gitignored layer — a
   JetBrains/IDE remote interpreter bound to the origin path (a common Docker-Compose-in-worktree
   failure), tracked files that hardcode the origin path, or symlinks into the origin checkout.
   It surfaces these as a ⚠ heads-up with the fix, rather than silently mis-"fixing" them.
8. **Concurrency-safe.** Built for parallel agents: each file is written atomically (temp + rename,
   so a reader or a crash never sees a half-written secret), and a portable per-worktree lock
   serializes concurrent syncs of the same worktree (hook + manual run) — second one skips cleanly.

```
git-worktree-yolo · api-server-feature
  stack:  Rails · Node(npm) · iOS
  IDE:    JetBrains · VSCode
  done: 8 synced, 2 path-rewritten, heavy/oversized skipped
  next steps — this worktree still needs dependencies installed:
      npm ci         # node_modules (npm)
      pod install    # Pods (CocoaPods)
```

### Supported stacks & IDEs

| Layer | Detected / handled |
|---|---|
| **Server** | Ruby/Rails (`master.key`, credentials), Python (`.venv` recreate), Node, Go, Java/Kotlin (Gradle/Maven), .NET, PHP/Laravel |
| **Web** | JS/TS — Next, Vite, CRA, Nuxt, SvelteKit, Angular (`.env*`, `.npmrc`) |
| **Mobile** | iOS/CocoaPods (`*.xcconfig`, `Pods` recreate), Android/Gradle (`local.properties` `sdk.dir`, `keystore.properties`, `*.jks`/`*.keystore`), React Native, Flutter (`.dart_tool`) |
| **IDE env** | JetBrains (`.idea`), VSCode (`.vscode`), Fleet, Zed, Nova, Xcode |
| **Secrets** | `*.key`, `*.jks`/`*.keystore`/`*.p12`, `google-services.json`, `GoogleService-Info.plist` (when gitignored, copied verbatim) |

Globally-cached ecosystems (Gradle `~/.gradle`, Maven `~/.m2`, Go `~/go`, NuGet) aren't nagged for
re-install — a worktree shares those caches. Teams tune everything via a committed
**[`.worktree-yolo`](.worktree-yolo.example)** manifest (`sync` / `skip` / `recreate` directives).

Runs on macOS (bash 3.2+) and Linux; needs `git` and `perl` (both standard).

## Safety — never commits secrets

Convenience must never leak credentials. This is enforced at three layers:

1. **Writes only gitignored files.** Every file the sync writes must be gitignored in the
   target (`git check-ignore`) — so a synced `.env` or key can never become a `git status` diff
   or be staged by `git add -A`.
2. **Refuses to misplace a secret.** If a secret (`.env*`, `*.key`, `*.pem`, `*.jks`,
   `*.keystore`, `*.p12`, `master.key`, …) isn't gitignored where it would land, the sync
   **refuses** it with a CRITICAL error instead of risking a commit.
3. **Audit + commit block.** Every run audits the repo for committable secrets (tracked, or
   not-gitignored) and reports them. The optional **pre-commit guard** *blocks any commit* that
   stages a secret file:

```bash
bash "$S" --audit            # scan: exits non-zero if a secret is tracked
bash "$S" --install-guard    # global pre-commit hook that blocks committing secrets
```

Safe-by-design exceptions (`*.example`, `*.sample`, `*.template`, `*.dist`, `*.pub`, `*.enc`)
are never flagged. Override per repo in `.worktree-yolo` (`allow <glob>` / `secret <glob>`), or
bypass a single commit with `git commit --no-verify`.

## Works across agents (Claude Code · OpenAI Codex · Google Antigravity)

The engine is **agent-agnostic** — a bash script + git hooks. The git `post-checkout`/`pre-commit`
hooks fire on `git worktree add` / `git commit` no matter which agent (or none) you use, so the
full behavior works everywhere via `--with-hook` / `--with-guard`. Only the skill *discovery* and
the slash-command wrapper differ; `install.sh` handles all three (target one with `--agent`):

| Agent | Skill location (installed) | Slash command | Instructions file |
|---|---|---|---|
| **Claude Code** | `~/.claude/skills/git-worktree-yolo/` | `/worktree-yolo-hook` (`~/.claude/commands/`) | `CLAUDE.md` |
| **OpenAI Codex** | `~/.agents/skills/git-worktree-yolo/` *(open standard)* | invoke via `$git-worktree-yolo` / `/skills` | `AGENTS.md` |
| **Google Antigravity** | `~/.agents/skills/git-worktree-yolo/` (IDE) | `/worktree-yolo-hook` workflow (`~/.gemini/antigravity/global_workflows/`) | `GEMINI.md` + `.agent/rules/` |

`~/.agents/skills/` and [`AGENTS.md`](AGENTS.md) are shared cross-agent standards, so a single
`SKILL.md` is read by Codex and Antigravity alike. Notes:
- **Codex** has a hook system (`~/.codex/hooks.json`) but no "entered a worktree" event — so the
  git `post-checkout` hook remains the right layer; optionally add a `SessionStart` hook to also
  sync when a Codex session opens in an existing worktree.
- **Antigravity** has no confirmed event-hook mechanism — rely on the git hook, and the shipped
  skill/workflow give on-request invocation. Add a one-line `.agent/rules/` entry pointing agents
  to run it on entering a worktree.
- Add a one-line `GEMINI.md`/`CLAUDE.md` pointing at `AGENTS.md` so every agent shares one source.

```bash
curl -fsSL …/install.sh | bash -s -- --agent codex        # or: claude | antigravity | all
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

Six isolated harnesses (they never touch your real repos or `~/.gitconfig`) — **84 assertions**:

```bash
bash skills/git-worktree-yolo/simulate.sh          # core sync/rewrite/skip/zero-diff   → 18 passed
bash skills/git-worktree-yolo/test-global-hook.sh  # global core.hooksPath hook          → 12 passed
bash skills/git-worktree-yolo/test-multistack.sh   # stack/IDE detection, manifest, bootstrap → 19 passed
bash skills/git-worktree-yolo/test-secret-guard.sh # audit, pre-commit block, allow-list → 15 passed
bash skills/git-worktree-yolo/test-advisory.sh     # heads-up for unfixable issues       →  5 passed
bash skills/git-worktree-yolo/test-concurrency.sh  # atomic writes, lock, parallel safety → 15 passed
```

`simulate.sh` asserts sync, boundary-aware path rewrite, binary-verbatim copy, heavy-dir skip,
`.iml` exclusion, **zero git diff**, idempotency. `test-global-hook.sh` proves the global hook
install/chain/uninstall in a sandboxed `HOME`. `test-multistack.sh` proves stack/IDE detection,
the report, recreate guidance, the `.worktree-yolo` manifest, and `--bootstrap`. `test-secret-guard.sh`
proves the secret audit, the pre-commit commit-block, the allow-list, and guard install/uninstall.
`test-advisory.sh` proves the heads-up advisories for issues the sync can't fix.

## How it works (internals)

See **[SKILL.md](skills/git-worktree-yolo/SKILL.md)** for the skill contract,
**[automation.md](skills/git-worktree-yolo/automation.md)** for hook recipes, and
**[spec.md](skills/git-worktree-yolo/spec.md)** for the design.

## License

MIT — see [LICENSE](LICENSE).
