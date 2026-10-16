#!/bin/bash
# test-session-handoff-gate.sh -- session-handoff-gate.sh (PreToolUse,
# narrow scope, РП-484 Ф197, 16.10.2026, прямое поручение пилота).
# Денит Write/Edit/MultiEdit, когда пилот явно назвал WP, у этого WP есть
# последняя сессия со статусом "report.md есть", и агент ещё не вызывал
# Read на её report.md. Не трогает Bash/Read и РП без такого статуса.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/session-handoff-gate.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $desc (ожидалось '$want', получено '$got')"; fi
}

write_transcript() {  # write_transcript <path> <user_text> [read_file_path]
  local path="$1" user_text="$2" read_path="${3:-}"
  python3 - "$path" "$user_text" "$read_path" <<'PY'
import json, sys
path, user_text, read_path = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [{"type": "user", "message": {"content": user_text}}]
if read_path:
    rows.append({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "r1", "name": "Read", "input": {"file_path": read_path}}
    ]}})
with open(path, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

# Строит изолированный IWE_ROOT с .iwe-runtime/sessions/<name>.open +
# MC-sessions/<folder>/report.md -- та же пара файлов, которую реальный
# wp-session-journal-gaps.py читает со своего сканера (parse_semaphore +
# report_status), только в песочнице, не в боевых данных.
make_sandbox_session() {  # make_sandbox_session <root> <wp> <folder> <has_report:yes|no>
  local root="$1" wp="$2" folder="$3" has_report="$4"
  mkdir -p "$root/.iwe-runtime/sessions" "$root/MC-sessions/$folder"
  cat > "$root/.iwe-runtime/sessions/sem-$(basename "$folder").closed" <<EOF
wp: $wp
session_id: $(basename "$folder")
opened_at: 2026-10-16T07:00:00Z
file: $folder/report.md
EOF
  [ "$has_report" = "yes" ] && echo "# report" > "$root/MC-sessions/$folder/report.md"
}

run_hook() {  # run_hook <iwe_root> <transcript> <session_id> <tool>
  printf '{"session_id":"%s","transcript_path":"%s","tool_name":"%s","tool_input":{"file_path":"/tmp/x.md"}}' "$3" "$2" "$4" |
    CLAUDE_PROJECT_DIR="$1" IWE_ROOT="$1" IWE_SCRIPTS="$HOME/IWE/scripts" IWE_SESSIONS_ROOT="$1/MC-sessions" \
    bash "$HOOK"
}

decision_of() {
  if printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo deny
  else
    echo allow
  fi
}

# === last session has report.md, no Read yet -> deny ===
P1="$TMP_DIR/p1"; mkdir -p "$P1/.claude/state"
make_sandbox_session "$P1" "WP-900" "2026-10/16/wp900-session-a" "yes"
write_transcript "$P1/t.jsonl" "продолжи РП-900"
check "report.md есть, не прочитан: denies" deny "$(decision_of "$(run_hook "$P1" "$P1/t.jsonl" sess-1 Edit)")"

# === same, but Read already happened -> allow + marker ===
P2="$TMP_DIR/p2"; mkdir -p "$P2/.claude/state"
make_sandbox_session "$P2" "WP-900" "2026-10/16/wp900-session-a" "yes"
write_transcript "$P2/t.jsonl" "продолжи РП-900" "$P2/MC-sessions/2026-10/16/wp900-session-a/report.md"
check "report.md есть, прочитан: allows" allow "$(decision_of "$(run_hook "$P2" "$P2/t.jsonl" sess-2 Edit)")"
check "writes its own confirmed marker" yes \
  "$([ -f "$P2/.claude/state/handoff-confirmed-sess-2-WP-900" ] && echo yes || echo no)"

# === no prior sessions at all for this WP -> allow ===
P3="$TMP_DIR/p3"; mkdir -p "$P3/.claude/state" "$P3/.iwe-runtime/sessions" "$P3/MC-sessions"
write_transcript "$P3/t.jsonl" "продолжи РП-901"
check "no prior sessions: allows" allow "$(decision_of "$(run_hook "$P3" "$P3/t.jsonl" sess-3 Edit)")"

# === last session is a draft/missing report (gap), not "report.md есть" -> allow (out of scope) ===
P4="$TMP_DIR/p4"; mkdir -p "$P4/.claude/state"
make_sandbox_session "$P4" "WP-902" "2026-10/16/wp902-session-a" "no"
write_transcript "$P4/t.jsonl" "продолжи РП-902"
check "gap status (no report.md): allows, out of this gate's scope" allow "$(decision_of "$(run_hook "$P4" "$P4/t.jsonl" sess-4 Edit)")"

# === Bash is out of scope entirely, even unread report.md ===
P5="$TMP_DIR/p5"; mkdir -p "$P5/.claude/state"
make_sandbox_session "$P5" "WP-900" "2026-10/16/wp900-session-a" "yes"
write_transcript "$P5/t.jsonl" "продолжи РП-900"
check "Bash tool: out of scope, allows" allow "$(decision_of "$(run_hook "$P5" "$P5/t.jsonl" sess-5 Bash)")"

# === Read itself is never blocked (it's the compliance action) ===
P6="$TMP_DIR/p6"; mkdir -p "$P6/.claude/state"
make_sandbox_session "$P6" "WP-900" "2026-10/16/wp900-session-a" "yes"
write_transcript "$P6/t.jsonl" "продолжи РП-900"
check "Read tool: out of scope, allows" allow "$(decision_of "$(run_hook "$P6" "$P6/t.jsonl" sess-6 Read)")"

# === no WP named -> allow (narrow scope) ===
P7="$TMP_DIR/p7"; mkdir -p "$P7/.claude/state"
write_transcript "$P7/t.jsonl" "сделай что-то без номера"
check "no WP named: allows" allow "$(decision_of "$(run_hook "$P7" "$P7/t.jsonl" sess-7 Edit)")"

# === already-confirmed session+WP -> allow regardless, scanner not re-run ===
P8="$TMP_DIR/p8"; mkdir -p "$P8/.claude/state"
make_sandbox_session "$P8" "WP-900" "2026-10/16/wp900-session-a" "yes"
touch "$P8/.claude/state/handoff-confirmed-sess-8-WP-900"
write_transcript "$P8/t.jsonl" "продолжи РП-900"
check "already-confirmed: allows without re-scanning" allow "$(decision_of "$(run_hook "$P8" "$P8/t.jsonl" sess-8 Edit)")"

# === unreadable transcript -> fail open (allow) ===
P9="$TMP_DIR/p9"; mkdir -p "$P9/.claude/state"
printf '\xff\xfe\x00invalid utf-8 garbage\x80\x81' > "$P9/t.jsonl"
check "unreadable transcript: fails open (allows)" allow "$(decision_of "$(run_hook "$P9" "$P9/t.jsonl" sess-9 Edit)")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
