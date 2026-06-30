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
# SAFETY FIRST: this tool only ever writes gitignored files (zero git diff), refuses to place
# a secret where it isn't gitignored, audits the repo for committable secrets on every run,
# and can install a pre-commit hook that BLOCKS committing env/secret files.
#
# Usage:
#   git-worktree-yolo.sh [TARGET_DIR]          # sync + stack/IDE report + secret audit
#   git-worktree-yolo.sh --dry-run [TARGET_DIR]# preview only
#   git-worktree-yolo.sh --bootstrap [TARGET_DIR] # also RUN the dep install commands
#   git-worktree-yolo.sh --audit [TARGET_DIR]  # scan for committable secrets (exit 1 if any tracked)
#   git-worktree-yolo.sh --quiet [TARGET_DIR]  # silent unless something is synced (for hooks)
#   git-worktree-yolo.sh --install-hook        # per-repo hooks (post-checkout sync + pre-commit guard)
#   git-worktree-yolo.sh --install-global-hook # GLOBAL hooks (all repos): sync + secret-commit guard
#   git-worktree-yolo.sh --uninstall-global-hook
#   git-worktree-yolo.sh --install-guard       # GLOBAL secret-commit guard ONLY (no auto-sync)
#   git-worktree-yolo.sh --uninstall-guard
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

# --- SECRETS: the #1 safety concern — these must NEVER be committed -----------
# Basename globs treated as secrets. Committing any of these is a leak.
SECRET_NAMES=(
  ".env" ".env.*" ".envrc"
  "*.pem" "*.key" "*.keystore" "*.jks" "*.p12" "*.pfx"
  "id_rsa" "id_dsa" "id_ecdsa" "id_ed25519" "*.ppk"
  "master.key" "credentials.json" "service-account*.json" "*serviceaccount*.json"
  "secrets.yml" "secrets.yaml" "secring.*"
)
# Safe exceptions — templates/examples/public keys are meant to be committed.
SECRET_ALLOW=(
  "*.example" "*.sample" "*.template" "*.dist" "*.enc" "*.pub"
  ".env.example" ".env.sample" ".env.template" ".env.dist" ".env.*.example"
)

# Per-repo manifest (committed at repo root). Populated by load_config().
CONFIG_SYNC=()      # globs to force-include even if the skip-list would drop them
CONFIG_SKIP=()      # extra paths/globs to skip
CONFIG_RECREATE=()  # "depdir|||command" entries; emitted if depdir missing in target
CONFIG_SECRET=()    # extra secret globs to guard
CONFIG_ALLOW=()     # globs explicitly allowed to be committed (override secret guard)

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
    --install-guard)         ACTION="install-guard" ;;
    --uninstall-guard)       ACTION="uninstall-guard" ;;
    --audit)                 ACTION="audit" ;;
    --pre-commit-guard)      ACTION="pre-commit-guard" ;;   # internal: invoked by the hook
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
crit() { printf '\033[1;31m‼ SECRET:\033[0m %s\n' "$*" >&2; }   # always shown (even --quiet)

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

# --- SECRET classification ----------------------------------------------------
# A path is a secret if its basename matches a secret glob AND not an allow glob.
is_allowed() {
  local base="${1##*/}" g
  for g in "${SECRET_ALLOW[@]}" ${CONFIG_ALLOW[@]+"${CONFIG_ALLOW[@]}"}; do
    # shellcheck disable=SC2053
    [[ "$base" == $g || "$1" == $g ]] && return 0
  done
  return 1
}
is_secret() {
  local base="${1##*/}" g
  is_allowed "$1" && return 1
  for g in "${SECRET_NAMES[@]}" ${CONFIG_SECRET[@]+"${CONFIG_SECRET[@]}"}; do
    # shellcheck disable=SC2053
    [[ "$base" == $g ]] && return 0
  done
  return 1
}

# --- audit a repo dir for secrets at risk of being committed ------------------
# CRITICAL: a secret already TRACKED by git (it's in history / will commit).
# WARNING:  a secret in the working tree that is NOT gitignored (a `git add -A` traps it).
# Returns the number of CRITICAL findings.
audit_secrets() {
  local dir="$1" label="$2" rel crit_n=0 warn_n=0
  # tracked secrets — already committed, the worst case
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    is_secret "$rel" && { crit "$label: '$rel' is TRACKED by git — it is (or will be) committed."; crit_n=$((crit_n+1)); }
  done < <(git -C "$dir" ls-files 2>/dev/null)
  # untracked + not-ignored secrets — one `git add -A` away from a leak
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if is_secret "$rel"; then
      warn "$label: '$rel' is NOT gitignored — add it to .gitignore so it can never be committed."
      warn_n=$((warn_n+1))
    fi
  done < <(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)
  [[ "$crit_n" -gt 0 ]] && crit "$label: $crit_n tracked secret(s) — remove with: git rm --cached <file>  (then commit & rotate them)"
  return "$crit_n"
}

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
    if is_secret "$rel"; then
      crit "refusing to place secret '$rel' in the worktree — it is NOT gitignored there, so"
      crit "syncing it would risk a commit. Add it to .gitignore first, then re-run."
    else
      warn "skip (not gitignored in target, would create a diff): $rel"
    fi
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
      sync)   CONFIG_SYNC+=("$rest") ;;
      skip)   CONFIG_SKIP+=("$rest") ;;
      secret) CONFIG_SECRET+=("$rest") ;;
      allow)  CONFIG_ALLOW+=("$rest") ;;
      recreate)
        if [[ "$rest" == *" -- "* ]]; then
          dir="${rest%% -- *}"; cmd="${rest#* -- }"
          CONFIG_RECREATE+=("${dir}|||${cmd}")
        fi ;;
    esac
  done < "$f"
  local n=$(( ${#CONFIG_SYNC[@]} + ${#CONFIG_SKIP[@]} + ${#CONFIG_RECREATE[@]} + ${#CONFIG_SECRET[@]} + ${#CONFIG_ALLOW[@]} ))
  [[ "$n" -gt 0 ]] && log "loaded .worktree-yolo (${#CONFIG_SYNC[@]} sync · ${#CONFIG_SKIP[@]} skip · ${#CONFIG_RECREATE[@]} recreate · ${#CONFIG_SECRET[@]} secret · ${#CONFIG_ALLOW[@]} allow)"
  return 0   # IMPORTANT: never let the last command's status leak out under `set -e`
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

  # SAFETY (most important): never let env/secret values reach a commit.
  audit_secrets "$TARGET" "worktree" || true
}

# --- secret-commit guard (invoked by the pre-commit hook) -----------------------
# Blocks a commit that stages any env/secret file. The teeth of "never commit secrets".
pre_commit_guard() {
  TARGET="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  local common; common="$(git rev-parse --git-common-dir)"
  case "$common" in /*) : ;; *) common="$TARGET/$common" ;; esac
  ORIGIN="$(cd "$(dirname "$common")" && pwd)"
  load_config
  local rel offenders=()
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    is_secret "$rel" && offenders+=("$rel")
  done < <(git diff --cached --name-only --diff-filter=AM 2>/dev/null)
  [[ "${#offenders[@]}" -eq 0 ]] && exit 0
  crit "COMMIT BLOCKED — these staged files look like secrets and must never be committed:"
  local f; for f in "${offenders[@]}"; do printf '      \033[1;31m%s\033[0m\n' "$f" >&2; done
  crit "fix:  git rm --cached <file>  then add it to .gitignore  (rotate it if already pushed)"
  crit "safe on purpose?  allow it in .worktree-yolo ('allow <glob>')  or bypass: git commit --no-verify"
  exit 1
}

# --- standalone audit: scan a repo for committable secrets ----------------------
do_audit() {
  resolve_worktrees
  load_config
  info "secret audit · $(basename "$TARGET")"
  local n=0
  audit_secrets "$TARGET" "repo" || n=$?
  if [[ "$n" -eq 0 ]]; then info "✓ no committed secrets detected."; else exit 1; fi
}

# --- shared hook helpers --------------------------------------------------------
MARKER="# >>> git-worktree-yolo managed hook >>>"
preserve_existing() {   # move a pre-existing, non-managed hook aside so we can chain it
  local hook="$1"
  if [[ -f "$hook" ]] && ! grep -qF "$MARKER" "$hook"; then
    mv "$hook" "$hook.prev"
    warn "existing $(basename "$hook") preserved as $hook.prev (still runs, chained)"
  fi
}
# post-checkout: auto-sync a new worktree.  $1=dir  $2=1 to chain repo-local hook
write_post_checkout_hook() {
  local dir="$1" chain="$2" hook="$dir/post-checkout"
  mkdir -p "$dir"; preserve_existing "$hook"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
$MARKER
# Auto-heals a new git worktree's machine-local env. Safe no-op outside worktrees.
[ "\${3:-1}" = 1 ] && "$SELF" --quiet "\$PWD" || true
[ -x "$hook.prev" ] && "$hook.prev" "\$@"
EOF
  [[ "$chain" == 1 ]] && cat >> "$hook" <<'EOF'
__rl="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/post-checkout"
[ -x "$__rl" ] && [ ! "$__rl" -ef "$0" ] && "$__rl" "$@"
EOF
  echo 'exit 0' >> "$hook"; chmod +x "$hook"
}
# pre-commit: BLOCK committing secrets.  $1=dir  $2=1 to chain repo-local hook
write_pre_commit_hook() {
  local dir="$1" chain="$2" hook="$dir/pre-commit"
  mkdir -p "$dir"; preserve_existing "$hook"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
$MARKER
# Blocks committing env/secret files. Bypass (discouraged): git commit --no-verify
"$SELF" --pre-commit-guard || exit 1
[ -x "$hook.prev" ] && { "$hook.prev" "\$@" || exit \$?; }
EOF
  [[ "$chain" == 1 ]] && cat >> "$hook" <<'EOF'
__rl="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/pre-commit"
[ -x "$__rl" ] && [ ! "$__rl" -ef "$0" ] && { "$__rl" "$@" || exit $?; }
EOF
  echo 'exit 0' >> "$hook"; chmod +x "$hook"
}
remove_managed_hook() {   # restore .prev or remove, only if the hook is ours
  local dir="$1" name="$2" hook="$1/$2"
  if [[ -f "$hook" ]] && grep -qF "$MARKER" "$hook"; then
    if [[ -f "$hook.prev" ]]; then mv "$hook.prev" "$hook"; info "restored previous $name"
    else rm -f "$hook"; info "removed managed $name"; fi
  elif [[ -e "$hook" ]]; then warn "$name in $dir is not ours — left untouched."; fi
}
hooks_dir_or_default() {   # echo existing global hooksPath (abs) or our default
  local d; d="$(git config --global core.hooksPath || true)"
  if [[ -n "$d" ]]; then case "$d" in "~"*) d="$HOME${d#\~}" ;; esac; printf '%s' "$d"
  else printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks"; fi
}
maybe_unset_hookspath() {
  local dir="$1"
  [[ "$dir" == "${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks" ]] || { warn "left core.hooksPath=$dir as-is (predates this tool)."; return 0; }
  if [[ ! -e "$dir/post-checkout" && ! -e "$dir/pre-commit" ]]; then
    git config --global --unset core.hooksPath || true
    info "unset global core.hooksPath (no managed hooks remain)."
  fi
}

# --- per-repo hooks (this repo's shared git dir only) ---------------------------
install_hook() {
  resolve_worktrees
  local hookdir; hookdir="$(git -C "$TARGET" rev-parse --git-common-dir)/hooks"
  case "$hookdir" in /*) : ;; *) hookdir="$TARGET/$hookdir" ;; esac
  write_post_checkout_hook "$hookdir" 0
  write_pre_commit_hook    "$hookdir" 0
  info "installed per-repo hooks in $hookdir:"
  log  "  post-checkout → auto-sync new worktrees of THIS repo"
  log  "  pre-commit    → block committing env/secret files"
}

# --- global hooks (all repos, via core.hooksPath): sync + secret guard ----------
install_global_hook() {
  local dir was_unset=0
  [[ -z "$(git config --global core.hooksPath || true)" ]] && was_unset=1
  dir="$(hooks_dir_or_default)"
  [[ "$was_unset" == 0 ]] && info "core.hooksPath already set → installing into: $dir"
  write_post_checkout_hook "$dir" 1
  write_pre_commit_hook    "$dir" 1
  if [[ "$was_unset" == 1 ]]; then
    git config --global core.hooksPath "$dir"
    warn "set global core.hooksPath=$dir — git reads hooks from here for ALL repos."
    warn "hooks chain to each repo's .git/hooks, but other hook types there won't run unless copied."
    warn "reverse with: $SELF --uninstall-global-hook"
  fi
  info "GLOBAL hooks installed in $dir:"
  log  "  post-checkout → auto-sync new worktrees (any repo)"
  log  "  pre-commit    → block committing env/secret files (any repo)"
}

# install ONLY the secret-commit guard globally (no auto-sync) --------------------
install_guard() {
  local dir was_unset=0
  [[ -z "$(git config --global core.hooksPath || true)" ]] && was_unset=1
  dir="$(hooks_dir_or_default)"
  write_pre_commit_hook "$dir" 1
  if [[ "$was_unset" == 1 ]]; then
    git config --global core.hooksPath "$dir"
    warn "set global core.hooksPath=$dir (git reads hooks from here for ALL repos)."
  fi
  info "GLOBAL secret-commit guard installed: $dir/pre-commit"
}

uninstall_global_hook() {
  [[ -z "$(git config --global core.hooksPath || true)" ]] && { info "no global core.hooksPath — nothing to uninstall."; exit 0; }
  local dir; dir="$(hooks_dir_or_default)"
  remove_managed_hook "$dir" post-checkout
  remove_managed_hook "$dir" pre-commit
  maybe_unset_hookspath "$dir"
}
uninstall_guard() {
  [[ -z "$(git config --global core.hooksPath || true)" ]] && { info "no global core.hooksPath — nothing to uninstall."; exit 0; }
  local dir; dir="$(hooks_dir_or_default)"
  remove_managed_hook "$dir" pre-commit
  maybe_unset_hookspath "$dir"
}

case "$ACTION" in
  install-hook)          install_hook ;;
  install-global-hook)   install_global_hook ;;
  uninstall-global-hook) uninstall_global_hook ;;
  install-guard)         install_guard ;;
  uninstall-guard)       uninstall_guard ;;
  audit)                 do_audit ;;
  pre-commit-guard)      pre_commit_guard ;;
  sync)                  do_sync ;;
esac
