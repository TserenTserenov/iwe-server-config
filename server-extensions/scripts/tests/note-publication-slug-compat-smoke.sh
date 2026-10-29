#!/usr/bin/env bash
# WP-539 F21 B5: note-publication accepts the dated slug as --session-id only as a
# logged compatibility path. A direct guard id always wins; a slug must match
# exactly one open semaphore of the same agent; everything else keeps refusing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/scripts/session-guard.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.iwe-runtime/sessions"
SHA=$(printf 'a%.0s' $(seq 1 40))
FAIL=0

mk() {  # <agent> <guard id> <wp> <slug>
  printf -- '---\nagent: %s\nwp: %s\nslug: %s\nsession_id: %s\nguard_schema: 1\n' \
    "$1" "$3" "$4" "$2" > "$T/.iwe-runtime/sessions/$1-$2.open"
}
mk claude-code aaaa1111 WP-1 slug-one
mk claude-code bbbb2222 WP-2 slug-two
mk claude-code cccc3333 WP-3 dup-slug
mk claude-code dddd4444 WP-4 dup-slug
# A slug that equals another session's guard id: the direct id must win.
mk claude-code eeee5555 WP-5 aaaa1111
mk codex ffff6666 WP-6 only-codex

OUT=""
RC=0
run() {  # <agent> <--session-id value>; fills OUT and RC
  OUT=$(IWE_ROOT="$T" IWE_AGENT="$1" bash "$GUARD" note-publication "$SHA" \
    --repo nosuchrepo --session-id "$2" 2>&1)
  RC=$?
}
expect_has() {  # <label> <needle>
  case "$OUT" in *"$2"*) ;; *) echo "FAIL: $1: missing '$2' in: $OUT"; FAIL=1 ;; esac
}
expect_lacks() {  # <label> <needle>
  case "$OUT" in *"$2"*) echo "FAIL: $1: unexpected '$2' in: $OUT"; FAIL=1 ;; esac
}
expect_refused() {  # <label>
  [ "$RC" -ne 0 ] || { echo "FAIL: $1: expected a refusal, got exit 0"; FAIL=1; }
}

run claude-code slug-two
expect_has "unique slug" "resolved to 'bbbb2222'"
expect_lacks "unique slug" "нет открытой сессии"

run claude-code bbbb2222
expect_lacks "direct id" "is a slug"
expect_lacks "direct id" "нет открытой сессии"

run claude-code aaaa1111
expect_lacks "id equal to another slug" "is a slug"
expect_lacks "id equal to another slug" "resolved to"

run claude-code bbbb2222
expect_lacks "direct id" "resolved to"

# A closed semaphore is not an open session; odd values never reach a glob or a path.
: > "$T/.iwe-runtime/sessions/claude-code-gggg7777.open.closed"
run claude-code gggg7777
expect_has "closed semaphore" "нет открытой сессии claude-code-gggg7777"
expect_refused "closed semaphore"
for odd in '../x' '*' 'a/b' ''; do
  [ -n "$odd" ] || continue
  run claude-code "$odd"
  expect_lacks "odd value '$odd'" "resolved to"
  expect_refused "odd value '$odd'"
done

run claude-code dup-slug
expect_has "ambiguous slug" "matches 2 open sessions"
expect_refused "ambiguous slug"

run claude-code nonexistent
expect_has "unknown value" "нет открытой сессии claude-code-nonexistent"
expect_refused "unknown value"

run claude-code only-codex
expect_has "other agent's slug" "нет открытой сессии claude-code-only-codex"
expect_refused "other agent's slug"

[ "$FAIL" -eq 0 ] && echo "PASS: note-publication slug compatibility" || exit 1
