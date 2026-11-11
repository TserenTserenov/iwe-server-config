#!/usr/bin/env bash
# wp-merge-refs-check-smoke.sh -- WP-561 Ф60: the bundle helper that compares
# pull requests / branches named in a WP card with their real GitHub state.
# Uses a stub `gh` (WP_MERGE_REFS_GH) and throwaway git repos, no network.
set -uo pipefail

HELPER="$(cd "$(dirname "$0")/.." && pwd)/wp-merge-refs-check.py"
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
for repo in PACK-digital-platform FMT-exocortex-template docs; do
  mkdir -p "$WS/$repo"
  git -C "$WS/$repo" init -q
  git -C "$WS/$repo" remote add origin "git@github.com:Org/$repo.git"
done

GH="$SANDBOX/gh"
cat > "$GH" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_SLEEP:-}" ] && sleep "$GH_SLEEP"
[ -n "${GH_FAIL_TOKEN:-}" ] && { echo "bad credentials for token ghp_abcdef1234567890" >&2; exit 1; }
case "$*" in
  *"Org/PACK-digital-platform"*)
    echo '[{"number":64,"state":"MERGED","headRefName":"wp616-translator-role","mergedAt":"2026-11-10T15:12:00Z"},
          {"number":63,"state":"MERGED","headRefName":"wp616-ownership","mergedAt":"2026-11-10T12:00:00Z"},
          {"number":65,"state":"OPEN","headRefName":"wp616-next","mergedAt":null},
          {"number":66,"state":"CLOSED","headRefName":"wp616-dropped","mergedAt":null},
          {"number":50,"state":"MERGED","headRefName":"old-work","mergedAt":"2020-01-01T00:00:00Z"}]' ;;
  *) echo "HTTP 404" >&2; exit 1 ;;
esac
EOF
chmod +x "$GH"
export WP_MERGE_REFS_GH="$GH"

run() {  # <card text> -> stdout of the helper; drift lines in $SANDBOX/drift
  printf '%s\n' "$1" > "$SANDBOX/card.md"
  : > "$SANDBOX/drift"
  python3 "$HELPER" "$SANDBOX/card.md" --workspace "$WS" --drift-file "$SANDBOX/drift" --days "${DAYS:-100000}"
}

echo "scenario A: the 10.11 case -- branch named, merge request already merged"
OUT=$(run '- [x] DP.ROLE.121 Переводчик (ветка `wp616-translator-role` PACK-digital-platform, запрос на слияние — после закрытия сессии)')
assert_contains "$OUT" "ветка \`wp616-translator-role\`" "reports the branch"
assert_contains "$OUT" "слита запросом #64" "names the merging pull request"
assert_contains "$(cat "$SANDBOX/drift")" "DRIFT: merge_ref_mismatch" "writes a drift line"

echo "scenario B: card already says merged -> no drift"
OUT=$(run '- [x] ([PACK-digital-platform #63](https://github.com/Org/PACK-digital-platform/pull/63), слит 2fe1c8b) принцип
- [x] PACK-digital-platform #64 слит f699c5e; ветку `wp616-translator-role` на сервере можно удалить')
assert_contains "$OUT" "расхождений: 0" "zero mismatches"
[ -s "$SANDBOX/drift" ] && { echo "  FAIL no drift expected"; fails=$((fails+1)); } || echo "  ok   no drift lines"

echo "scenario C: open PR called merged, closed PR not called closed, 'не слит' is not 'слит'"
OUT=$(run '- PACK-digital-platform #65 слит вчера
- PACK-digital-platform PR #66 ждёт ревью
- PACK-digital-platform #64 не слит')
assert_contains "$OUT" "#65 — открыт, а карточка называет его слитым" "open but called merged"
assert_contains "$OUT" "#66 — закрыт без слияния" "closed without merge"
assert_contains "$OUT" "#64 — слит 2026-11-10 15:12 UTC, а карточка пишет о нём как о неслитом" "negated word does not count as merged"

echo "scenario D: alias FMT and GitHub failure are reported as unavailable, not drift"
OUT=$(run '- FMT #1521 слит')
assert_contains "$OUT" "Проверка недоступна — FMT-exocortex-template" "unavailable repo reported"
[ -s "$SANDBOX/drift" ] && { echo "  FAIL unavailability must not be drift"; fails=$((fails+1)); } || echo "  ok   no drift on failure"

echo "scenario E: status word of a neighbour reference does not leak"
OUT=$(run '- PACK-digital-platform #63 слит; PACK-digital-platform #65 открыт')
assert_contains "$OUT" "расхождений: 0" "neighbour 'слит' is not attributed to #65"

echo "scenario F: unknown repo names and plain #N are ignored"
OUT=$(run '- в пак слиты #59–#64; other-repo #5')
assert_contains "$OUT" "нет ссылок" "nothing to check"
assert_not_contains "$OUT" "⚠️" "no warnings"

echo "scenario G: merged PR next to a commit id, no status word -> not a claim, no drift"
OUT=$(run '- [x] (09.11; PACK-digital-platform #63, 2fe1c8b) принцип записан')
assert_contains "$OUT" "расхождений: 0" "bare reference is not flagged"

echo "scenario H: merged PR still described as awaiting merge"
OUT=$(run '- Ф4 — PACK-digital-platform #64 ждёт слияния пилотом')
assert_contains "$OUT" "#64 — слит 2026-11-10 15:12 UTC, а карточка пишет о нём как о неслитом" "pending claim on merged PR"

echo "scenario I: merge older than the window is history, not a claim"
OUT=$(DAYS=30 run '- PACK-digital-platform #50 ждёт слияния')
assert_contains "$OUT" "расхождений: 0" "old merge ignored"

echo "scenario J: a bare '#64 слит' elsewhere in the card acknowledges the merge"
OUT=$(run '- PACK-digital-platform #64 открыт, ждёт пилота
- позже: запрос #64 слит 10.11')
assert_contains "$OUT" "расхождений: 0" "bare acknowledgment counts"

echo "scenario K: default branch and branch without a pending claim are not flagged"
OUT=$(run '- PACK-digital-platform: ветка `main` обновлена
- PACK-digital-platform ветка `wp616-translator-role` — исправления внесены')
assert_contains "$OUT" "расхождений: 0" "no claim, no drift"

echo "scenario L: path first, branch nearest to its own repo name (review В2)"
OUT=$(run '- DS-my-strategy/inbox/WP-616: ветка `wp616-translator-role` в PACK-digital-platform, запрос после закрытия')
assert_contains "$OUT" "слита запросом #64" "branch attributed to the nearest repo"
OUT=$(run '- docs: ветка `wp616-translator-role` ждёт')
assert_contains "$OUT" "нет ссылок" "non-ecosystem directory names are not repos"

echo "scenario M: comma-separated neighbours do not share status words (review С1)"
OUT=$(run '- PACK-digital-platform #63 слит, PACK-digital-platform #65 открыт')
assert_contains "$OUT" "расхождений: 0" "no false alarm for the open neighbour"
OUT=$(run '- PACK-digital-platform #63 слит, PACK-digital-platform #64 ждёт слияния')
assert_contains "$OUT" "#64 — слит" "pending neighbour still caught"

echo "scenario N: wider pending vocabulary (review С2)"
OUT=$(run '- PACK-digital-platform #64 ждет пилота')
assert_contains "$OUT" "#64 — слит" "'ждет' without ё"
OUT=$(run '- ветка `wp616-translator-role` PACK-digital-platform, запрос на слияние создам позже')
assert_contains "$OUT" "слита запросом #64" "'создам позже'"

echo "scenario O: bare acknowledgment is strict (review С3)"
OUT=$(run '- PACK-digital-platform #64 ждёт
- FMT #64 слит')
assert_contains "$OUT" "PACK-digital-platform #64 — слит" "another repo's '#64 слит' does not acknowledge"
OUT=$(run '- PACK-digital-platform #64 ждёт
- запрос #64 слить после закрытия')
assert_contains "$OUT" "PACK-digital-platform #64 — слит" "'слить' is not 'слит'"
OUT=$(run '- PACK-digital-platform #64 ждёт
- запрос #64 пока не будет слит')
assert_contains "$OUT" "PACK-digital-platform #64 — слит" "'не будет слит' is not 'слит'"

echo "scenario P: hanging GitHub stops within the total budget (review В1)"
start=$(date +%s)
OUT=$(GH_SLEEP=60 run '- PACK-digital-platform #64 ждёт
- FMT #1521 ждёт')
took=$(( $(date +%s) - start ))
assert_contains "$OUT" "опрос остановлен" "polling stopped after the first hang"
if [ "$took" -le 35 ]; then echo "  ok   finished in ${took}s"; else echo "  FAIL took ${took}s"; fails=$((fails+1)); fi

echo "scenario Q: tokens in GitHub error text are masked (review Н1)"
OUT=$(GH_FAIL_TOKEN=1 run '- PACK-digital-platform #64 ждёт')
assert_contains "$OUT" "ghp_***" "token masked"
assert_not_contains "$OUT" "abcdef1234567890" "token body absent"

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails"; exit 1; fi
echo "ALL OK"
