#!/usr/bin/env bash
# Regression for the isolated-copy and directory-search branches of
# .claude/hooks/wp-card-read-gate.sh (WP-484 F257 M5), on real git repositories:
#   - an isolated copy whose card is behind the server is denied, a fresh or ahead one
#     is allowed (with a note), an unknown freshness is logged as unresolved, never "fresh";
#   - a Grep over a card directory is judged by path and glob together;
#   - a symlink to a stale copy is resolved before the copy is judged;
#   - the journal records whether a subagent id reached the hook.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/wp-card-read-gate.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect() {  # expect <name> <allow|deny> <payload-json>
  local out decision
  out="$(printf '%s' "$3" | IWE_ROOT="$IWE" bash "$HOOK" 2>/dev/null)"
  if [ -z "$out" ]; then decision=allow; else
    decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"
  fi
  [ "$decision" = "$2" ] && ok || bad "$1 (ожидалось $2, получено $decision)"
}
last_log() { tail -1 "$IWE/.claude/logs/wp-card-read-gate.jsonl" 2>/dev/null; }
read_payload() { jq -nc --arg f "$1" --arg c "${2:-}" '{tool_name:"Read", session_id:"t", tool_input:{file_path:$f}, cwd:$c}'; }
grep_payload() { jq -nc --arg p "$1" --arg g "$2" --arg c "$3" '{tool_name:"Grep", session_id:"t", tool_input:({pattern:"x"} + (if $p=="" then {} else {path:$p} end) + (if $g=="" then {} else {glob:$g} end)), cwd:$c}'; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wp-card-read-gate-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
IWE="$TMP/iwe"
mkdir -p "$IWE/scripts/lib" "$IWE/.iwe-runtime/isolated-worktrees"
cp "$ROOT/scripts/lib/git-sync-status.sh" "$ROOT/scripts/lib/find-python3.sh" "$IWE/scripts/lib/"
export WP_CARD_READ_GATE_CACHE_TTL=0

git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/seed" 2>/dev/null
git -C "$TMP/seed" config user.email t@example.com
git -C "$TMP/seed" config user.name test
git -C "$TMP/seed" checkout -q -b main
mkdir -p "$TMP/seed/inbox/WP-9"
printf '# WP-9\n\n## Осталось\n\n**Следующий шаг:** Ф1 — база\n' >"$TMP/seed/inbox/WP-9/WP-9.md"
git -C "$TMP/seed" add -A && git -C "$TMP/seed" commit -q -m base && git -C "$TMP/seed" push -q origin main 2>/dev/null

git clone -q "$TMP/origin.git" "$IWE/DS-test" 2>/dev/null
git -C "$IWE/DS-test" config user.email t@example.com
git -C "$IWE/DS-test" config user.name test
CARD="inbox/WP-9/WP-9.md"
ISO="$IWE/.iwe-runtime/isolated-worktrees"
git -C "$IWE/DS-test" worktree add -q -b iso-fresh "$ISO/fresh" origin/main 2>/dev/null
git -C "$IWE/DS-test" worktree add -q -b iso-old "$ISO/old" origin/main 2>/dev/null
git -C "$IWE/DS-test" worktree add -q -b iso-ahead "$ISO/ahead" origin/main 2>/dev/null

# 1. everything in sync: canon, fresh copy, directory search are allowed
expect "канон в синхроне" allow "$(read_payload "$IWE/DS-test/$CARD")"
expect "свежая копия" allow "$(read_payload "$ISO/fresh/$CARD")"
expect "поиск по каталогу карточек в синхроне" allow "$(grep_payload "$IWE/DS-test/inbox" "" "$IWE/DS-test")"

# 2. the server moves on and the object is NOT local: freshness is unknown, not "fresh"
git -C "$TMP/seed" pull -q origin main 2>/dev/null
printf '**Следующий шаг:** Ф2 — новое с сервера\n' >>"$TMP/seed/$CARD"
git -C "$TMP/seed" commit -q -am newer && git -C "$TMP/seed" push -q origin main 2>/dev/null
expect "объекта сервера нет локально: не deny" allow "$(read_payload "$ISO/old/$CARD")"
LAST="$(last_log)"
printf '%s' "$LAST" | jq -e '.decision == "unresolved" and (.detail | contains("свежесть неизвестна"))' >/dev/null && ok || bad "unknown -> unresolved в журнале: $LAST"

# 3. the object arrives: the old copy is stale -> deny; fresh-by-newest copy is not
git -C "$IWE/DS-test" fetch -q origin 2>/dev/null
expect "отстающая изолированная копия" deny "$(read_payload "$ISO/old/$CARD")"
LAST="$(last_log)"
printf '%s' "$LAST" | jq -e '.decision == "deny" and (.detail | contains("копия отстаёт"))' >/dev/null && ok || bad "deny записан в журнал: $LAST"
git -C "$IWE/DS-test" worktree add -q -b iso-new "$ISO/new" origin/main 2>/dev/null
expect "копия, созданная от свежего сервера" allow "$(read_payload "$ISO/new/$CARD")"

# 4. ahead of the server with its own commit, and fresh base with an uncommitted edit
git -C "$ISO/new" config user.email t@example.com
git -C "$ISO/new" config user.name test
printf 'правка копии\n' >>"$ISO/new/$CARD"
expect "свежая база и правка в работе" allow "$(read_payload "$ISO/new/$CARD")"
printf '%s' "$(last_log)" | jq -e '.detail | contains("правка в работе")' >/dev/null && ok || bad "пометка 'правка в работе'"
git -C "$ISO/new" commit -q -am own
expect "копия впереди сервера своими коммитами" allow "$(read_payload "$ISO/new/$CARD")"
printf '%s' "$(last_log)" | jq -e '.detail | contains("впереди")' >/dev/null && ok || bad "пометка 'впереди'"

# 5. directory searches: path and glob are judged together
expect "поиск по inbox устаревшей копии" deny "$(grep_payload "$ISO/old/inbox" "" "$ISO/old")"
expect "поиск от корня копии без glob не блокируется" allow "$(grep_payload "" "" "$ISO/old")"
expect "поиск с карточным glob" deny "$(grep_payload "$ISO/old" "WP-*.md" "$ISO/old")"
expect "поиск по коду (glob не карточный) вне карточек" allow "$(grep_payload "$ISO/old" "*.py" "$ISO/old")"
expect "поиск по свежей копии" allow "$(grep_payload "$ISO/new/inbox" "" "$ISO/new")"

# 6. a symlink to the stale copy is resolved before judging
ln -s "$ISO/old" "$TMP/link-to-old"
expect "симлинк на устаревшую копию" deny "$(read_payload "$TMP/link-to-old/$CARD")"
expect "путь с .. в устаревшую копию" deny "$(read_payload "$ISO/fresh/../old/$CARD")"

# 7. the journal says whether a subagent id reached the hook
SUB="$(jq -nc --arg f "$ISO/old/$CARD" '{tool_name:"Read", session_id:"t", agent_id:"sub-123", agent_type:"general-purpose", tool_input:{file_path:$f}}')"
printf '%s' "$SUB" | IWE_ROOT="$IWE" bash "$HOOK" >/dev/null 2>&1
printf '%s' "$(last_log)" | jq -e '.agent_id == "sub-123" and .agent_type == "general-purpose" and (.payload_keys | index("agent_id"))' >/dev/null \
  && ok || bad "agent_id и ключи входа в журнале: $(last_log)"

echo "wp-card-read-gate isolate smoke: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
