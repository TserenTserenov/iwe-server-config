#!/usr/bin/env bash
# test-style-pin.sh — lib/style-pin.sh: a session keeps the pack rules it first saw until the
# pin ages out; a new session or an aged pin sees the new rules; failures fall back to nothing.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/style-pin.sh
. "$HOOK_DIR/lib/style-pin.sh"

FAIL=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; FAIL=1; fi; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q -am "$2"; }

mkdir -p "$ROOT/PACK-rhetoric/pack/language-style/registry" "$ROOT/PACK-digital-platform/pack/dp" "$ROOT/DS-my-strategy"
printf 'print("rules v1")\n' >"$ROOT/$DISPATCHER_REL"
printf 'DP.SC.050: PACK-digital-platform/pack/dp/base.md\nL1.x: DS-my-strategy/a.md\n' \
  >"$ROOT/PACK-rhetoric/pack/language-style/registry/content-sources.yaml"
printf 'base v1\n' >"$ROOT/PACK-digital-platform/pack/dp/base.md"
printf 'not pinned\n' >"$ROOT/PACK-digital-platform/pack/dp/other.md"
for repo in PACK-rhetoric PACK-digital-platform; do
  git -C "$ROOT/$repo" init -q && git -C "$ROOT/$repo" add -A && commit "$ROOT/$repo" init
done

first=$(style_pin_dispatcher "$ROOT" s1)
check "pinned dispatcher runs from the snapshot" "$(python3 "$first")" "rules v1"
pin=$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$first")")")")")
check "platform source named in content-sources is pinned" "$(cat "$pin/PACK-digital-platform/pack/dp/base.md")" "base v1"
check "other platform files are not copied" "$([ -e "$pin/PACK-digital-platform/pack/dp/other.md" ] && echo copied || echo absent)" "absent"
check "non-pack source stays live via link" "$(readlink "$pin/DS-my-strategy")" "$ROOT/DS-my-strategy"

printf 'print("rules v2")\n' >"$ROOT/$DISPATCHER_REL"
commit "$ROOT/PACK-rhetoric" v2
check "same session keeps its rules after the pack moves" "$(python3 "$(style_pin_dispatcher "$ROOT" s1)")" "rules v1"
check "new session sees the new rules" "$(python3 "$(style_pin_dispatcher "$ROOT" s2)")" "rules v2"
touch -t 202001010000 "$ROOT/.claude/state/style-pin-s1"
check "aged pin is refreshed" "$(python3 "$(style_pin_dispatcher "$ROOT" s1)")" "rules v2"

printf 'print("rules draft")\n' >"$ROOT/$DISPATCHER_REL"
check "uncommitted pack edit -> live rules (author sees them at once)" "$(style_pin_dispatcher "$ROOT" s4; echo "rc=$?")" "rc=1"
git -C "$ROOT/PACK-rhetoric" checkout -q -- .
check "pins are never nested by a lost race" "$(find "$ROOT/.iwe-runtime/style-pins" -name '.build.*' | wc -l | tr -d ' ')" "0"

rm -rf "$ROOT/PACK-digital-platform/.git"
check "broken pack gives no pin (caller keeps live)" "$(style_pin_dispatcher "$ROOT" s3 2>/dev/null; echo "rc=$?")" "rc=1"
check "failure is remembered, not retried every turn" "$(cat "$ROOT/.claude/state/style-pin-s3")" "none"
STYLE_PIN=0
check "STYLE_PIN=0 switches pinning off" "$(style_pin_dispatcher "$ROOT" s2; echo "rc=$?")" "rc=1"

exit "$FAIL"
