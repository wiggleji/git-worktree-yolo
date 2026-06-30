#!/usr/bin/env bash
#
# test-multistack.sh — proves stack/IDE detection, the in-session report, recreate
# guidance, the .worktree-yolo manifest, and --bootstrap. Fully isolated.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wtms.XXXXXX")"; SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
# hermetic: ignore the user's global git config (e.g. an installed global post-checkout hook)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
ck(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

O="$SB/polyglot"; WT="$SB/polyglot-feat"
mkdir -p "$O"/{ios,android/app,.idea,vendor,extra,config,node_modules/x,ios/Pods/y,.gradle}
git -C "$O" init -q; git -C "$O" config user.email s@t; git -C "$O" config user.name s

cat > "$O/.gitignore" <<'G'
/.env
/local.properties
/.idea/workspace.xml
/node_modules/
/ios/Pods/
/.gradle/
/vendor/
/extra/
/config/secret.token
*.keystore
G
# tracked stack markers (so detection has something after checkout)
printf '{ "dependencies": { "react-native": "0.73" } }\n' > "$O/package.json"
echo "platform :ios"            > "$O/ios/Podfile"
echo "// gradle"                > "$O/build.gradle"
echo "// app gradle"            > "$O/android/app/build.gradle"
echo "App"                      > "$O/App.js"
cat > "$O/.worktree-yolo" <<'C'
# team manifest
sync vendor/keep.token
skip extra
recreate fake_dep -- touch BOOTSTRAPPED.marker
C
git -C "$O" add -A; git -C "$O" commit -qm init

# machine-local (gitignored) files
echo "API=$O/api"                         > "$O/.env"
echo "sdk.dir=/Users/dev/Library/Android/sdk" > "$O/local.properties"   # machine path, must NOT be rewritten
printf '\x00\x01keystorebytes\xff'        > "$O/android/app/release.keystore"
printf '<project><property name="x" value="%s"/></project>\n' "$O" > "$O/.idea/workspace.xml"
echo "force-include-me"                   > "$O/vendor/keep.token"      # normally skipped (vendor), manifest force-syncs
echo "should-not-sync"                    > "$O/extra/local.conf"       # manifest skips
echo "tok"                                > "$O/config/secret.token"
echo "junk" > "$O/node_modules/x/a.js"; echo "pod" > "$O/ios/Pods/y/b.rb"; echo "g" > "$O/.gradle/cache"

git -C "$O" worktree add -q -b feat "$WT" >/dev/null 2>&1

echo "== run sync, capture report =="
REPORT="$("$SCRIPT" "$WT" 2>&1 || true)"
printf '%s\n' "$REPORT" | sed 's/^/    | /'

echo "== detection / report =="
ck "report shows React Native"   'grep -q "React Native" <<<"$REPORT"'
ck "report shows iOS"            'grep -q "iOS" <<<"$REPORT"'
ck "report shows Android"        'grep -q "Android" <<<"$REPORT"'
ck "report shows JetBrains IDE"  'grep -q "JetBrains" <<<"$REPORT"'

echo "== synced machine-local env =="
ck ".env synced + rewritten"     'grep -qF "API=$WT/api" "$WT/.env"'
ck "local.properties synced"     '[[ -f "$WT/local.properties" ]]'
ck "local.properties sdk.dir NOT rewritten (machine path)" 'grep -qF "sdk.dir=/Users/dev/Library/Android/sdk" "$WT/local.properties"'
ck "keystore synced VERBATIM"    'cmp -s "$O/android/app/release.keystore" "$WT/android/app/release.keystore"'
ck "idea workspace.xml rewritten" 'grep -qF "value=\"$WT\"" "$WT/.idea/workspace.xml"'

echo "== manifest sync/skip =="
ck "manifest force-sync vendor/keep.token (normally skipped)" '[[ -f "$WT/vendor/keep.token" ]]'
ck "manifest skip excludes extra/local.conf"                  '[[ ! -e "$WT/extra/local.conf" ]]'

echo "== heavy dirs skipped =="
ck "node_modules NOT copied"     '[[ ! -e "$WT/node_modules" ]]'
ck "ios/Pods NOT copied"         '[[ ! -e "$WT/ios/Pods" ]]'
ck ".gradle NOT copied"          '[[ ! -e "$WT/.gradle" ]]'

echo "== recreate guidance =="
ck "guidance suggests npm"       'grep -qiE "npm (ci|install)" <<<"$REPORT"'
ck "guidance suggests pod install" 'grep -q "pod install" <<<"$REPORT"'
ck "guidance includes manifest recreate (fake_dep)" 'grep -q "BOOTSTRAPPED.marker" <<<"$REPORT"'

echo "== zero git diff =="
ck "worktree git status clean"   '[[ -z "$(git -C "$WT" status --porcelain)" ]]'

echo "== --bootstrap runs commands (isolated minimal repo) =="
M="$SB/mini"; MW="$SB/mini-feat"; mkdir -p "$M"; git -C "$M" init -q
git -C "$M" config user.email s@t; git -C "$M" config user.name s
printf '/.env\n' > "$M/.gitignore"; echo x > "$M/f"
printf 'recreate fake_dep -- touch DID_BOOTSTRAP.marker\n' > "$M/.worktree-yolo"
git -C "$M" add -A; git -C "$M" commit -qm init
echo "E=1" > "$M/.env"
git -C "$M" worktree add -q -b feat "$MW" >/dev/null 2>&1
"$SCRIPT" --bootstrap "$MW" >/dev/null 2>&1 || true
ck "--bootstrap executed manifest recreate command" '[[ -f "$MW/DID_BOOTSTRAP.marker" ]]'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
