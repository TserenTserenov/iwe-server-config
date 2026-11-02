#!/usr/bin/env bash
# WP-484 Ф282 measure 4: iwe-version.sh, called without an argument by
# session-guard open/close, compares the root scripts with the iwe-local-config
# main branch known on the host and names files the last delivery held back.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/iwe-version.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/iwe-version-smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

# iwe-local-config clone whose origin/main is at NEW; OLD is its parent.
g init -q --bare "$T/remote.git"
g clone -q "$T/remote.git" "$T/seed" 2>/dev/null
g -C "$T/seed" commit -q --allow-empty -m old
OLD=$(git -C "$T/seed" rev-parse HEAD)
g -C "$T/seed" commit -q --allow-empty -m new
NEW=$(git -C "$T/seed" rev-parse HEAD)
g -C "$T/seed" push -q origin HEAD:main

host() {  # <dir> -- a fresh IWE root with an iwe-local-config clone
  mkdir -p "$1/.iwe-runtime"
  g clone -q "$T/remote.git" "$1/iwe-local-config" 2>/dev/null
}
receipt() {  # <root> <root_commit> [excluded-json-array]
  printf '{"root_commit": "%s", "config_revision": "c", "root_commit_excluded": %s}\n' \
    "$2" "${3:-[]}" > "$1/.iwe-runtime/iwe-release.json"
}
run() { IWE_ROOT="$1" bash "$SCRIPT" 2>/dev/null; }

host "$T/h1"; receipt "$T/h1" "$NEW"
out=$(run "$T/h1")
{ grep -q "checkout=ok" <<<"$out" && ! grep -q "⚠️" <<<"$out"; } \
  && ok "receipt at origin/main: ok, no warning" || bad "current receipt: $out"

host "$T/h2"; receipt "$T/h2" "$OLD"
out=$(run "$T/h2")
{ grep -q "checkout=stale" <<<"$out" && grep -q "Корневые скрипты этого хоста на ${OLD:0:12}" <<<"$out"; } \
  && ok "receipt behind origin/main: stale warning on stdout" || bad "stale receipt: $out"

host "$T/h3"; receipt "$T/h3" "$NEW" '["server-extensions/scripts/session-guard.sh"]'
out=$(run "$T/h3")
grep -q "задержала файлы.*server-extensions/scripts/session-guard.sh" <<<"$out" \
  && ok "held-back files are named" || bad "excluded list: $out"

# Mac shape: no receipt, the root itself is a git checkout behind origin/main.
host "$T/h4"; g clone -q "$T/remote.git" "$T/h4-root" 2>/dev/null
g -C "$T/h4-root" reset -q --hard "$OLD"
mv "$T/h4/iwe-local-config" "$T/h4-root/"; rm -rf "$T/h4/.iwe-runtime"
out=$(run "$T/h4-root")
grep -q "checkout=stale" <<<"$out" && ok "git-checkout root behind origin/main: stale" || bad "git root: $out"

# The host clone fetched before the root moved on: root ahead of its origin/main.
host "$T/h6"; git -C "$T/h6/iwe-local-config" update-ref refs/remotes/origin/main "$OLD"; receipt "$T/h6" "$NEW"
out=$(run "$T/h6")
{ grep -q "checkout=ok" <<<"$out" && ! grep -q "⚠️" <<<"$out"; } \
  && ok "root ahead of a stale clone ref: ok, no warning" || bad "root ahead: $out"

# A root commit the clone has never seen cannot be judged: unknown, no warning.
host "$T/h7"; receipt "$T/h7" "$(printf '%040d' 7)"
out=$(run "$T/h7")
{ grep -q "checkout=unknown" <<<"$out" && ! grep -q "⚠️" <<<"$out"; } \
  && ok "root unknown to the clone: unknown, no warning" || bad "unknown root: $out"

mkdir -p "$T/h5"
out=$(run "$T/h5")
grep -q "release=unknown" <<<"$out" && ok "no receipt, no git: unknown" || bad "bare root: $out"

echo "iwe-version smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
