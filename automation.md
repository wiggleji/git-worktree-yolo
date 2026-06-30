# Automatic invocation

`git-worktree-yolo` is designed to run **automatically** when you (or an agent) enter a worktree,
not to be invoked by hand. Pick the trigger that fits how worktrees are created in your team.

The script is **idempotent** — running it on an already-synced worktree is a no-op — so it is
safe to fire on every session start (even on resume/compact).

## Option A — Claude Code hook (team-wide, zero per-developer install) ✅ recommended

Hooks committed in `.claude/settings.json` are shared with everyone who clones the repo — no
`core.hooksPath` opt-in, unlike git's `.git/hooks`. A `SessionStart` hook fires for every
session, including sessions that begin inside a worktree.

Commit the skill into the repo at `.claude/skills/git-worktree-yolo/`, then add to
`.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh\" \"$PWD\" || true" }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          { "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/skills/git-worktree-yolo/git-worktree-yolo.sh\" \"$PWD\" || true" }
        ]
      }
    ]
  }
}
```

- `${CLAUDE_PROJECT_DIR}` resolves to the repo root regardless of where Claude was launched.
- `|| true` keeps a sync hiccup from blocking the session; the script is already a safe no-op
  in the main worktree.
- **Why both events:** `SessionStart` covers interactive and worktree sessions. Whether it also
  fires inside Task-dispatched **subagents** is undocumented, so `SubagentStart` is added to
  guarantee an agent spawned straight into a worktree self-heals. (If your Claude Code version
  doesn't support `SubagentStart`, drop that block — `SessionStart` still covers the common case.)

## Option B — git post-checkout hook (universal, per-clone install)

Fires on every `git worktree add` from any tool (CLI, IDEs, scripts). Not specific to Claude.
Because git never clones `.git/hooks`, each developer runs this once per clone:

```bash
bash .claude/skills/git-worktree-yolo/git-worktree-yolo.sh --install-hook
```

This writes a shared `post-checkout` hook into the common git dir (covers all worktrees).

## Which to use

| Situation | Use |
|---|---|
| Team uses Claude Code agents in worktrees | **Option A** (committed hook, no install) |
| Worktrees created via raw `git worktree add` outside Claude | **Option B** |
| Belt-and-suspenders | Both — the script is idempotent, double-firing is harmless |

> Note: the docs don't confirm whether Claude's *internal* worktree creation triggers git's
> `post-checkout`. Option A's session hooks don't depend on that, which is why they're the
> reliable default.
