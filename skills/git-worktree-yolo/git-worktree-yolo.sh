#!/usr/bin/env bash
#
# git-worktree-yolo.sh — make a git worktree runnable/debuggable by mirroring machine-local
# (gitignored) files from the origin worktree and rewriting baked-in origin paths, then
# guiding (or running) the dependency bootstrap the new worktree needs.
# Idempotent: safe to run repeatedly; a synced worktree is a no-op ("you only load once").
#
# Multi-stack: server (Ruby/Python/Node/Go/Java-Kotlin/.NET/PHP), web (JS/TS), and
# mobile (iOS/CocoaPods, Android/Gradle, React Native, Flutter). Per-repo tuning via a
# committed `.worktree-yolo` manifest (sync/skip/recreate directives).
#
# Safety invariant: only ever writes paths that are gitignored in the TARGET worktree,
# so it can never produce a `git status` diff (tracked or untracked).
#
# Usage:
#   git-worktree-yolo.sh [TARGET_DIR]          # sync current (or named) worktree
#   git-worktree-yolo.sh --dry-run [TARGET_DIR]# preview only
#   git-worktree-yolo.sh --bootstrap [TARGET_DIR] # also RUN the dep install commands
#   git-worktree-yolo.sh --quiet [TARGET_DIR]  # silent unless something is synced (for hooks)
#   git-worktree-yolo.sh --install-hook        # per-repo post-checkout hook (this repo only)
#   git-worktree-yolo.sh --install-global-hook # GLOBAL post-checkout hook (all repos, via core.hooksPath)
#   git-worktree-yolo.sh --uninstall-global-hook
#
set -euo pipefail

# --- config: heavy / regenerable paths never worth syncing -------------------
# Heavy / regenerable / generated-output dirs — never synced (path-prefix match).
# We only ever sync GITIGNORED files, so tracked dirs of the same name are unaffected.
SKIP_DIRS=(
  # JS / TS / web
  node_modules .pnpm-store .yarn bower_components
  .next .nuxt .svelte-kit .turbo .vite .parcel-cache .cache .angular
  # build output / general
  dist build out target dist-ssr coverage .nyc_output
  # Ruby
  vendor .bundle
  # Python
  .venv venv .tox __pycache__ .pytest_cache .mypy_cache .ruff_cache
  # JVM (Gradle/Maven) + .NET
  .gradle bin obj
  # iOS / macOS
  Pods Carthage DerivedData
  # Flutter / Dart
  .dart_tool
  # logs / scratch / generated exports
  tmp log logs storage public
  # vcs / editor / nested worktrees
  .git .idea/shelf .claude/worktrees
)
# Generated/junk files — never synced (basename glob match).
# *.iml: JetBrains module files are per-worktree and name-specific (the worktree
# auto-generates its own, e.g. api-server-outbox.iml) — copying origin's would
# corrupt the worktree's project structure.
SKIP_NAMES=( ".DS_Store" "*.log" "*.pid" "*.sock" "*.iml" "*.xcuserstate" )
# Exact rel-path skips — JetBrains module index, tied to the *.iml above.
SKIP_PATHS=( ".idea/modules.xml" )
# Size cap: machine-local config is tiny; anything larger is treated as a data
# artifact and skipped. Override with WTSYNC_MAX_BYTES.
MAX_BYTES="${WTSYNC_MAX_BYTES:-1048576}"   # 1 MiB

# Per-repo manifest (committed at repo root). Populated by load_config().
CONFIG_SYNC=()      # globs to force-include even if the skip-list would drop them
CONFIG_SKIP=()      # extra paths/globs to skip
CONFIG_RECREATE=()  # "depdir|||command" entries; emitted if depdir missing in target

DRY_RUN=0
QUIET=0
BOOTSTRAP=0
ACTION="sync"
TARGET_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-hook)          ACTION="install-hook" ;;
    --install-global-hook)   ACTION="install-global-hook" ;;
    --uninstall-global-hook) ACTION="uninstall-global-hook" ;;
    --dry-run)               DRY_RUN=1 ;;
    --bootstrap)             BOOTSTRAP=1 ;;
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
  local rel="$1" base="${1##*/}" s n p g
  # manifest force-include wins over every skip rule (still must be gitignored to be written)
  # (bash 3.2 + set -u: guard empty-array expansion with the ${arr[@]+"..."} idiom)
  for g in ${CONFIG_SYNC[@]+"${CONFIG_SYNC[@]}"}; do
    # shellcheck disable=SC2053
    [[ "$rel" == $g || "$base" == $g ]] && return 1
  done
  for g in ${CONFIG_SKIP[@]+"${CONFIG_SKIP[@]}"}; do
    # shellcheck disable=SC2053
    [[ "$rel" == "$g" || "$rel" == "$g/"* || "$base" == $g ]] && return 0
  done
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

# --- per-repo manifest: .worktree-yolo at repo root -----------------------------
# Directives, one per line (blank lines and # comments ignored):
#   sync   <glob>                  force-include a gitignored path the skip-list would drop
#   skip   <path|glob>             never sync this path
#   recreate <depdir> -- <command> if <depdir> is missing in the worktree, suggest <command>
load_config() {
  local f="$ORIGIN/.worktree-yolo"
  [[ -f "$f" ]] || return 0
  local kind rest dir cmd
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                       # strip comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    [[ -z "$line" ]] && continue
    kind="${line%%[[:space:]]*}"
    rest="${line#"$kind"}"; rest="${rest#"${rest%%[![:space:]]*}"}"  # ltrim remainder
    case "$kind" in
      sync) CONFIG_SYNC+=("$rest") ;;
      skip) CONFIG_SKIP+=("$rest") ;;
      recreate)
        if [[ "$rest" == *" -- "* ]]; then
          dir="${rest%% -- *}"; cmd="${rest#* -- }"
          CONFIG_RECREATE+=("${dir}|||${cmd}")
        fi ;;
    esac
  done < "$f"
  [[ "${#CONFIG_SYNC[@]}${#CONFIG_SKIP[@]}${#CONFIG_RECREATE[@]}" != "000" ]] && \
    log "loaded .worktree-yolo (${#CONFIG_SYNC[@]} sync, ${#CONFIG_SKIP[@]} skip, ${#CONFIG_RECREATE[@]} recreate)"
}

# --- detect which dependency bootstraps the worktree needs ----------------------
# Focuses on PER-REPO dep dirs that don't carry over (node_modules, .venv, Pods, ...).
# Globally-cached ecosystems (Gradle ~/.gradle, Maven ~/.m2, Go ~/go, NuGet) are NOT
# nagged about — a worktree shares those caches and works without re-install.
RECREATE=()
have() { [[ -e "$TARGET/$1" ]]; }
add_recreate() { RECREATE+=("$1|||$2"); }   # cmd ||| reason
detect_recreate() {
  local t="$TARGET"
  # JS / TS  (lockfile picks the package manager)
  if [[ -f "$t/package.json" ]] && ! have node_modules; then
    if   [[ -f "$t/pnpm-lock.yaml" ]];   then add_recreate "pnpm install --frozen-lockfile" "node_modules (pnpm)"
    elif [[ -f "$t/yarn.lock" ]];        then add_recreate "yarn install --frozen-lockfile" "node_modules (yarn)"
    elif [[ -f "$t/package-lock.json" ]];then add_recreate "npm ci" "node_modules (npm)"
    else add_recreate "npm install" "node_modules (npm)"; fi
  fi
  # Python
  if [[ -f "$t/pyproject.toml" || -f "$t/requirements.txt" ]] && ! have .venv && ! have venv; then
    if   [[ -f "$t/poetry.lock" ]]; then add_recreate "poetry install" ".venv (poetry)"
    elif [[ -f "$t/uv.lock" ]];     then add_recreate "uv sync" ".venv (uv)"
    elif [[ -f "$t/requirements.txt" ]]; then add_recreate "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" ".venv (pip)"
    else add_recreate "python3 -m venv .venv && .venv/bin/pip install -e ." ".venv (pip)"; fi
  fi
  # PHP / Laravel
  [[ -f "$t/composer.json" ]] && ! have vendor && add_recreate "composer install" "vendor (composer)"
  # iOS / CocoaPods
  [[ -f "$t/Podfile" ]] && ! have Pods && add_recreate "pod install" "Pods (CocoaPods)"
  [[ -f "$t/ios/Podfile" ]] && ! have ios/Pods && add_recreate "(cd ios && pod install)" "ios/Pods (CocoaPods)"
  # Flutter / Dart
  [[ -f "$t/pubspec.yaml" ]] && ! have .dart_tool && add_recreate "flutter pub get" ".dart_tool (Flutter)"
  # Ruby — only when bundler is configured to install into the repo (vendor/bundle)
  if [[ -f "$t/Gemfile" && -f "$t/.bundle/config" ]] && grep -q 'BUNDLE_PATH' "$t/.bundle/config" 2>/dev/null && ! have vendor/bundle; then
    add_recreate "bundle install" "vendor/bundle (bundler)"
  fi
  # manifest-declared extras
  local e dir cmd
  for e in ${CONFIG_RECREATE[@]+"${CONFIG_RECREATE[@]}"}; do
    dir="${e%%|||*}"; cmd="${e#*|||}"
    [[ -n "$dir" ]] && ! have "$dir" && add_recreate "$cmd" "$dir (.worktree-yolo)"
  done
}

emit_recreate() {
  [[ "${#RECREATE[@]}" -eq 0 ]] && return 0
  local e cmd reason
  if [[ "$BOOTSTRAP" == 1 ]]; then
    printf '\033[36mgit-worktree-yolo:\033[0m bootstrapping %d dependency set(s)…\n' "${#RECREATE[@]}" >&2
    for e in "${RECREATE[@]}"; do
      cmd="${e%%|||*}"; reason="${e#*|||}"
      printf '  → %s: %s\n' "$reason" "$cmd" >&2
      ( cd "$TARGET" && eval "$cmd" ) || warn "bootstrap failed for $reason (continuing)"
    done
  elif [[ "$QUIET" == 1 ]]; then
    # compact one-liner for hook output
    local list=""
    for e in "${RECREATE[@]}"; do list+="${list:+; }${e%%|||*}"; done
    printf '\033[36mgit-worktree-yolo:\033[0m worktree still needs: \033[33m%s\033[0m\n' "$list" >&2
  else
    info "next steps — this worktree still needs dependencies installed:"
    for e in "${RECREATE[@]}"; do
      cmd="${e%%|||*}"; reason="${e#*|||}"
      printf '    \033[33m%s\033[0m   # %s\n' "$cmd" "$reason" >&2
    done
    log "(re-run with --bootstrap to execute these automatically)"
  fi
}

# --- detect stacks & IDEs for the in-session report ----------------------------
STACKS=(); IDES=()
join_by() { local sep="$1"; shift; local out="" x; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }
detect_stacks() {
  # detect against ORIGIN (fully-populated main worktree); gitignored markers like
  # .idea/ and local.properties aren't in the fresh worktree yet.
  local t="$ORIGIN"; STACKS=(); IDES=()
  # languages / frameworks (marker files)
  if [[ -f "$t/Gemfile" ]]; then
    { [[ -f "$t/config/application.rb" || -f "$t/bin/rails" ]] && STACKS+=("Rails"); } || STACKS+=("Ruby")
  fi
  if [[ -f "$t/package.json" ]]; then
    local pm=npm; [[ -f "$t/yarn.lock" ]] && pm=yarn; [[ -f "$t/pnpm-lock.yaml" ]] && pm=pnpm
    if   grep -q '"react-native"' "$t/package.json" 2>/dev/null; then STACKS+=("React Native")
    elif grep -q '"next"'         "$t/package.json" 2>/dev/null; then STACKS+=("Next.js($pm)")
    else STACKS+=("Node($pm)"); fi
  fi
  [[ -f "$t/pyproject.toml" || -f "$t/requirements.txt" || -f "$t/setup.py" ]] && STACKS+=("Python")
  [[ -f "$t/go.mod" ]] && STACKS+=("Go")
  [[ -f "$t/pom.xml" ]] && STACKS+=("Maven/JVM")
  if [[ -f "$t/build.gradle" || -f "$t/build.gradle.kts" || -f "$t/settings.gradle" || -f "$t/settings.gradle.kts" ]]; then
    { [[ -f "$t/app/build.gradle" || -f "$t/app/build.gradle.kts" || -f "$t/local.properties" ]] && STACKS+=("Android"); } || STACKS+=("Gradle/JVM")
  elif [[ -f "$t/android/app/build.gradle" || -f "$t/android/build.gradle" || -f "$t/android/local.properties" ]]; then
    STACKS+=("Android")   # React Native / mobile monorepo with native android/ dir
  fi
  ls "$t"/*.sln "$t"/*.csproj >/dev/null 2>&1 && STACKS+=(".NET")
  [[ -f "$t/composer.json" ]] && STACKS+=("PHP")
  { [[ -f "$t/Podfile" || -f "$t/ios/Podfile" ]] && STACKS+=("iOS"); }
  [[ -f "$t/pubspec.yaml" ]] && STACKS+=("Flutter")
  # IDE configs present (the env an IDE needs to open/run the worktree)
  [[ -d "$t/.idea" ]]   && IDES+=("JetBrains")
  [[ -d "$t/.vscode" ]] && IDES+=("VSCode")
  [[ -d "$t/.fleet" ]]  && IDES+=("Fleet")
  [[ -d "$t/.zed" ]]    && IDES+=("Zed")
  [[ -d "$t/.nova" ]]   && IDES+=("Nova")
  ls "$t"/*.xcworkspace >/dev/null 2>&1 && IDES+=("Xcode")
  return 0
}

do_sync() {
  resolve_worktrees
  if [[ "$ORIGIN" == "$TARGET" ]]; then
    info "In the main worktree ($TARGET) — nothing to sync."
    exit 0   # silent under --quiet (the common case when a hook fires on a normal checkout)
  fi
  load_config
  detect_stacks
  local stacks_str ides_str
  stacks_str="$(join_by ' · ' ${STACKS[@]+"${STACKS[@]}"})"
  ides_str="$(join_by ' · ' ${IDES[@]+"${IDES[@]}"})"
  info "git-worktree-yolo · $(basename "$TARGET")"
  [[ -n "$stacks_str" ]] && log "stack:  ${stacks_str}"
  [[ -n "$ides_str" ]]   && log "IDE:    ${ides_str}"
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

  # explicit pass for manifest `sync` entries — these may live inside skip-pruned dirs
  # (e.g. vendor/keep.token) that enumeration never descends into.
  local g
  for g in ${CONFIG_SYNC[@]+"${CONFIG_SYNC[@]}"}; do
    [[ -f "$ORIGIN/$g" ]] && sync_file "$g"
  done

  # In quiet (hook) mode, emit a single summary line only if we synced something.
  if [[ "$QUIET" == 1 ]]; then
    [[ "${#SYNCED[@]}" -gt 0 ]] && \
      printf '\033[36mgit-worktree-yolo:\033[0m %s%s synced %d env file(s)\n' \
        "$(basename "$TARGET")" "${stacks_str:+ [$stacks_str]}" "${#SYNCED[@]}" >&2
  else
    info "done: ${#SYNCED[@]} synced, ${#REWRITTEN[@]} path-rewritten, heavy/oversized skipped"
  fi

  # detect & report (or run) the dependency bootstrap this worktree needs
  detect_recreate
  emit_recreate
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
