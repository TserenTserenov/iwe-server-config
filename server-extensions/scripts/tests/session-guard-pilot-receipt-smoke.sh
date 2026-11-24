#!/usr/bin/env bash
# WP-561 F82 step 2: `close --pilot-receipt` releases a live foreign mark only on the pilot's
# signed Telegram receipt. The first call sends the buttons and refuses (code 3), a repeat
# waits, "keep" is final, and after "release" the receipt is verified against the key
# published on origin/main and consumed once. A guard on another host reaches the claims
# over SSH (faked here) and still verifies locally. The real release_receipt.py of the
# governance repo is used; only Telegram is replaced by a fake that accepts every call.
set -euo pipefail
export IWE_PEER_CLOSE_WORD_ENFORCE=0
# The fixture repo sits where the wrapper protects the governance checkout; use real git
# (same as week-close-commit-guard-main-checkout-smoke.sh).
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.iwe-runtime/bin$' | paste -sd: -)

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="${SESSION_GUARD_UNDER_TEST:-$ROOT_DIR/scripts/session-guard.sh}"
RECEIPT_PY="${RELEASE_RECEIPT_PY:-$ROOT_DIR/../DS-my-strategy/scripts/lib/release_receipt.py}"
[ -f "$RECEIPT_PY" ] || { echo "SKIP: release_receipt.py not found (set RELEASE_RECEIPT_PY)"; exit 0; }
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-pilot-receipt.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
LIVE_PID=""
trap '[ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts/lib" "$REPO/machine"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '#!/usr/bin/env python3\nprint("{}")\n' > "$REPO/scripts/process-runner.py"
chmod +x "$REPO/scripts/process-runner.py"
cp "$RECEIPT_PY" "$REPO/scripts/lib/release_receipt.py"

# Telegram replaced at call time; everything else is the real program.
cat > "$REPO/scripts/lib/fake_telegram_door.py" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_receipt as rr

def fake(method, payload):
    if method == "sendMessage":
        return {"ok": True, "result": {"message_id": 42}}
    return {"ok": True, "result": True}

rr.telegram_call = fake
if sys.argv[1] == "press":
    update = {"update_id": 900, "callback_query": {
        "id": "cb", "data": f"rel:{sys.argv[2]}:{sys.argv[3]}", "from": {"id": 111},
        "message": {"message_id": 42, "chat": {"id": 111, "type": "private"}}}}
    sys.exit(rr.handle_update(update, 111, 111, rr.now_utc()))
sys.exit(rr.main(sys.argv[1:]))
PY
# The door the guard calls; the real one only adds the bot credentials.
cat > "$REPO/scripts/release-receipt.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export TELEGRAM_CHAT_ID=111
exec python3 "$(cd "$(dirname "$0")" && pwd)/lib/fake_telegram_door.py" "$@"
SH

KEY="$TEST_ROOT/signing_key"
ssh-keygen -q -t ed25519 -N "" -f "$KEY"
printf 'iwe-release-receipt %s\n' "$(cat "$KEY.pub")" > "$REPO/machine/release-receipt-allowed-signers"
git -C "$REPO" add scripts machine
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" IWE_FROZEN_CANONICAL_PATH=""
export IWE_RELEASE_SIGNING_KEY="$KEY" IWE_RELEASE_RECEIPT_DIR="$TEST_ROOT/receipt-state"
export IWE_RELEASE_RECEIPT_HOST="$(hostname -s)"
unset CLAUDE_PID OWNER_PID CODEX_THREAD_ID
SESSIONS="$TEST_ROOT/.iwe-runtime/sessions"
AUDIT="$TEST_ROOT/.iwe-runtime/pilot-release-audit.jsonl"

PASS=0
FAIL=0
check() {  # <name> <got> <expected>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "  ПРОВАЛ: $1 (ожидал '$3', получил '$2')"
  fi
}

write_orz() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ndate: 2026-11-22\ntype: work\nwp: WP-561\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nf\n\n## Контекст\nf\n\n## Достигнуто\nf\n\n## Ключевые решения\nf\n' > "$1"
}

sem_of() { grep -l "^slug: $1\$" "$SESSIONS"/fixture-*.open 2>/dev/null || true; }

open_sem() {  # <conversation> <slug>: a live foreign mark with its ORZ file published
  local semaphore orz
  CLAUDE_CODE_SESSION_ID="$1" bash "$GUARD" open --wp WP-561 --task "fixture $2" \
    --slug "$2" --agent fixture --owner-pid "$LIVE_PID" >/dev/null 2>&1
  semaphore=$(sem_of "$2")
  orz=$(grep '^orz_file: ' "$semaphore" | cut -d' ' -f2-)
  write_orz "$REPO/sessions/$orz"
  git -C "$REPO" add "sessions/$orz"
  git -C "$REPO" commit -qm "orz $2"
  git -C "$REPO" push -q origin HEAD:main
}

CLOSE_ERR="$TEST_ROOT/close.err"
close_sem() {  # <conversation> <slug> [extra close args...]; prints the exit code
  local conversation="$1" slug="$2" rc=0
  shift 2
  CLAUDE_CODE_SESSION_ID="$conversation" bash "$GUARD" close --wp WP-561 --slug "$slug" \
    --agent fixture "$@" >/dev/null 2>"$CLOSE_ERR" || rc=$?
  echo "$rc"
}

state_of() { [ -n "$(sem_of "$1")" ] && echo open || echo closed; }
seen() { grep -q -- "$1" "$CLOSE_ERR" && echo yes || echo no; }
claims() { find "$1/claims" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
last_claim() {  # <state dir>: id of the newest claim
  python3 - "$1" <<'PY'
import json, pathlib, sys
claims = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1], "claims").glob("*.json")]
print(max(claims, key=lambda c: c["created_at"])["claim_id"])
PY
}
press() {  # <state dir> <claim> <r|k>
  IWE_RELEASE_RECEIPT_DIR="$1" python3 "$REPO/scripts/lib/fake_telegram_door.py" press "$2" "$3" >/dev/null
}
last_audit() { tail -1 "$AUDIT" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print(r.get("owner",""), r.get("word","")[:18])'; }

sleep 600 &
LIVE_PID=$!
open_sem convo-caller caller-mark

echo "1. на хосте квитанций: заявка, ожидание, нажатие «Снять», снятие"
open_sem convo-live live-mark
check "первый вызов: отказ 3" "$(close_sem convo-caller live-mark --pilot-receipt)" "3"
check "пилоту отправлено сообщение" "$(seen 'отправлено сообщение «Снять отметку сессии?»')" "yes"
check "отметка осталась" "$(state_of live-mark)" "open"
check "повтор до нажатия: отказ 3" "$(close_sem convo-caller live-mark --pilot-receipt)" "3"
check "повтор говорит, что ждёт нажатия" "$(seen 'нажатия пока нет')" "yes"
check "второго сообщения нет" "$(claims "$IWE_RELEASE_RECEIPT_DIR")" "1"
press "$IWE_RELEASE_RECEIPT_DIR" "$(last_claim "$IWE_RELEASE_RECEIPT_DIR")" r
check "после нажатия: снято" "$(close_sem convo-caller live-mark --pilot-receipt)" "0"
check "отметка снята" "$(state_of live-mark)" "closed"
check "журнал: квитанция при живом владельце" "$(last_audit)" "receipt_alive квитанция Telegram"

echo "2. «Не трогать» окончательно, заново не спрашивает"
open_sem convo-keep keep-mark
close_sem convo-caller keep-mark --pilot-receipt >/dev/null
press "$IWE_RELEASE_RECEIPT_DIR" "$(last_claim "$IWE_RELEASE_RECEIPT_DIR")" k
check "после «Не трогать»: отказ 3" "$(close_sem convo-caller keep-mark --pilot-receipt)" "3"
check "отказ называет решение пилота" "$(seen 'пилот нажал «Не трогать»')" "yes"
check "отметка осталась" "$(state_of keep-mark)" "open"
check "новых заявок нет" "$(claims "$IWE_RELEASE_RECEIPT_DIR")" "2"

echo "3. Кодекс (слово в беседе недоказуемо) снимает по квитанции"
open_sem convo-codex codex-mark
check "заявка отправлена" "$(CODEX_THREAD_ID=t1 close_sem "" codex-mark --pilot-receipt)" "3"
press "$IWE_RELEASE_RECEIPT_DIR" "$(last_claim "$IWE_RELEASE_RECEIPT_DIR")" r
check "снято" "$(CODEX_THREAD_ID=t1 close_sem "" codex-mark --pilot-receipt)" "0"

echo "3а. отметка без номера беседы (Кими, Гермес) тоже снимается"
open_sem "" thread-less-mark
check "в отметке нет номера беседы" "$(grep -c '^harness_session_id: ' "$(sem_of thread-less-mark)" || true)" "0"
check "заявка отправлена" "$(close_sem convo-caller thread-less-mark --pilot-receipt)" "3"
press "$IWE_RELEASE_RECEIPT_DIR" "$(last_claim "$IWE_RELEASE_RECEIPT_DIR")" r
check "снято" "$(close_sem convo-caller thread-less-mark --pilot-receipt)" "0"

echo "4. другой хост: заявки на хосте квитанций через SSH, проверка у себя"
SERVER_STATE="$TEST_ROOT/server-state"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/server-home"
ln -s "$TEST_ROOT" "$TEST_ROOT/server-home/IWE"
cat > "$TEST_ROOT/bin/ssh" <<SH
#!/usr/bin/env bash
# fake ssh: last argument is the remote command, run as the server user
while [ "\$#" -gt 1 ]; do shift; done
HOME="$TEST_ROOT/server-home" IWE_RELEASE_RECEIPT_DIR="$SERVER_STATE" bash -c "\$1"
SH
chmod +x "$TEST_ROOT/bin/ssh"
open_sem convo-mac mac-mark
check "заявка через SSH: отказ 3" "$(PATH="$TEST_ROOT/bin:$PATH" IWE_RELEASE_RECEIPT_HOST=tsekh-test close_sem convo-caller mac-mark --pilot-receipt)" "3"
check "заявка лежит на хосте квитанций" "$(claims "$SERVER_STATE")" "1"
press "$SERVER_STATE" "$(last_claim "$SERVER_STATE")" r
check "снято с проверкой на своём хосте" "$(PATH="$TEST_ROOT/bin:$PATH" IWE_RELEASE_RECEIPT_HOST=tsekh-test close_sem convo-caller mac-mark --pilot-receipt)" "0"
check "погашение записано у себя" "$(find "$IWE_RELEASE_RECEIPT_DIR/consumed" -type f | wc -l | tr -d ' ')" "4"

echo "5. ключ проверки только из опубликованной версии"
open_sem convo-forged forged-mark
close_sem convo-caller forged-mark --pilot-receipt >/dev/null
press "$IWE_RELEASE_RECEIPT_DIR" "$(last_claim "$IWE_RELEASE_RECEIPT_DIR")" r
ssh-keygen -q -t ed25519 -N "" -f "$TEST_ROOT/other_key"
printf 'iwe-release-receipt %s\n' "$(cat "$TEST_ROOT/other_key.pub")" > "$REPO/machine/release-receipt-allowed-signers"
git -C "$REPO" commit -qam "rotate key"
git -C "$REPO" push -q origin HEAD:main
check "чужой опубликованный ключ: отказ 3" "$(close_sem convo-caller forged-mark --pilot-receipt)" "3"
check "отказ называет проверку подписи" "$(seen 'не прошла проверку')" "yes"
check "отметка осталась" "$(state_of forged-mark)" "open"

echo
echo "pilot-receipt: прошло $PASS, провалов $FAIL"
[ "$FAIL" -eq 0 ]
