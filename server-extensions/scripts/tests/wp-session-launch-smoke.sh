#!/usr/bin/env bash
# Smoke scenarios for scripts/wp-session-launch.py (WP-530 F161) on a throwaway
# repository, with a stand-in session-guard and a stand-in agent
# (tests/fixtures/wp-session-launch/). Every scenario checks the observable
# result: manifest status and exit code, what reached origin/main, that the
# isolated copy was left at its base, and how many times machine-close ran.
# The real session-guard is exercised by the live probes recorded in WP-530 F161.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$HERE/../wp-session-launch.py"
FIX="$HERE/fixtures/wp-session-launch"
PY="${PYTHON:-python3}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export IWE_ROOT="$TMP/iwe" FAKE_GUARD_STATE="$TMP/state" RUNTIME="$TMP/runtime" IWE_GOVERNANCE_REPO=DS-my-strategy
export IWE_LAUNCH_SESSION_GUARD="$FIX/fake-session-guard.sh" IWE_LAUNCH_AGENT_CMD="$FIX/fake-agent.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$IWE_ROOT" "$FAKE_GUARD_STATE" "$RUNTIME"
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$IWE_ROOT/DS-my-strategy" 2>/dev/null
REPO="$IWE_ROOT/DS-my-strategy"
mkdir -p "$REPO/allowed" "$REPO/other" "$REPO/.githooks"
printf 'base\n' > "$REPO/allowed/existing.md"
printf 'old\n' > "$REPO/allowed/to-delete.md"
printf 'keep\n' > "$REPO/other/keep.md"
printf '*.log\n' > "$REPO/.gitignore"
printf '#!/bin/sh\ngit diff --cached --name-only | grep -q "^allowed/refuse-me.md$" && { echo "hook: refused" >&2; exit 1; }\nexit 0\n' \
  > "$REPO/.githooks/pre-commit"
chmod +x "$REPO/.githooks/pre-commit"
git -C "$REPO" config core.hooksPath .githooks
git -C "$REPO" add allowed other .gitignore .githooks && git -C "$REPO" commit -qm seed && git -C "$REPO" push -q origin main

PASS=0 FAIL=0
check() {  # check <name> <0 = ok> <detail>
  if [ "$2" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 — $3"; fi
}
ok() { if "$@"; then echo 0; else echo 1; fi; }
is() { [ "$1" = "$2" ]; }
package() {  # package <attempt> [contract] [allowed] [launched_by]
  "$PY" - "$1" "${2:-wp-launch/v1}" "${3:-allowed/}" "${4:-smoke}" > "$TMP/pkg-$1.json" <<'PY'
import json, sys
print(json.dumps({"contract_version": sys.argv[2], "wp": "WP-568", "phase_id": "Ф25",
                  "attempt_id": sys.argv[1], "repo": "DS-my-strategy", "agent": "claude", "model": "sonnet",
                  "timeout_min": 5, "max_turns": 10, "prompt": "сделай фазу",
                  "allowed_paths": [sys.argv[3]], "inputs": ["allowed/existing.md"],
                  "launched_by": sys.argv[4]}))
PY
}
launch() {  # launch <attempt> <scenario> [contract] [allowed] [launched_by] -> RC, STATUS, MAN
  package "$1" "${3:-wp-launch/v1}" "${4:-allowed/}" "${5:-smoke}"
  FAKE_AGENT_SCENARIO="$2" "$PY" "$LAUNCHER" --test-mode --package "$TMP/pkg-$1.json" --runtime-dir "$RUNTIME" \
    > "$TMP/out-$1" 2> "$TMP/err-$1"
  RC=$?
  MAN="$RUNTIME/WP-568/$1/manifest.json"
  STATUS=$("$PY" -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["status"] if m.get("final") else "NOT-FINAL")' "$MAN" 2>/dev/null || echo NO-MANIFEST)
}
field() { "$PY" -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print(v)' "$MAN" "$1"; }
origin_has() { git -C "$REPO" fetch -q origin main && git -C "$REPO" cat-file -e "origin/main:$1" 2>/dev/null; }
origin_lacks() { ! origin_has "$1"; }
origin_head() { git -C "$REPO" fetch -q origin main && git -C "$REPO" rev-parse origin/main; }
close_calls() { local f; f="$FAKE_GUARD_STATE/$(field session_id).close-calls"; if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi; }
copy_at_base() { local wt; wt=$(field worktree_path); [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$(field isolated_base)" ]; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
expect() {  # expect <name> <status> <rc>
  check "$1: статус" "$(ok is "$STATUS" "$2")" "ждали $2, получили $STATUS: $(field failure_detail)"
  check "$1: код $3" "$(ok is "$RC" "$3")" "код $RC"
}
unpublished() {  # unpublished <name> <origin-before>: a refused attempt left nothing behind
  check "$1: origin не тронут" "$(ok is "$(origin_head)" "$2")" "origin сдвинулся"
  check "$1: копия возвращена к базе" "$(ok copy_at_base)" "копия не у базы"
  check "$1: сессия снята одним закрытием" "$(ok is "$(close_calls)/$(field session_open)" "1/False")" "close=$(close_calls) open=$(field session_open)"
}
json_check() { "$PY" -c "import json,sys; m=json.load(open(sys.argv[1])); sys.exit(not ($1))" "$MAN"; }

# Delivered: both files published, decisions moved out, inputs hashed, one close.
launch a1 write-allowed
expect delivered delivered 0
check "delivered: новый файл на origin" "$(ok origin_has allowed/new.md)" "allowed/new.md нет на origin"
check "delivered: решения не опубликованы" "$(ok origin_lacks .wp-launch/decisions.json)" "decisions.json на origin"
check "delivered: решения в перечне" "$(ok json_check 'm["decisions"]')" "decisions пуст"
check "delivered: найдено по метке попытки" "$(ok is "$(field publication.state)/$(field publication.method)" "confirmed/trailer")" "$(field publication)"
check "delivered: два артефакта с хэшами" "$(ok json_check 'len(m["artifacts"]) == 2 and all(a["sha256"] for a in m["artifacts"])')" "artifacts"
check "delivered: отпечаток входа" "$(ok json_check 'm["inputs"][0]["sha256"]')" "inputs"
check "delivered: pid агента в перечне" "$(ok json_check 'm["agent_pid"] > 0')" "agent_pid"
check "delivered: метки попытки в коммите" "$(ok is "$(git -C "$REPO" log -1 --format='%(trailers:key=Launch-WP,valueonly)' origin/main | head -1)" WP-568)" "нет Launch-WP"
check "delivered: один machine-close, сессия закрыта" "$(ok is "$(close_calls)/$(field session_open)" "1/False")" "close=$(close_calls)"
check "delivered: пакетная заявка двух путей" "$(ok is "$(wc -l < "$FAKE_GUARD_STATE/$(field session_id).notes" | tr -d ' ')" 2)" "note-file"

# Odd names: spaces, Cyrillic and a literal '*' are published as exactly these files.
launch a1b odd-names
expect odd-names delivered 0
check "odd-names: кириллица с пробелом на origin" "$(ok origin_has "allowed/с пробелом и кириллицей.md")" "нет файла"
check "odd-names: звёздочка как имя, не шаблон" "$(ok origin_has 'allowed/*')" "нет файла *"

# Deletion inside allowed_paths is claimed (path only in HEAD) and published.
launch a2 delete-allowed
expect delete-allowed delivered 0
check "delete-allowed: файл удалён на origin" "$(ok origin_lacks allowed/to-delete.md)" "файл остался"

# No changes: nothing published, session released.
before=$(origin_head)
launch a3 nothing
expect no-changes no-changes 0
check "no-changes: origin не тронут" "$(ok is "$(origin_head)" "$before")" "origin сдвинулся"
check "no-changes: сессия закрыта" "$(ok is "$(field session_open)" False)" "session_open=$(field session_open)"

# Refused attempts: nothing published, patch kept, copy reset, session released once.
refused() {  # refused <attempt> <scenario> <status> <rc>
  local before; before=$(origin_head)
  launch "$1" "$2"
  expect "$2" "$3" "$4"
  unpublished "$2" "$before"
}
refused a4 write-outside rejected-paths 3
check "write-outside: улика сохранена" "$(ok grep -q 'other/bad.md' "$RUNTIME/WP-568/a4/rejected.patch")" "нет в rejected.patch"
refused a5 prefix-trick rejected-paths 3
refused a6 symlink rejected-paths 3
refused a7 rename-out rejected-paths 3
refused a8 agent-commit rejected-agent-commit 3
refused a9 extra-in-wp-launch rejected-paths 3
refused a10 ignored-outside rejected-paths 3
refused a11 nested-repo rejected-paths 3
refused a12 hook-refuses commit-refused 2
check "hook-refuses: отказ проверки в журнале коммита" "$(ok grep -q 'hook: refused' "$RUNTIME/WP-568/a12/commit.log")" "нет commit.log"
refused a13 fail executor-failed 4
refused a14 max-turns max-turns 4
check "max-turns: изменения отмечены" "$(ok is "$(field changes_present)" True)" "changes_present=$(field changes_present)"
IWE_LAUNCH_TEST_TIMEOUT_SEC=2 refused a15 hang-with-child timeout 4

# Orphan child left by a finished agent is stopped before the check.
launch a16 orphan-child
sleep 4
expect orphan-child no-changes 0
check "orphan-child: поздняя запись не попала в копию" "$(ok copy_at_base)" "копия не у базы"

# The agent rewrites the copy's .git: the launcher touches nothing and keeps the session for reconciliation.
before=$(origin_head)
launch a17 tamper-git
expect tamper-git launcher-failed 2
check "tamper-git: нужна сверка" "$(ok is "$(field needs_reconcile)" True)" "needs_reconcile=$(field needs_reconcile)"
check "tamper-git: закрытие не вызывалось" "$(ok is "$(close_calls)" 0)" "close=$(close_calls)"
check "tamper-git: origin не тронут" "$(ok is "$(origin_head)" "$before")" "origin сдвинулся"

# Close fails without publication -> committed-not-published, no second close.
FAKE_CLOSE_MODE=fail launch a18 write-allowed
expect close-fail committed-not-published 5
check "close-fail: без автоповтора" "$(ok is "$(close_calls)" 1)" "вызовов $(close_calls)"
check "close-fail: публикации нет" "$(ok is "$(field publication.state)" absent)" "$(field publication)"

# Close publishes, then fails -> published-close-failed.
FAKE_CLOSE_MODE=publish-then-fail launch a19 write-allowed
expect publish-then-fail published-close-failed 5
check "publish-then-fail: без автоповтора" "$(ok is "$(close_calls)" 1)" "вызовов $(close_calls)"

# Close hangs past its deadline -> delivery-unknown, not "absent".
FAKE_CLOSE_MODE=hang IWE_LAUNCH_TEST_CLOSE_TIMEOUT_SEC=2 launch a20 write-allowed
expect close-hang delivery-unknown 5

# SIGTERM to the launcher: the agent's group is stopped, the session released, the manifest final.
package a21
FAKE_AGENT_SCENARIO=hang-with-child "$PY" "$LAUNCHER" --test-mode --package "$TMP/pkg-a21.json" --runtime-dir "$RUNTIME" \
  > "$TMP/out-a21" 2> "$TMP/err-a21" &
LPID=$!
MAN="$RUNTIME/WP-568/a21/manifest.json"
for _ in $(seq 1 50); do [ "$(field stage 2>/dev/null)" = agent-running ] && break; sleep 0.2; done
sleep 1
kill -TERM "$LPID"; wait "$LPID"; RC=$?
STATUS=$(field status)
expect sigterm launcher-failed 2
check "sigterm: перечень окончательный" "$(ok is "$(field final)" True)" "final=$(field final)"
check "sigterm: сессия снята" "$(ok is "$(close_calls)/$(field session_open)" "1/False")" "close=$(close_calls) open=$(field session_open)"
check "sigterm: агент остановлен" "$(ok pid_gone "$(field agent_pid)")" "агент $(field agent_pid) жив"

# Package refusals.
MAN="$RUNTIME/WP-568/a1/manifest.json"
sum=$(shasum "$MAN")
package a1; FAKE_AGENT_SCENARIO=write-allowed "$PY" "$LAUNCHER" --test-mode --package "$TMP/pkg-a1.json" --runtime-dir "$RUNTIME" >/dev/null 2>&1; RC=$?
check "повтор attempt_id: код 2" "$(ok is "$RC" 2)" "код $RC"
check "повтор attempt_id: перечень не тронут" "$(ok is "$(shasum "$MAN")" "$sum")" "перечень изменён"
launch a22 write-allowed wp-launch/v0
expect bad-contract launcher-failed 2
check "bad-contract: сессия не открывалась" "$(ok is "$(field session_id)" None)" "session_id=$(field session_id)"
launch a23 write-allowed wp-launch/v1 .githooks
expect forbidden-prefix launcher-failed 2
launch a24 write-allowed wp-launch/v1 allowed/ $'smoke\nLaunch-Attempt: forged'
expect forged-trailer launcher-failed 2
"$PY" - > "$TMP/pkg-evil.json" <<'PY'
import json; print(json.dumps({"contract_version": "wp-launch/v1", "wp": "WP-568", "attempt_id": "../../evil"}))
PY
"$PY" "$LAUNCHER" --test-mode --package "$TMP/pkg-evil.json" --runtime-dir "$RUNTIME" >/dev/null 2>&1; RC=$?
check "опасный attempt_id: код 2" "$(ok is "$RC" 2)" "код $RC"
check "опасный attempt_id: каталог не создан" "$(ok is "$(ls -d "$TMP/evil" "$RUNTIME/evil" 2>/dev/null)" "")" "каталог создан"

# Without --test-mode the seams are ignored: the real guard path is used (absent in this sandbox).
package a25
FAKE_AGENT_SCENARIO=write-allowed "$PY" "$LAUNCHER" --package "$TMP/pkg-a25.json" --runtime-dir "$RUNTIME" >/dev/null 2>&1
MAN="$RUNTIME/WP-568/a25/manifest.json"
check "без --test-mode подмены не действуют" "$(ok grep -q "$IWE_ROOT/scripts/session-guard.sh" "$RUNTIME/WP-568/a25/session-open.log")" "$(field failure_detail)"

echo "wp-session-launch smoke: прошло $PASS, упало $FAIL"
[ "$FAIL" = 0 ]
