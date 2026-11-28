#!/usr/bin/env bash
# wp-archive-trigger-check-smoke.sh -- WP-561 Ф94 part 3 (pilot decision
# 28.11.2026): the 14-day / 400-line threshold no longer gates the archive
# licence. Any card is `licensed` unless archive_declined is less than 14 days
# old; over_threshold is still printed with its old meaning. Throwaway
# workspace only, bash 3.2 compatible.
set -uo pipefail
TOOL="$(cd "$(dirname "$0")/.." && pwd)/wp-archive-trigger-check.sh"
[ -f "$TOOL" ] || { echo "FAIL: $TOOL not found"; exit 1; }
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
fails=0
assert() { # <got> <want> <name>
  if [ "$1" = "$2" ]; then echo "  ok   $3"; else
    echo "  FAIL $3"
    echo "       got:  $(printf '%s' "$1" | tr '\n' ' ')"
    echo "       want: $(printf '%s' "$2" | tr '\n' ' ')"
    fails=$((fails+1))
  fi
}

WS="$SANDBOX/ws"; GOV="$WS/DS-my-strategy"
mkdir -p "$GOV/docs" "$GOV/inbox/WP-9301"
printf '| WP | P | Название | Статус |\n|---|---|---|---|\n| 9301 | P1 | **Fixture 9301** | 🔄 |\n' > "$GOV/docs/WP-REGISTRY.md"
CARD="$GOV/inbox/WP-9301/WP-9301.md"
unset IWE_GOVERNANCE_REPO

days_ago() { # <N> -> UTC date N days back (BSD or GNU date)
  local epoch
  epoch=$(( $(date -u +%s) - $1 * 86400 ))
  date -u -r "$epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%d
}
TODAY=$(days_ago 0)

write_card() { # <total lines> [frontmatter line ...] -> card of exactly that many lines
  local total="$1" n fm
  shift
  {
    echo '---'
    echo 'wp: 9301'
    echo 'status: in_progress'
    for fm in "$@"; do echo "$fm"; done
    echo '---'
    echo '## Ф1 первая ✅'
  } > "$CARD"
  n=$(wc -l < "$CARD" | tr -d ' ')
  while [ "$n" -lt "$total" ]; do echo "текст $n" >> "$CARD"; n=$((n + 1)); done
}

run_check() { # sets OUT (stdout) and STATUS ("rc=N stderr=...")
  local rc
  OUT=$(bash "$TOOL" 9301 "$WS" 2>"$SANDBOX/err.txt"); rc=$?
  STATUS="rc=$rc stderr=$(cat "$SANDBOX/err.txt")"
}

lines() { printf '%s\n' "$@"; }

echo "scenario 1: a 10-line card created today is licensed (the threshold does not gate)"
write_card 10 "created: $TODAY"
run_check
assert "$STATUS" "rc=0 stderr=" "exit 0, empty stderr"
assert "$OUT" "$(lines age_days=0 line_count=10 archive_declined_recent=false over_threshold=false auto_archive=licensed)" "exact report"

echo "scenario 2: the same card declined today -> declined"
write_card 10 "created: $TODAY" "archive_declined: $TODAY"
run_check
assert "$STATUS" "rc=0 stderr=" "exit 0, empty stderr"
assert "$OUT" "$(lines age_days=0 line_count=10 archive_declined_recent=true over_threshold=false auto_archive=declined)" "exact report"

echo "scenario 3: the same card declined 20 days ago -> the decline expired, licensed"
write_card 10 "created: $TODAY" "archive_declined: $(days_ago 20)"
run_check
assert "$STATUS" "rc=0 stderr=" "exit 0, empty stderr"
assert "$OUT" "$(lines age_days=0 line_count=10 archive_declined_recent=false over_threshold=false auto_archive=licensed)" "exact report"

echo "scenario 4: a card without created -> licensed"
write_card 10
run_check
assert "$STATUS" "rc=0 stderr=" "exit 0, empty stderr"
assert "$OUT" "$(lines age_days=unknown line_count=10 archive_declined_recent=false over_threshold=false auto_archive=licensed)" "exact report"

check_big_old() { # <declined-line or empty> <want declined_recent> <want over_threshold> <want auto_archive>
  if [ -n "$1" ]; then write_card 450 "created: $(days_ago 30)" "$1"; else write_card 450 "created: $(days_ago 30)"; fi
  run_check
  assert "$STATUS" "rc=0 stderr=" "exit 0, empty stderr"
  local age_line age
  age_line=$(printf '%s\n' "$OUT" | sed -n 1p)
  age=${age_line#age_days=}
  case "$age" in ''|*[!0-9]*) age=-1 ;; esac
  assert "$([ "$age" -gt 14 ] && echo over-14 || echo "$age_line")" "over-14" "age_days is a number over 14 (exact value depends on the clock)"
  assert "$(printf '%s\n' "$OUT" | sed -n '2,$p')" "$(lines line_count=450 "archive_declined_recent=$2" "over_threshold=$3" "auto_archive=$4")" "exact report after age_days"
}

echo "scenario 5: a big old card -> licensed, over_threshold=true"
check_big_old "" false true licensed

echo "scenario 6: the big old card declined today -> a fresh decline still wins, over_threshold keeps its meaning"
check_big_old "archive_declined: $TODAY" true false declined

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s)"; exit 1; fi
echo "PASS: all scenarios"
