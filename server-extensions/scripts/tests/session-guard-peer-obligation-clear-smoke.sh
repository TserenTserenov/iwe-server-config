#!/usr/bin/env bash
# session-guard-peer-obligation-clear-smoke.sh -- WP-484 "eighth case"
# (06.09, peer session 2026-09-05-33 with Kimi).
#
# A peer session that closes correctly leaves its `.open.closed` semaphore on disk
# forever, and close_obligation.py keeps exempting the whole conversation from the
# Stop gate as long as that semaphore is the newest one. Nothing on that path
# cleared the obligation, so it stayed armed and every later
# `process-runner.py start quick-close` in the same conversation refused to start.
# clear_peer_session_obligation() closes that hole at the moment of the close.
#
# Guards four properties, each of which was a real decision in that session:
#   1. an armed obligation is actually cleared;
#   2. a `running` obligation of ANOTHER work product in the same conversation is
#      NOT touched (cold review 03.09 found this hole in the first version);
#   3. a semaphore without harness_session_id is a silent no-op, not a crash;
#   4. a broken obligation CLI never fails the close ("never blocks the close").
#
# The function is extracted from the shipped session-guard.sh, so the test cannot
# drift away from the code it guards, and runs under `set -euo pipefail` exactly
# like the script itself.
set -euo pipefail

IWE_ROOT_REAL="${IWE_ROOT:-$HOME/IWE}"
GUARD="$IWE_ROOT_REAL/scripts/session-guard.sh"
GOV_REPO_REAL="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
OBLIGATION_CLI_REAL="$IWE_ROOT_REAL/$GOV_REPO_REAL/scripts/close_obligation.py"

[ -f "$GUARD" ] || { echo "SKIP: не найден $GUARD"; exit 0; }
[ -f "$OBLIGATION_CLI_REAL" ] || { echo "SKIP: не найден $OBLIGATION_CLI_REAL"; exit 0; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

IWE_ROOT="$SANDBOX/iwe"
GOV_REPO="$GOV_REPO_REAL"
mkdir -p "$IWE_ROOT/$GOV_REPO/scripts"
cp "$OBLIGATION_CLI_REAL" "$IWE_ROOT/$GOV_REPO/scripts/"
# Obligation state lives in its own runtime dir, never the real one.
export IWE_RUNTIME_DIR="$SANDBOX/runtime"
mkdir -p "$IWE_RUNTIME_DIR"

OBLIGATION_CLI="$IWE_ROOT/$GOV_REPO/scripts/close_obligation.py"

# Extract the function from the live script rather than copying its body here.
python3 - "$GUARD" "$SANDBOX/clear_fn.sh" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").split("\n")
try:
    start = next(i for i, line in enumerate(lines)
                 if line.startswith("clear_peer_session_obligation() {"))
except StopIteration:
    raise SystemExit("clear_peer_session_obligation() не найдена в session-guard.sh")
end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
Path(sys.argv[2]).write_text("\n".join(lines[start:end + 1]), encoding="utf-8")
PY

# shellcheck source=/dev/null
. "$SANDBOX/clear_fn.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "  ПРОВАЛ: $1 (ожидал '$3', получил '$2')"
  fi
}

make_semaphore() {  # <path> [harness_session_id]
  {
    echo "wp: WP-484"
    echo "close_path: peer-session"
    if [ -n "${2:-}" ]; then
      echo "harness_session_id: $2"
    fi
  } > "$1"
}

# State is read from the stored record, not from a CLI verb: close_obligation.py
# has no read-only "what state is this in" command, and the verbs that would tell
# us (stop-check) mutate state as a side effect -- an observer must not do that.
obligation_state() {  # <session_id> -> state or "none"
  python3 - "$IWE_RUNTIME_DIR/close-obligation" "$1" <<'PY'
import json, pathlib, sys
directory, session_id = pathlib.Path(sys.argv[1]), sys.argv[2]
for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    if record.get("session_id") == session_id:
        print(record.get("state") or "unknown")
        break
else:
    print("none")
PY
}

echo "1. взведённое обязательство пир-сессии снимается"
SID_ARMED="11111111-1111-1111-1111-111111111111"
python3 "$OBLIGATION_CLI" arm --session-id "$SID_ARMED" --mode block >/dev/null
check "до закрытия обязательство взведено" "$(obligation_state "$SID_ARMED")" "armed"
make_semaphore "$SANDBOX/armed.open.closed" "$SID_ARMED"
clear_peer_session_obligation "$SANDBOX/armed.open.closed" "wp484-peer" 2>/dev/null
check "после закрытия обязательства нет" "$(obligation_state "$SID_ARMED")" "none"

echo "2. выполняющееся обязательство чужого РП не трогаем"
SID_RUNNING="22222222-2222-2222-2222-222222222222"
python3 "$OBLIGATION_CLI" arm --session-id "$SID_RUNNING" --mode block >/dev/null
TICKET=$(python3 "$OBLIGATION_CLI" issue-ticket --session-id "$SID_RUNNING" --slug other-wp \
  --tool-use-id smoke-tool-use 2>/dev/null | tr -d '[:space:]')
[ -n "$TICKET" ] || { echo "  ПРОВАЛ: issue-ticket не выдал nonce"; exit 1; }
python3 "$OBLIGATION_CLI" consume-ticket --nonce "$TICKET" --slug other-wp --run-id run-other >/dev/null
check "обязательство доведено до состояния running" "$(obligation_state "$SID_RUNNING")" "running"
make_semaphore "$SANDBOX/running.open.closed" "$SID_RUNNING"
clear_peer_session_obligation "$SANDBOX/running.open.closed" "wp484-peer" 2>/dev/null
check "выполняющееся обязательство уцелело" "$(obligation_state "$SID_RUNNING")" "running"

echo "3. семафор без идентификатора разговора — тихий no-op"
SID_BYSTANDER="44444444-4444-4444-4444-444444444444"
python3 "$OBLIGATION_CLI" arm --session-id "$SID_BYSTANDER" --mode block >/dev/null
make_semaphore "$SANDBOX/no-sid.open.closed"
set +e
NOISE=$(clear_peer_session_obligation "$SANDBOX/no-sid.open.closed" "wp484-peer" 2>&1)
RC=$?
set -e
check "функция вернула 0, ничего не сломав" "$RC" "0"
check "молча: ни слова в вывод" "$NOISE" ""
# "No-op" has to mean "touched nothing", not just "exited 0": without a conversation
# id there is nobody to clear, so a bystander obligation must survive untouched.
check "чужое обязательство не задето" "$(obligation_state "$SID_BYSTANDER")" "armed"

echo "4. сломанный обязательственный клиент не роняет закрытие"
SID_BROKEN="33333333-3333-3333-3333-333333333333"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(9)\n' > "$OBLIGATION_CLI"
make_semaphore "$SANDBOX/broken.open.closed" "$SID_BROKEN"
set +e
STDERR=$(clear_peer_session_obligation "$SANDBOX/broken.open.closed" "wp484-peer" 2>&1 >/dev/null)
RC=$?
set -e
check "функция вернула 0 вместо падения всего close" "$RC" "0"
case "$STDERR" in
  *"close_obligation cancel не прошёл"*) PASS=$((PASS + 1)); echo "  ok: отказ назван вслух, а не проглочен" ;;
  *) FAIL=$((FAIL + 1)); echo "  ПРОВАЛ: отказ не сообщён (stderr: '$STDERR')" ;;
esac

echo "5. функция действительно подключена к закрытию"
# Everything above tests the function in isolation. If the call site is deleted,
# renamed or re-guarded, those checks stay green and the defect comes back
# (cold review 06.09, Medium). This one reads the shipped script and asserts the
# wiring itself: the call exists, and it is guarded by the semaphore's own
# `close_path: peer-session` rather than by anything derived elsewhere.
WIRING=$(python3 - "$GUARD" <<'PY'
import re, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
calls = [m for m in re.finditer(r"^\s*clear_peer_session_obligation ", text, re.M)]
if len(calls) != 1:
    print(f"вызовов не один, а {len(calls)}")
    raise SystemExit(0)
before = text[:calls[0].start()].rsplit("\n", 3)[-3:]
guard = "\n".join(before)
print("ok" if "close_path: peer-session" in guard else f"вызов не под нужным условием: {guard!r}")
PY
)
check "вызов один и стоит под проверкой close_path" "$WIRING" "ok"

echo
echo "session-guard-peer-obligation-clear-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
