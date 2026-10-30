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
    CLAUDE_PROJECT_DIR="$1" IWE_RUNTIME_DIR="$1/runtime" bash "$HOOK"
}

write_decl() {  # write_decl <project> <session> <intent> <ritual_agreed_at or empty>
  mkdir -p "$1/runtime/intent-declarations"
  jq -nc --arg s "$2" --arg i "$3" --arg at "$4" \
    '{session_id: $s, intent: $i, declared_at: "2026-10-29T10:00:00Z"} + (if $at != "" then {ritual: {text: "agreed", agreed_at: $at}} else {} end)' \
    > "$1/runtime/intent-declarations/$2.json"
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

# === WP-484 Ф267 п.4: Ritual stored in the conversation record counts as shown ===
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
R1="$TMP_DIR/r1"; mkdir -p "$R1/.claude/state"
write_transcript "$R1/t.jsonl" "продолжай по РП-484"
write_decl "$R1" sess-r1 WP-484 "$NOW"
check "stored Ritual for the same WP: allows" allow "$(decision_of "$(run_hook "$R1" "$R1/t.jsonl" sess-r1 Bash)")"
check "stored Ritual: writes no WP-less confirmed marker" no \
  "$([ -f "$R1/.claude/state/ritual-confirmed-sess-r1" ] && echo yes || echo no)"

R2="$TMP_DIR/r2"; mkdir -p "$R2/.claude/state"
write_transcript "$R2/t.jsonl" "продолжай по РП-485"
write_decl "$R2" sess-r2 WP-484 "$NOW"
check "stored Ritual for ANOTHER WP: still denies" deny "$(decision_of "$(run_hook "$R2" "$R2/t.jsonl" sess-r2 Bash)")"

R3="$TMP_DIR/r3"; mkdir -p "$R3/.claude/state"
write_transcript "$R3/t.jsonl" "продолжай по РП-484"
write_decl "$R3" sess-r3 WP-484 ""
check "intent declared without a Ritual: still denies" deny "$(decision_of "$(run_hook "$R3" "$R3/t.jsonl" sess-r3 Bash)")"

R4="$TMP_DIR/r4"; mkdir -p "$R4/.claude/state"
write_transcript "$R4/t.jsonl" "продолжай по РП-484"
write_decl "$R4" sess-r4 WP-484 "yesterday"
check "malformed agreed_at: still denies" deny "$(decision_of "$(run_hook "$R4" "$R4/t.jsonl" sess-r4 Bash)")"

R5="$TMP_DIR/r5"; mkdir -p "$R5/.claude/state"
write_transcript "$R5/t.jsonl" "продолжай по РП-484"
write_decl "$R5" other-session WP-484 "$NOW"
check "Ritual stored under another conversation id: still denies" deny "$(decision_of "$(run_hook "$R5" "$R5/t.jsonl" sess-r5 Bash)")"


# a record under the right file name but carrying another conversation's id
R6="$TMP_DIR/r6"; mkdir -p "$R6/.claude/state"
write_transcript "$R6/t.jsonl" "продолжай по РП-484"
write_decl "$R6" sess-r6 WP-484 "$NOW"
jq '.session_id = "other-session"' "$R6/runtime/intent-declarations/sess-r6.json" > "$R6/x.json" \
  && mv "$R6/x.json" "$R6/runtime/intent-declarations/sess-r6.json"
check "inner session_id of another conversation: still denies" deny "$(decision_of "$(run_hook "$R6" "$R6/t.jsonl" sess-r6 Bash)")"

R7="$TMP_DIR/r7"; mkdir -p "$R7/.claude/state"
write_transcript "$R7/t.jsonl" "продолжай по РП-484"
write_decl "$R7" sess-r7 WP-484 "$(date -u -v-5d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)"
check "Ritual older than 72 h: still denies" deny "$(decision_of "$(run_hook "$R7" "$R7/t.jsonl" sess-r7 Bash)")"

R8="$TMP_DIR/r8"; mkdir -p "$R8/.claude/state"
write_transcript "$R8/t.jsonl" "продолжай по РП-484"
write_decl "$R8" sess-r8 WP-484 "$(date -u -v+2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 days' +%Y-%m-%dT%H:%M:%SZ)"
check "agreed_at in the future: still denies" deny "$(decision_of "$(run_hook "$R8" "$R8/t.jsonl" sess-r8 Bash)")"

R9="$TMP_DIR/r9"; mkdir -p "$R9/.claude/state"
write_transcript "$R9/t.jsonl" "продолжай по РП-484"
write_decl "$R9" sess-r9 WP-484 "2026-99-99T99:99:99Z"
check "calendar-invalid agreed_at: still denies" deny "$(decision_of "$(run_hook "$R9" "$R9/t.jsonl" sess-r9 Bash)")"

R10="$TMP_DIR/r10"; mkdir -p "$R10/.claude/state"
write_transcript "$R10/t.jsonl" "продолжай по РП-484"
write_decl "$R10" sess-r10 WP-484 "$NOW"
jq '.ritual.text = "   "' "$R10/runtime/intent-declarations/sess-r10.json" > "$R10/x.json" \
  && mv "$R10/x.json" "$R10/runtime/intent-declarations/sess-r10.json"
check "blank Ritual text: still denies" deny "$(decision_of "$(run_hook "$R10" "$R10/t.jsonl" sess-r10 Bash)")"

R12="$TMP_DIR/r12"; mkdir -p "$R12/.claude/state"
write_transcript "$R12/t.jsonl" "продолжай по РП-484"
write_decl "$R12" sess-r12 WP-484 "2026-02-30T10:00:00Z"
check "non-existent calendar day (normalised by jq): still denies" deny "$(decision_of "$(run_hook "$R12" "$R12/t.jsonl" sess-r12 Bash)")"

R13="$TMP_DIR/r13"; mkdir -p "$R13/.claude/state"
write_transcript "$R13/t.jsonl" "продолжай по РП-484"
write_decl "$R13" sess-r13 WP-484 "$NOW"
echo '{}' >> "$R13/runtime/intent-declarations/sess-r13.json"
check "record followed by a second JSON document: still denies" deny "$(decision_of "$(run_hook "$R13" "$R13/t.jsonl" sess-r13 Bash)")"

# the agreement is per WP and re-checked on every call: same session, next WP named
R11="$TMP_DIR/r11"; mkdir -p "$R11/.claude/state"
write_transcript "$R11/t.jsonl" "продолжай по РП-484"
write_decl "$R11" sess-r11 WP-484 "$NOW"
check "same session, stored WP named: allows" allow "$(decision_of "$(run_hook "$R11" "$R11/t.jsonl" sess-r11 Bash)")"
write_transcript "$R11/t.jsonl" "а теперь РП-485"
check "same session, next WP named: denies (agreement does not carry over)" deny "$(decision_of "$(run_hook "$R11" "$R11/t.jsonl" sess-r11 Bash)")"

# === compaction summary names a WP, the pilot's own last message does not -> allow ===
C1="$TMP_DIR/c1"; mkdir -p "$C1/.claude/state"
python3 - "$C1/t.jsonl" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": "делайте"}},
    {"type": "user", "isCompactSummary": True, "message": {"content": "This session is being continued... РП-484 Ф267"}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
check "compaction summary naming a WP is not the pilot naming it: allows" allow "$(decision_of "$(run_hook "$C1" "$C1/t.jsonl" sess-c1 Bash)")"

C2="$TMP_DIR/c2"; mkdir -p "$C2/.claude/state"
python3 - "$C2/t.jsonl" <<'PY'
import json, sys
rows = [
    {"type": "user", "isCompactSummary": True, "message": {"content": "summary: РП-484 Ф267"}},
    {"type": "user", "message": {"content": "продолжай РП-484"}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
check "pilot names the WP after a compaction summary: still denies" deny "$(decision_of "$(run_hook "$C2" "$C2/t.jsonl" sess-c2 Bash)")"

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
