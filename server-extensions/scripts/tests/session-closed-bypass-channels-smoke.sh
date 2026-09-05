#!/usr/bin/env bash
# session-closed-bypass-channels-smoke.sh -- WP-484 (05.09, peer-session
# 2026-09-05-25 with Kimi + cold review): hours for closes that bypass
# process-runner.py must reach the day ledger as full `session_closed` events.
#
# Guards three defects that were live before this test existed:
#   1. identity by bare slug -- `open` defaults slug to $WP, so a second session
#      of the same WP on the same day was silently skipped and its hours lost;
#   2. event filed under "today" instead of the session's own day -- a close
#      crossing midnight moved the hours to the wrong day;
#   3. channel `auto-archive-cancelled` skipped on the assumption that the runner
#      already wrote the event (step ORDER is not step SUCCESS).
#
# Runs the function under `set -euo pipefail`, exactly like session-guard.sh
# itself: the pre-fix version died on a bare `var=$(cmd)` assignment there, which
# broke the "never fails the close" contract in production but not in a laxer
# test shell.
set -euo pipefail

IWE_ROOT_REAL="${IWE_ROOT:-$HOME/IWE}"
GUARD="$IWE_ROOT_REAL/scripts/session-guard.sh"
GOV_REPO_REAL="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
LEDGER_APPEND="$IWE_ROOT_REAL/$GOV_REPO_REAL/scripts/ledger-append.sh"

[ -f "$GUARD" ] || { echo "SKIP: не найден $GUARD"; exit 0; }
[ -f "$LEDGER_APPEND" ] || { echo "SKIP: не найден $LEDGER_APPEND"; exit 0; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Sandbox mirrors only what the function touches: the ledger writer, its lib/,
# and an empty ledger tree. Nothing here points at the real ledger.
IWE_ROOT="$SANDBOX/iwe"
GOV_REPO="$GOV_REPO_REAL"
mkdir -p "$IWE_ROOT/$GOV_REPO/scripts" "$IWE_ROOT/$GOV_REPO/machine/ledger"
cp "$LEDGER_APPEND" "$IWE_ROOT/$GOV_REPO/scripts/"
cp -R "$IWE_ROOT_REAL/$GOV_REPO_REAL/scripts/lib" "$IWE_ROOT/$GOV_REPO/scripts/"
export IWE_LEDGER_DIR="$IWE_ROOT/$GOV_REPO/machine/ledger"

# Extract emit_session_closed() from the live script: the test must exercise the
# shipped code, not a copy that can drift away from it.
python3 - "$GUARD" "$SANDBOX/emit_fn.sh" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text(encoding="utf-8").split("\n")
try:
    start = next(i for i, line in enumerate(src) if line.startswith("emit_session_closed() {"))
except StopIteration:
    raise SystemExit("emit_session_closed() не найдена в session-guard.sh")
# The function body contains bare "}" lines of its own (python dict literals
# inside heredocs), so the closing brace is the one followed by the next
# top-level definition rather than simply the first "}" at column zero.
end = next(i for i in range(start + 50, len(src))
           if src[i] == "}" and src[i + 2].startswith("# resolve_orz_sessions_dir"))
Path(sys.argv[2]).write_text("\n".join(src[start:end + 1]), encoding="utf-8")
PY

now_date() { date +"%Y-%m-%d"; }
# shellcheck source=/dev/null
. "$SANDBOX/emit_fn.sh"

PASS=0
FAIL=0
check() {  # check <описание> <ожидание> <факт>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 -- ожидал '$2', получил '$3'"
    FAIL=$((FAIL + 1))
  fi
}

count_events() {  # count_events <дата> <поле> <значение>
  local file="$IWE_LEDGER_DIR/day/${1:0:4}/${1:5:2}/day-$1.yaml"
  [ -f "$file" ] || { echo 0; return; }
  FILE_ENV="$file" FIELD_ENV="$2" VALUE_ENV="$3" python3 -c '
import os, yaml
doc = yaml.safe_load(open(os.environ["FILE_ENV"], encoding="utf-8")) or {}
field, value = os.environ["FIELD_ENV"], os.environ["VALUE_ENV"]
print(sum(1 for e in doc.get("events") or []
          if e.get("kind") == "session_closed"
          and str((e.get("data") or {}).get(field, "")) == value))
'
}

field_of() {  # field_of <дата> <slug> <поле>
  local file="$IWE_LEDGER_DIR/day/${1:0:4}/${1:5:2}/day-$1.yaml"
  FILE_ENV="$file" SLUG_ENV="$2" FIELD_ENV="$3" python3 -c '
import os, yaml
doc = yaml.safe_load(open(os.environ["FILE_ENV"], encoding="utf-8")) or {}
for e in doc.get("events") or []:
    data = e.get("data") or {}
    if e.get("kind") == "session_closed" and data.get("slug") == os.environ["SLUG_ENV"]:
        print(data.get(os.environ["FIELD_ENV"]))
        break
'
}

make_sem() {  # make_sem <файл> <opened_at> <slug> <session_id> <orz_file>
  cat > "$1" <<EOF
---
agent: claude-code
personality: unassigned
wp: WP-484
slug: $3
opened_at: $2
session_id: $4
orz_file: $5
---
EOF
}

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d 'yesterday' +%Y-%m-%d)
OPENED_45M=$(date -u -v-45M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '45 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

echo "1. полное событие с измеренной длительностью"
make_sem "$SANDBOX/sem1.open" "$OPENED_45M" "slug-one" "1700000001" "2026-09/$TODAY-slug-one.md"
emit_session_closed "peer-session" "$SANDBOX/sem1.open" "WP-484" "slug-one" "claude-code"
check "событие записано" "1" "$(count_events "$TODAY" slug slug-one)"
check "длительность измерена из семафора" "45" "$(field_of "$TODAY" slug-one duration_min)"
check "канал закрытия записан" "peer-session" "$(field_of "$TODAY" slug-one close_channel)"

echo "2. повторное закрытие той же сессии не дублирует событие"
emit_session_closed "peer-session" "$SANDBOX/sem1.open" "WP-484" "slug-one" "claude-code" 2>/dev/null
check "второго события нет" "1" "$(count_events "$TODAY" slug slug-one)"

echo "3. две разные сессии одного РП в один день (общий slug=WP-N)"
make_sem "$SANDBOX/sem2.open" "$OPENED_45M" "WP-484" "1700000002" "2026-09/$TODAY-first.md"
make_sem "$SANDBOX/sem3.open" "$OPENED_45M" "WP-484" "1700000003" "2026-09/$TODAY-second.md"
emit_session_closed "force-no-reflection" "$SANDBOX/sem2.open" "WP-484" "WP-484" "claude-code"
emit_session_closed "force-no-reflection" "$SANDBOX/sem3.open" "WP-484" "WP-484" "claude-code"
check "обе сессии записаны, часы второй не потеряны" "2" "$(count_events "$TODAY" slug WP-484)"

echo "4. сессия открыта вчера, закрыта сегодня"
make_sem "$SANDBOX/sem4.open" "$OPENED_45M" "slug-midnight" "1700000004" "2026-09/$YESTERDAY-midnight.md"
emit_session_closed "peer-session" "$SANDBOX/sem4.open" "WP-484" "slug-midnight" "claude-code"
check "событие в дне сессии" "1" "$(count_events "$YESTERDAY" slug slug-midnight)"
check "событие не попало в сегодняшний день" "0" "$(count_events "$TODAY" slug slug-midnight)"

echo "5. канал auto-archive-cancelled, событие раннера отсутствует"
make_sem "$SANDBOX/sem5.open" "$OPENED_45M" "slug-archive" "1700000005" "2026-09/$TODAY-archive.md"
emit_session_closed "auto-archive-cancelled" "$SANDBOX/sem5.open" "WP-484" "slug-archive" "claude-code"
check "часы записаны, а не потеряны вместе со сбоем раннера" "1" "$(count_events "$TODAY" slug slug-archive)"

echo "6. канал auto-archive-cancelled, событие раннера уже есть"
RUNNER_EVENT="{\"wp\":\"WP-484\",\"agent\":\"claude-code\",\"duration_min\":30,\"turns\":7,\"session_file\":\"MC-sessions/2026-09/$TODAY-runner-wrote.md\",\"repos\":[],\"status\":\"done\"}"
bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$TODAY" session_closed "$RUNNER_EVENT" quick-close >/dev/null
make_sem "$SANDBOX/sem6.open" "$OPENED_45M" "slug-runner" "1700000006" "2026-09/$TODAY-runner-wrote.md"
emit_session_closed "auto-archive-cancelled" "$SANDBOX/sem6.open" "WP-484" "slug-runner" "claude-code" 2>/dev/null
check "событие раннера распознано по имени файла, дубля нет" "0" "$(count_events "$TODAY" slug slug-runner)"

echo "7. метка вне полосы правдоподобия"
make_sem "$SANDBOX/sem7.open" "2020-01-01T00:00:00Z" "slug-susp" "1700000007" "2026-09/$TODAY-susp.md"
emit_session_closed "cancel-obligation" "$SANDBOX/sem7.open" "WP-484" "slug-susp" "claude-code"
check "длительность не выдумана" "None" "$(field_of "$TODAY" slug-susp duration_min)"
check "причина названа" "semaphore_suspicious" "$(field_of "$TODAY" slug-susp duration_reason)"

echo "8. сломанный python3 не роняет close"
make_sem "$SANDBOX/sem8.open" "$OPENED_45M" "slug-broken" "1700000008" "2026-09/$TODAY-broken.md"
mkdir -p "$SANDBOX/fakebin"
printf '#!/usr/bin/env bash\necho "simulated failure" >&2\nexit 1\n' > "$SANDBOX/fakebin/python3"
chmod +x "$SANDBOX/fakebin/python3"
set +e
( PATH="$SANDBOX/fakebin:$PATH"; emit_session_closed "peer-session" "$SANDBOX/sem8.open" "WP-484" "slug-broken" "claude-code" ) 2>/dev/null
BROKEN_EXIT=$?
set -e
check "функция вернула 0 вместо падения всего close" "0" "$BROKEN_EXIT"

echo
echo "session-closed-bypass-channels-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
