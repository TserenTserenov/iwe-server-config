#!/bin/bash
# test-ritual-hard-gate-narrow.sh -- ritual-hard-gate.sh (PreToolUse, narrow
# scope, РП-484 Ф182, 13.10.2026). Denies only when the PILOT themselves
# named a WP (РП-NNN/WP-NNN) in a user message AND no Ritual block has
# appeared yet in the transcript. No nontriviality threshold applies here
# (unlike ritual_detect_status / ritual-pre-gate.sh) -- it must catch the
# very first tool call of a session.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR/ritual-hard-gate.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $desc (ожидалось '$want', получено '$got')"; fi
}

write_transcript() {  # write_transcript <path> <user_text> [assistant_ritual_text]
  local path="$1" user_text="$2" ritual_text="${3:-}"
  python3 - "$path" "$user_text" "$ritual_text" <<'PY'
import json, sys
path, user_text, ritual_text = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [{"type": "user", "message": {"content": user_text}}]
if ritual_text:
    rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": ritual_text}]}})
with open(path, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

run_hook() {  # run_hook <project> <transcript> <session> <tool>
  printf '{"session_id":"%s","transcript_path":"%s","tool_name":"%s"}' "$3" "$2" "$4" |
    CLAUDE_PROJECT_DIR="$1" bash "$HOOK"
}

decision_of() {
  if printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo deny
  else
    echo allow
  fi
}

RITUAL_TEXT="> **Роль пользователя:** x
> **РП:** y
> **Целевой переход состояния:** z"

# === pilot named WP-N, no ritual shown yet -> deny ===
P1="$TMP_DIR/p1"; mkdir -p "$P1/.claude/state"
write_transcript "$P1/t.jsonl" "сделай что-то по РП-484"
check "WP named, no ritual: denies" deny "$(decision_of "$(run_hook "$P1" "$P1/t.jsonl" sess-1 Bash)")"

# === pilot named WP-N, ritual already shown -> allow, writes confirmed marker ===
P2="$TMP_DIR/p2"; mkdir -p "$P2/.claude/state"
write_transcript "$P2/t.jsonl" "сделай что-то по WP-484" "$RITUAL_TEXT"
check "WP named, ritual shown: allows" allow "$(decision_of "$(run_hook "$P2" "$P2/t.jsonl" sess-2 Bash)")"
check "WP named, ritual shown: writes its own ritual-confirmed marker" yes \
  "$([ -f "$P2/.claude/state/ritual-confirmed-sess-2" ] && echo yes || echo no)"

# === pilot did NOT name any WP -> allow (out of scope for this narrow gate) ===
P3="$TMP_DIR/p3"; mkdir -p "$P3/.claude/state"
write_transcript "$P3/t.jsonl" "сделай что-то без номера"
check "no WP named: allows (narrow scope only)" allow "$(decision_of "$(run_hook "$P3" "$P3/t.jsonl" sess-3 Bash)")"

# === already-confirmed session (own marker set) -> allow regardless ===
P4="$TMP_DIR/p4"; mkdir -p "$P4/.claude/state"
write_transcript "$P4/t.jsonl" "сделай что-то по РП-484"
touch "$P4/.claude/state/ritual-confirmed-sess-4"
check "already-confirmed session: allows (skipped)" allow "$(decision_of "$(run_hook "$P4" "$P4/t.jsonl" sess-4 Bash)")"

# === cold-review Critical #1 regression: Stop hook's ritual-checked-*
# marker (written even on "absent") must NOT disarm this gate. ===
P5="$TMP_DIR/p5"; mkdir -p "$P5/.claude/state"
write_transcript "$P5/t.jsonl" "сделай что-то по РП-484"
touch "$P5/.claude/state/ritual-checked-sess-5"
check "ritual-checked marker (Stop hook's, absent status) does not disarm this gate" deny \
  "$(decision_of "$(run_hook "$P5" "$P5/t.jsonl" sess-5 Bash)")"

# === cold-review Critical #2 regression: a transcript that raises on read
# (invalid UTF-8, not just a malformed JSON line -- read_transcript()
# already tolerates those per-line) must fail OPEN (allow), not deny, in
# BOTH ritual_prompt_names_wp and ritual_block_present_now. ===
P6="$TMP_DIR/p6"; mkdir -p "$P6/.claude/state"
printf '\xff\xfe\x00invalid utf-8 garbage\x80\x81' > "$P6/t.jsonl"
check "unreadable transcript: allows (fails open, not closed)" allow \
  "$(decision_of "$(run_hook "$P6" "$P6/t.jsonl" sess-6 Bash)")"

# === only the MOST RECENT user message is scoped in -- an old WP mention
# earlier in the session must not arm the gate for an unrelated later call
# (cold-review High #3 narrowing). ===
P7="$TMP_DIR/p7"; mkdir -p "$P7/.claude/state"
python3 - "$P7/t.jsonl" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": "сделай что-то по РП-484"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "ок"}]}},
    {"type": "user", "message": {"content": "теперь без номера, другая просьба"}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
check "old WP mention, unrelated latest message: allows" allow \
  "$(decision_of "$(run_hook "$P7" "$P7/t.jsonl" sess-7 Bash)")"

# === incident 2026-10-20: a tool-injected synthetic "user" turn (Skill
# output, isMeta=true) mentions a WP number inside its own documentation
# text -- this is NOT the pilot naming a WP and must not arm the gate. ===
P8="$TMP_DIR/p8"; mkdir -p "$P8/.claude/state"
python3 - "$P8/t.jsonl" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": "давай пройдем полную сессию стратегирования"}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_1", "name": "Skill", "input": {}}]}},
    {"type": "user", "isMeta": True, "sourceToolUseID": "toolu_1",
     "message": {"content": [{"type": "text", "text": "Base directory for this skill: /home/tseren/IWE/.claude/skills/strategy-session\n\nsee WP-481 as an example"}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
check "Skill isMeta injection mentions WP, real pilot message does not: allows" allow \
  "$(decision_of "$(run_hook "$P8" "$P8/t.jsonl" sess-8 Bash)")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
