#!/usr/bin/env bash
#
# git-worktree-yolo.sh — make a git worktree IDE-runnable by mirroring machine-local
# (gitignored) files from the origin worktree and rewriting baked-in origin paths.
# Idempotent: safe to run repeatedly; a synced worktree is a no-op ("you only load once").
#
# Safety invariant: only ever writes paths that are gitignored in the TARGET worktree,
# so it can never produce a `git status` diff (tracked or untracked).
#
# Usage:
#   git-worktree-yolo.sh [TARGET_DIR]          # sync current (or named) worktree
#   git-worktree-yolo.sh --dry-run [TARGET_DIR]# preview only
#   git-worktree-yolo.sh --quiet [TARGET_DIR]  # silent unless something is synced (for hooks)
#   git-worktree-yolo.sh --install-hook        # per-repo post-checkout hook (this repo only)
#   git-worktree-yolo.sh --install-global-hook # GLOBAL post-checkout hook (all repos, via core.hooksPath)
#   git-worktree-yolo.sh --uninstall-global-hook
#
set -euo pipefail

# --- config: heavy / regenerable paths never worth syncing -------------------
# Heavy / regenerable / generated-output dirs — never synced (path-prefix match).
SKIP_DIRS=(
  node_modules tmp log logs coverage vendor .bundle .yarn .pnpm-store
  dist build target .gradle .next out storage public
  .git .idea/shelf
  .claude/worktrees   # nested git worktrees — never recurse-copy these
)
# Generated/junk files — never synced (basename glob match).
# *.iml: JetBrains module files are per-worktree and name-specific (the worktree
# auto-generates its own, e.g. api-server-outbox.iml) — copying origin's would
# corrupt the worktree's project structure.
SKIP_NAMES=( ".DS_Store" "*.log" "*.pid" "*.sock" "*.iml" )
# Exact rel-path skips — JetBrains module index, tied to the *.iml above.
SKIP_PATHS=( ".idea/modules.xml" )
# Size cap: machine-local config is tiny; anything larger is treated as a data
# artifact and skipped. Override with WTSYNC_MAX_BYTES.
MAX_BYTES="${WTSYNC_MAX_BYTES:-1048576}"   # 1 MiB

DRY_RUN=0
QUIET=0
ACTION="sync"
TARGET_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-hook)          ACTION="install-hook" ;;
    --install-global-hook)   ACTION="install-global-hook" ;;
    --uninstall-global-hook) ACTION="uninstall-global-hook" ;;
    --dry-run)               DRY_RUN=1 ;;
    --quiet|-q)              QUIET=1 ;;
    -h|--help)               grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                       TARGET_ARG="$1" ;;
  esac
  shift
done

# In --quiet mode info()/log() are suppressed; warnings always print.
log()  { [[ "$QUIET" == 1 ]] && return 0; printf '  %s\n' "$*" >&2; }
info() { [[ "$QUIET" == 1 ]] && return 0; printf '\033[36m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

# absolute path to this script (for baking into installed hooks)
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --- resolver: origin (main worktree) + target (current worktree) ------------
resolve_worktrees() {
  local start="${TARGET_ARG:-$PWD}"
  [[ -d "$start" ]] || { warn "not a directory: $start"; exit 1; }
  TARGET="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" \
    || { warn "$start is not inside a git repository"; exit 1; }
  # git-common-dir points at the SHARED .git of the main worktree.
  local common; common="$(git -C "$TARGET" rev-parse --git-common-dir)"
  case "$common" in /*) : ;; *) common="$TARGET/$common" ;; esac   # make absolute
  ORIGIN="$(cd "$(dirname "$common")" && pwd)"
}

# --- guard: is REL gitignored in the target worktree? ------------------------
target_ignored() { git -C "$TARGET" check-ignore -q "$1"; }

# --- should REL be skipped (heavy/regenerable dir, or junk basename)? --------
is_skipped() {
  local rel="$1" base="${1##*/}" s n p
  for s in "${SKIP_DIRS[@]}"; do
    [[ "$rel" == "$s" || "$rel" == "$s/"* ]] && return 0
  done
  for p in "${SKIP_PATHS[@]}"; do
    [[ "$rel" == "$p" ]] && return 0
  done
  for n in "${SKIP_NAMES[@]}"; do
    # shellcheck disable=SC2053
    [[ "$base" == $n ]] && return 0
  done
  return 1
}

# --- copier + rewriter for one file ------------------------------------------
sync_file() {
  local rel="$1" src="$ORIGIN/$1" dst="$TARGET/$1"
  [[ -f "$src" ]] || return 0

  # size cap: skip data artifacts (machine-local config is tiny)
  local bytes; bytes="$(wc -c < "$src" 2>/dev/null | tr -d ' ')"
  if [[ -n "$bytes" && "$bytes" -gt "$MAX_BYTES" ]]; then
    SKIPPED+=("$rel"); return 0
  fi

  # invariant: refuse to write anything not gitignored in the target
  if ! target_ignored "$rel"; then
    warn "skip (not gitignored in target, would create a diff): $rel"
    return 0
  fi

  # copy only if absent or origin is newer — never clobber local edits
  if [[ -e "$dst" && ! "$src" -nt "$dst" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    log "would sync: $rel"; SYNCED+=("$rel"); return 0
  fi

  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"

  # rewrite baked-in origin path -> target path, text files only.
  # Boundary-aware: only rewrite ORIGIN when followed by /, quote, space, :, ), > or EOL,
  # so it never corrupts a path that is already the longer worktree form
  # (origin "api-server" is a prefix of worktree "api-server-outbox"). \Q..\E quotes metachars.
  if grep -Iq . "$dst" 2>/dev/null && grep -qF "$ORIGIN" "$dst" 2>/dev/null; then
    ORIG="$ORIGIN" TGT="$TARGET" perl -i -pe \
      's/\Q$ENV{ORIG}\E(?=\/|["'"'"' :\)>]|$)/$ENV{TGT}/g' "$dst"
    log "synced + path-rewritten: $rel"
    REWRITTEN+=("$rel")
  else
    log "synced: $rel"
  fi
  SYNCED+=("$rel")
}

# build a find(1) prune predicate from the skip-list basenames (computed once)
PRUNE_ARGS=()
for _s in "${SKIP_DIRS[@]}"; do PRUNE_ARGS+=( -name "${_s##*/}" -o ); done
PRUNE_ARGS+=( -false )   # close the -o chain

# --- expand one candidate (file, or collapsed dir/) into file rels -----------
# Prints newline-separated rel paths; dedup happens in the caller via sort -u.
emit_candidate() {
  local rel="${1%/}"
  is_skipped "$rel" && return 0
  if [[ -d "$ORIGIN/$rel" ]]; then
    # prune skipped dirs (e.g. nested .claude/worktrees) so we never recurse them
    local f relf
    while IFS= read -r -d '' f; do
      relf="${f#"$ORIGIN/"}"
      is_skipped "$relf" && continue   # backstop: skip-list match per file
      printf '%s\n' "$relf"
    done < <(find "$ORIGIN/$rel" \( "${PRUNE_ARGS[@]}" \) -prune -o -type f -print0)
  else
    printf '%s\n' "$rel"
  fi
}

do_sync() {
  resolve_worktrees
  if [[ "$ORIGIN" == "$TARGET" ]]; then
    info "In the main worktree ($TARGET) — nothing to sync."
    exit 0   # silent under --quiet (the common case when a hook fires on a normal checkout)
  fi
  info "git-worktree-yolo"
  log "origin: $ORIGIN"
  log "target: $TARGET"
  SYNCED=(); REWRITTEN=(); SKIPPED=()
  # Enumerate ignored entries, expand dirs to files, then dedup (git lists both
  # the collapsed dir and individual files) before syncing.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && sync_file "$rel"
  done < <(
    git -C "$ORIGIN" ls-files --others --ignored --exclude-standard --directory \
      | while IFS= read -r c; do [[ -n "$c" ]] && emit_candidate "$c"; done \
      | LC_ALL=C sort -u
  )

  # In quiet (hook) mode, emit a single line only if we actually synced something.
  if [[ "$QUIET" == 1 ]]; then
    [[ "${#SYNCED[@]}" -gt 0 ]] && \
      printf '\033[36mgit-worktree-yolo:\033[0m synced %d file(s) into %s\n' "${#SYNCED[@]}" "$TARGET" >&2
  else
    info "done: ${#SYNCED[@]} synced, ${#REWRITTEN[@]} path-rewritten, heavy/oversized skipped"
  fi
}

# --- shared: write a post-checkout hook into DIR --------------------------------
# Preserves any pre-existing post-checkout (moved to .prev and chained).
# $1 = hooks dir, $2 = 1 to also chain repo-local hooks bypassed by core.hooksPath.
MARKER="# >>> git-worktree-yolo managed hook >>>"
write_post_checkout_hook() {
  local dir="$1" chain_repo_local="$2" hook="$dir/post-checkout"
  mkdir -p "$dir"
  if [[ -f "$hook" ]] && ! grep -qF "$MARKER" "$hook"; then
    mv "$hook" "$hook.prev"
    warn "existing post-checkout preserved as $hook.prev (it will still run, chained)"
  fi
  cat > "$hook" <<EOF
#!/usr/bin/env bash
$MARKER
# Auto-heals a new git worktree's machine-local env. Safe no-op outside worktrees.
# post-checkout args: \$1 prev-HEAD \$2 new-HEAD \$3 flag(1=branch/ref checkout)
[ "\${3:-1}" = 1 ] && "$SELF" --quiet "\$PWD" || true
# chain a previously-installed hook displaced by this one
[ -x "$hook.prev" ] && "$hook.prev" "\$@"
EOF
  if [[ "$chain_repo_local" == 1 ]]; then
    cat >> "$hook" <<'EOF'
# chain the repo-local post-checkout that a global core.hooksPath would bypass
__rl="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/post-checkout"
[ -x "$__rl" ] && [ ! "$__rl" -ef "$0" ] && "$__rl" "$@"
EOF
  fi
  echo 'exit 0' >> "$hook"
  chmod +x "$hook"
}

# --- per-repo hook (this repo's shared git dir only) ----------------------------
install_hook() {
  resolve_worktrees
  local hookdir; hookdir="$(git -C "$TARGET" rev-parse --git-common-dir)/hooks"
  case "$hookdir" in /*) : ;; *) hookdir="$TARGET/$hookdir" ;; esac
  write_post_checkout_hook "$hookdir" 0
  info "installed per-repo post-checkout hook: $hookdir/post-checkout"
  log "every 'git worktree add' in THIS repo will self-sync."
}

# --- global hook (all repos on this machine, via core.hooksPath) ----------------
install_global_hook() {
  local dir existing
  existing="$(git config --global core.hooksPath || true)"
  if [[ -n "$existing" ]]; then
    case "$existing" in "~"*) existing="$HOME${existing#\~}" ;; esac
    dir="$existing"
    info "core.hooksPath already set → installing into existing dir: $dir"
  else
    dir="${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks"
    write_post_checkout_hook "$dir" 1
    git config --global core.hooksPath "$dir"
    info "installed GLOBAL post-checkout hook: $dir/post-checkout"
    warn "set global core.hooksPath=$dir — git now reads hooks from here for ALL repos."
    warn "your hook chains to each repo's .git/hooks/post-checkout, but OTHER hook types"
    warn "(pre-commit, etc.) in .git/hooks will no longer run unless copied here. Reverse with:"
    warn "  $SELF --uninstall-global-hook"
    log "every 'git worktree add' in ANY repo will now self-sync."
    return 0
  fi
  write_post_checkout_hook "$dir" 1
  info "installed GLOBAL post-checkout hook: $dir/post-checkout"
  log "every 'git worktree add' in ANY repo will now self-sync."
}

uninstall_global_hook() {
  local dir; dir="$(git config --global core.hooksPath || true)"
  [[ -z "$dir" ]] && { info "no global core.hooksPath set — nothing to uninstall."; exit 0; }
  case "$dir" in "~"*) dir="$HOME${dir#\~}" ;; esac
  local hook="$dir/post-checkout"
  if [[ -f "$hook" ]] && grep -qF "$MARKER" "$hook"; then
    if [[ -f "$hook.prev" ]]; then mv "$hook.prev" "$hook"; info "restored previous hook: $hook"
    else rm -f "$hook"; info "removed our hook: $hook"; fi
  else
    warn "post-checkout in $dir is not ours — leaving it untouched."
  fi
  # only unset core.hooksPath if WE were the one pointing it at our default dir
  if [[ "$dir" == "${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks" ]]; then
    git config --global --unset core.hooksPath || true
    info "unset global core.hooksPath."
  else
    warn "left core.hooksPath=$dir as-is (it predates this tool)."
  fi
}

case "$ACTION" in
  install-hook)          install_hook ;;
  install-global-hook)   install_global_hook ;;
  uninstall-global-hook) uninstall_global_hook ;;
  sync)                  do_sync ;;
esac
