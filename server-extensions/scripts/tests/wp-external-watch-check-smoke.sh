#!/usr/bin/env bash
# wp-external-watch-check-smoke.sh -- WP-561 Ф74: the bundle helper that shows
# the state of external repositories (release branch, tags, issues, failed
# runs) next to a WP card. Uses a stub `gh` (WP_WATCH_GH) and throwaway git
# repos, no network. Reproduces the 17-18.11.2026 case: the card of the
# template-release WP knew nothing about branch release/v0.42.1 and rc tags.
set -uo pipefail

HELPER="$(cd "$(dirname "$0")/.." && pwd)/wp-external-watch-check.py"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER not found"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
fails=0
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then echo "  ok   $3"; else echo "  FAIL $3 (missing: $2)"; fails=$((fails+1)); fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then echo "  ok   $3"; else echo "  FAIL $3 (unexpectedly present: $2)"; fails=$((fails+1)); fi
}

WS="$SANDBOX/ws"
mkdir -p "$WS/FMT-exocortex-template"
git -C "$WS/FMT-exocortex-template" init -q
git -C "$WS/FMT-exocortex-template" remote add origin "git@github.com:Org/FMT-exocortex-template.git"

# Stub gh: answers come from files in $STUB_DIR so each scenario can change them.
STUB_DIR="$SANDBOX/stub"
mkdir -p "$STUB_DIR"
GH="$SANDBOX/gh"
cat > "$GH" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB_DIR/fail" ] && { echo "bad credentials for token ghp_abcdef1234567890" >&2; exit 1; }
case "$*" in
  *"prefix=refs/tags/"*)  cat "$STUB_DIR/tags.json" ;;
  *"prefix=refs/heads/"*) cat "$STUB_DIR/heads.json" ;;
  "pr list"*)    cat "$STUB_DIR/pulls.json" ;;
  "issue list"*) cat "$STUB_DIR/issues.json" ;;
  "run list"*)   cat "$STUB_DIR/runs.json" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$GH"
export WP_WATCH_GH="$GH" STUB_DIR WP_WATCH_CACHE_DIR="$SANDBOX/cache"

reset_stub() {
  cat > "$STUB_DIR/tags.json" <<'EOF'
{"data":{"repository":{"refs":{"nodes":[
 {"name":"v0.42.1-rc.2","target":{"__typename":"Tag","tagger":{"date":"2026-11-18T07:00:00Z"}}},
 {"name":"v0.42.1-rc.1","target":{"__typename":"Commit","committedDate":"2026-11-17T16:30:00Z"}},
 {"name":"nightly-20261118","target":{"__typename":"Commit","committedDate":"2026-11-18T03:00:00Z"}},
 {"name":"v0.41.0","target":{"__typename":"Commit","committedDate":"2026-10-01T10:00:00Z"}}
]}}}}
EOF
  cat > "$STUB_DIR/heads.json" <<'EOF'
{"data":{"repository":{"refs":{"nodes":[
 {"name":"release/v0.42.1","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}},
 {"name":"release/v0.41.0","target":{"__typename":"Commit","committedDate":"2026-10-02T10:00:00Z"}},
 {"name":"main","target":{"__typename":"Commit","committedDate":"2026-11-18T08:00:00Z"}}
]}}}}
EOF
  echo '[]' > "$STUB_DIR/pulls.json"
  echo '[]' > "$STUB_DIR/issues.json"
  echo '[]' > "$STUB_DIR/runs.json"
  rm -f "$STUB_DIR/fail"
  rm -rf "$SANDBOX/cache"
}

cat > "$SANDBOX/registry.json" <<'EOF'
{"version": 1, "watch": {"529": [{"repo": "FMT-exocortex-template", "branches": ["release/*"], "tags": ["v*"], "keywords": ["0.42"]}]}}
EOF

REVISED="2026-11-17T10:00:00Z"
run() {  # <card text> [wp] [extra args...] -> stdout; drift lines in $SANDBOX/drift
  local text="$1" wp="${2:-529}"
  shift 2 2>/dev/null || shift $#
  printf '%s\n' "$text" > "$SANDBOX/card.md"
  : > "$SANDBOX/drift"
  python3 "$HELPER" "$SANDBOX/card.md" --wp "$wp" --registry "$SANDBOX/registry.json" --revised-at "$REVISED" \
    --workspace "$WS" --drift-file "$SANDBOX/drift" "$@"
}
CARD_OLD=$'---\nwp: 529\n---\n- Ф275 — начать с #1567/#1568'

echo "scenario A: the 17-18.11 case -- card without refs, release branch and rc tags exist"
reset_stub
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "проверить — FMT-exocortex-template: 3 событий" "review signal with count (branch + two tags)"
assert_contains "$OUT" "ветка release/v0.42.1 обнаружена, время появления неизвестно" "branch is shown as time-unknown"
assert_contains "$OUT" "метка v0.42.1-rc.2" "annotated tag listed"
assert_contains "$OUT" "дата метки" "annotated tag names its time source"
assert_contains "$OUT" "метка v0.42.1-rc.1" "light tag listed"
assert_contains "$OUT" "дата коммита метки" "light tag names its time source"
assert_not_contains "$OUT" "v0.41.0" "old tag before the card revision is not listed"
assert_not_contains "$OUT" "release/v0.41.0" "old release branch is not listed"
assert_not_contains "$OUT" "nightly-20261118" "tag outside the masks is not listed"
assert_contains "$(cat "$SANDBOX/drift")" "REVIEW: external_state" "writes a review line"

echo "scenario B: card already names the branch and rc.1 -> only rc.2 remains"
reset_stub
OUT=$(run "$CARD_OLD"$'\n- ветка `release/v0.42.1`, метки v0.42.1-rc.1')
assert_contains "$OUT" "1 событий" "one event left"
assert_contains "$OUT" "метка v0.42.1-rc.2" "unnamed tag still listed"
assert_not_contains "$OUT" "ветка release/v0.42.1" "named branch is not listed"

echo "scenario C: only unrelated noise -> no review"
reset_stub
echo '{"data":{"repository":{"refs":{"nodes":[{"name":"nightly-20261118","target":{"__typename":"Commit","committedDate":"2026-11-18T03:00:00Z"}}]}}}}' > "$STUB_DIR/tags.json"
echo '{"data":{"repository":{"refs":{"nodes":[{"name":"main","target":{"__typename":"Commit","committedDate":"2026-11-18T08:00:00Z"}}]}}}}' > "$STUB_DIR/heads.json"
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "событий после ревизии карточки, не названных в ней, нет" "reports no events"
assert_not_contains "$OUT" "проверить" "no review signal"
[ -s "$SANDBOX/drift" ] && { echo "  FAIL no drift line expected"; fails=$((fails+1)); } || echo "  ok   no drift line"

echo "scenario D: GitHub down -> UNKNOWN, not review; with a cached answer the age is shown"
reset_stub
run "$CARD_OLD" >/dev/null
touch "$STUB_DIR/fail"
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "ниже справочно данные из кэша" "cached answer used"
assert_contains "$OUT" "метка v0.42.1-rc.2" "cached events still shown for reference"
[ -s "$SANDBOX/drift" ] && { echo "  FAIL cached events must not raise a review line"; fails=$((fails+1)); } || echo "  ok   cached events raise no review line"
assert_not_contains "$OUT" "ghp_abcdef" "token never printed"
rm -rf "$SANDBOX/cache"
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "UNKNOWN: FMT-exocortex-template" "no cache -> UNKNOWN"
assert_contains "$OUT" "не расхождение" "unknown is not a review"
assert_not_contains "$OUT" "проверить" "no review signal when GitHub is unreachable"
[ -s "$SANDBOX/drift" ] && { echo "  FAIL no drift line expected"; fails=$((fails+1)); } || echo "  ok   no drift line"

echo "scenario E: no registry entry and no watch: -> UNTRACKED; watch: [] -> switched off"
reset_stub
OUT=$(run "$CARD_OLD" 77)
assert_contains "$OUT" "UNTRACKED: внешнее состояние не отслеживается — нет записи" "no entry"
OUT=$(run $'---\nwp: 529\nwatch: []\n---\nbody')
assert_contains "$OUT" "UNTRACKED" "switched off is explicit"
assert_contains "$OUT" "отключено в карточке" "says it was switched off in the card"

echo "scenario F: watch: in the card replaces the registry entry"
reset_stub
OUT=$(run $'---\nwp: 529\nwatch: [{"repo": "FMT-exocortex-template", "tags": ["nightly-*"]}]\n---\nbody')
assert_contains "$OUT" "карточка (watch:)" "source is the card"
assert_contains "$OUT" "метка nightly-20261118" "card mask is used"
assert_not_contains "$OUT" "v0.42.1-rc.2" "registry masks are not mixed in"
OUT=$(run $'---\nwp: 529\nwatch: {broken\n---\nbody')
assert_contains "$OUT" "UNKNOWN: наблюдение не разобрано" "broken watch: is reported, not fatal"
OUT=$(run $'---\nwp: 529\nwatch:\n---\nbody')
assert_contains "$OUT" "UNKNOWN: наблюдение не разобрано" "empty watch: is an error, not a silent switch-off"
assert_not_contains "$OUT" "отключено" "empty watch: does not switch watching off"

echo "scenario G: closed issue by keyword, issue already named in card, failed run on the new branch"
reset_stub
echo '[{"number":1590,"title":"0.42.1 dry-run flag leaks","state":"CLOSED","createdAt":"2026-11-17T09:00:00Z","closedAt":"2026-11-18T05:00:00Z"},
      {"number":1567,"title":"0.42 manifest drift","state":"CLOSED","createdAt":"2026-11-10T09:00:00Z","closedAt":"2026-11-17T12:00:00Z"}]' > "$STUB_DIR/issues.json"
echo '[{"conclusion":"failure","createdAt":"2026-11-18T06:30:00Z","workflowName":"template-validate"},
      {"conclusion":"success","createdAt":"2026-11-18T07:30:00Z","workflowName":"template-validate"}]' > "$STUB_DIR/runs.json"
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "обращение #1590 закрыт" "closed issue matched by keyword"
assert_not_contains "$OUT" "#1567" "issue named in the card is not repeated"
assert_contains "$OUT" "красная сборка «template-validate» на ветке release/v0.42.1" "failed run on the new branch"
assert_not_contains "$OUT" "успех" "green run is not listed"

echo "scenario H: names are matched whole -- rc.10 in the card does not name rc.1; the branch does not name a tag"
reset_stub
OUT=$(run "$CARD_OLD"$'\n- метка v0.42.1-rc.10 уже есть; ветка `release/v0.42.1`')
assert_contains "$OUT" "метка v0.42.1-rc.1 " "rc.1 stays an event although rc.10 is named"
assert_contains "$OUT" "метка v0.42.1-rc.2" "rc.2 stays an event"
echo '{"data":{"repository":{"refs":{"nodes":[{"name":"v0.42.1","target":{"__typename":"Commit","committedDate":"2026-11-18T09:00:00Z"}}]}}}}' > "$STUB_DIR/tags.json"
OUT=$(run "$CARD_OLD"$'\n- ветка `release/v0.42.1`')
assert_contains "$OUT" "метка v0.42.1 " "tag is not named by the branch release/v0.42.1"
OUT=$(run "$CARD_OLD"$'\n- метка v0.42.1.')
assert_not_contains "$OUT" "метка v0.42.1 (" "name followed by a sentence dot is named"

echo "scenario I: branch without commit time is counted, a failed run on a branch named in the card is still reported"
reset_stub
echo '{"data":{"repository":{"refs":{"nodes":[{"name":"release/v0.43.0","target":{"__typename":"Commit","committedDate":null}},{"name":"release/v0.42.1","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}}]}}}}' > "$STUB_DIR/heads.json"
echo '[{"conclusion":"failure","createdAt":"2026-11-18T06:30:00Z","workflowName":"template-validate"}]' > "$STUB_DIR/runs.json"
OUT=$(run "$CARD_OLD"$'\n- ветка `release/v0.42.1` и метки v0.42.1-rc.1, v0.42.1-rc.2')
assert_contains "$OUT" "у 1 веток нет времени последнего коммита" "untimed branch is counted, not dropped"
assert_contains "$OUT" "красная сборка «template-validate» на ветке release/v0.42.1" "red build on a named branch is reported"
assert_not_contains "$OUT" "ветка release/v0.42.1 обнаружена" "named branch itself is not repeated"

echo "scenario J: damaged cache is no answer; truncated ref lists and the run-branch cap are said aloud"
reset_stub
run "$CARD_OLD" >/dev/null
touch "$STUB_DIR/fail"
for f in "$SANDBOX"/cache/*.json; do echo '{broken' > "$f"; done
OUT=$(run "$CARD_OLD"); RC=$?
assert_contains "$OUT" "UNKNOWN: FMT-exocortex-template" "damaged cache falls back to UNKNOWN"
[ "$RC" -eq 0 ] && echo "  ok   exit code stays 0" || { echo "  FAIL exit code $RC"; fails=$((fails+1)); }
reset_stub
echo '{"data":{"repository":{"refs":{"totalCount":384,"nodes":[{"name":"release/v0.42.1","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}}]}}}}' > "$STUB_DIR/heads.json"
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "найдено 384, просмотрено 1" "truncated list is reported"
echo '{"data":{"repository":{"refs":{"nodes":[
 {"name":"release/a","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}},
 {"name":"release/b","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}},
 {"name":"release/c","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}},
 {"name":"release/d","target":{"__typename":"Commit","committedDate":"2026-11-18T06:00:00Z"}}]}}}}' > "$STUB_DIR/heads.json"
OUT=$(run "$CARD_OLD")
assert_contains "$OUT" "сборки проверены у 3 из 4 активных веток" "run-branch cap is reported"

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails"; exit 1; fi
echo "all scenarios passed"
