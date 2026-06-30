#!/usr/bin/env bash
#
# test-global-hook.sh — proves --install-global-hook / --uninstall-global-hook in a
# FULLY ISOLATED sandbox. Overrides HOME so the real ~/.gitconfig is never touched.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"

SB="$(mktemp -d "${TMPDIR:-/tmp}/wtglobal.XXXXXX")"; SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT

# isolate ALL git global state into the sandbox
export HOME="$SB"
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL 2>/dev/null || true
git config --global user.email sim@test.local
git config --global user.name  sim
git config --global init.defaultBranch main

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
ck(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

mk_repo() {  # $1=path ; origin repo with a gitignored .env carrying a baked path
  local r="$1"; mkdir -p "$r"; git -C "$r" init -q
  printf '/.env\n' > "$r/.gitignore"; echo x > "$r/f"
  git -C "$r" add -A; git -C "$r" commit -qm init
  printf 'SECRET=%s/secrets\n' "$r" > "$r/.env"
}

GDIR="$SB/.config/git/hooks"

echo "== 1. install global hook =="
bash "$SCRIPT" --install-global-hook >/dev/null 2>&1
ck "global post-checkout hook created"        '[[ -x "$GDIR/post-checkout" ]]'
ck "core.hooksPath points at it"              '[[ "$(git config --global core.hooksPath)" == "$GDIR" ]]'

echo "== 2. new worktree auto-syncs via global hook =="
mk_repo "$SB/proj"
git -C "$SB/proj" worktree add -q -b feat "$SB/proj-feat" >/dev/null 2>&1
ck ".env synced into new worktree"            '[[ -f "$SB/proj-feat/.env" ]]'
ck ".env path rewritten to the worktree"      'grep -qF "SECRET=$SB/proj-feat/secrets" "$SB/proj-feat/.env"'
ck "new worktree git status clean"            '[[ -z "$(git -C "$SB/proj-feat" status --porcelain)" ]]'

echo "== 3. chains repo-local post-checkout (not bypassed by core.hooksPath) =="
RLH="$SB/proj/.git/hooks/post-checkout"   # absolute (rev-parse --git-common-dir is relative from main)
printf '#!/usr/bin/env bash\ntouch "%s/repo-local-ran"\n' "$SB" > "$RLH"; chmod +x "$RLH"
git -C "$SB/proj" worktree add -q -b feat2 "$SB/proj-feat2" >/dev/null 2>&1
ck "repo-local hook still ran (chained)"      '[[ -f "$SB/repo-local-ran" ]]'
ck "and .env still synced"                    '[[ -f "$SB/proj-feat2/.env" ]]'

echo "== 4. normal (non-worktree) checkout is a silent safe no-op =="
out="$(cd "$SB/proj" && git checkout -q -b other 2>&1; git checkout -q main 2>&1 || true)"
ck "no noise on ordinary branch switch"       '[[ -z "$out" ]]'

echo "== 5. idempotent re-install =="
bash "$SCRIPT" --install-global-hook >/dev/null 2>&1
ck "no spurious .prev created on re-install"  '[[ ! -e "$GDIR/post-checkout.prev" ]]'
ck "hook still present"                        '[[ -x "$GDIR/post-checkout" ]]'

echo "== 6. uninstall restores clean state =="
bash "$SCRIPT" --uninstall-global-hook >/dev/null 2>&1
ck "core.hooksPath unset"                      '[[ -z "$(git config --global core.hooksPath || true)" ]]'
ck "our hook removed"                          '[[ ! -e "$GDIR/post-checkout" ]]'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
