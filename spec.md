# git-worktree-yolo — Design Spec

**Date:** 2026-06-30
**Status:** Approved for build

## Problem

`git worktree add` only checks out **tracked** files. Machine-local files that are
gitignored — `.env`, `config/master.key`, `.idea/workspace.xml`, datasource configs —
do not propagate into a new worktree. Two concrete failure modes, both confirmed in the
real `api-server` worktrees:

1. **Missing machine-local files.** 3 of 5 `api-server` worktrees have no `.env`, so they
   cannot connect to a DB at runtime. The IDE compiles/runs against the wrong (or absent)
   config.
2. **Baked-in origin paths.** Files that *do* carry over can hardcode the origin's absolute
   path, e.g. `.idea/workspace.xml` → `last_opened_file_path: /Users/.../api-server`. In a
   worktree named `api-server-outbox` that path is now wrong.

Things JetBrains already stores relative to `$MODULE_DIR$` / `$PROJECT_DIR$` (the `.iml`,
`modules.xml`) auto-adapt and must **not** be touched.

## Goal

Make a freshly-created worktree runnable and debuggable in an IDE with zero manual setup,
by mirroring gitignored machine-local files from the origin worktree and rewriting any
baked-in origin absolute path — **touching only gitignored/untracked files, never anything
git tracks** (guaranteed zero `git status` diff).

## Mechanism (`git-worktree-yolo.sh`, idempotent)

1. **Resolve origin & target.**
   - Target = `git rev-parse --show-toplevel` (current worktree).
   - Origin = parent dir of `git rev-parse --git-common-dir` (the main worktree, source of truth).
   - If origin == target → no-op (we are in the main worktree).
2. **Enumerate candidates.** `git -C "$ORIGIN" ls-files --others --ignored --exclude-standard --directory`
   = exactly the gitignored entries, with fully-ignored dirs collapsed to `dir/`.
3. **Apply skip-list** of heavy/regenerable paths: `node_modules tmp log coverage vendor
   .bundle .yarn dist build target .gradle storage public/assets .git`. (Covers Rails *and*
   Spring/Gradle build output.)
4. **Copy** each surviving candidate into the target **only if absent or origin is newer**
   (never clobber a file the user already customized in the worktree).
5. **Rewrite baked-in paths.** In copied **text** files only (binary detected & skipped),
   replace the literal origin abspath → target abspath.
6. **Safety guard (the core invariant).** Before writing any target path, require
   `git -C "$TARGET" check-ignore -q "$relpath"`. If the path is *not* gitignored in the
   target, skip and warn. This guarantees the sync can never create a tracked-file diff or
   even an untracked-file entry in `git status`.

## Triggers

- **On demand:** the skill runs the script against the current worktree.
- **Automatic:** the skill can install a shared `post-checkout` hook
  (`$(git rev-parse --git-common-dir)/hooks/post-checkout`) that runs the script on every
  worktree checkout. Idempotent; only acts inside non-main worktrees.

## Components (independently testable)

| Unit | Responsibility |
|---|---|
| resolver | origin/target worktree paths |
| enumerator | gitignored candidates + skip-list filter |
| copier | absent-or-newer copy |
| rewriter | origin→target abspath substitution in text files |
| guard | `check-ignore` gate → zero-diff invariant |
| hook installer | shared post-checkout wiring |

## Proof

`simulate.sh` builds a throwaway git repo with a Rails-like gitignored layout, creates a
worktree, asserts the breakage (missing `.env`, baked path), runs the script, then asserts:
(a) `.env` now present, (b) baked path rewritten to the worktree path, (c) `master.key`
copied verbatim, (d) heavy dirs skipped, (e) `git status` still clean in both worktrees.
