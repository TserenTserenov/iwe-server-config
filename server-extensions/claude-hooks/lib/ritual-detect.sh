#!/usr/bin/env bash
# ritual-detect.sh -- shared detection of Ritual согласования block presence
# in a session transcript (TACT-01). Factored out of ritual-shown-detector.sh
# (РП-484 Ф182, 13.10.2026) so the Stop-hook observer, the warn-only
# pre-gate and the hard gate all share one signature implementation
# (ritual_signature.py) instead of drifting apart on separate copies.
#
# RITUAL_LIB_DIR must point at this file's own directory -- callers source
# it via an absolute path, so $PWD cannot be assumed.
RITUAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ritual_detect_status TRANSCRIPT_PATH -> JSON on stdout:
#   {"applies": false}                                   -- session too small to judge yet
#   {"applies": true, "ritual_status": "absent", ...}     -- no Ritual block found
#   {"applies": true, "ritual_status": "text_only", ...}
#   {"applies": true, "ritual_status": "text_and_pause", ...}
# Used by the Stop-hook observer: nontrivial-session threshold (>20 records
# AND a prior tool_use) protects it from flagging sessions long after they
# ended on trivial exchanges. Empty stdout on parse failure -- fail-open.
ritual_detect_status() {
  local transcript_path="$1"
  RITUAL_LIB_DIR="$RITUAL_LIB_DIR" TRANSCRIPT_PATH="$transcript_path" python3 <<'PY' 2>/dev/null || echo ""
import json, os, sys

sys.path.insert(0, os.environ["RITUAL_LIB_DIR"])
import ritual_signature as rs

rows = rs.read_transcript(os.environ["TRANSCRIPT_PATH"])
total_records = len(rows)
tool_use_present = any(rs.role_of(r) == "assistant" and rs.has_tool_use(r) for r in rows)

if not (total_records > 20 and tool_use_present):
    print(json.dumps({"applies": False}))
    raise SystemExit

ritual_row_idx = None
for i, r in enumerate(rows):
    if rs.role_of(r) != "assistant":
        continue
    text = rs.message_text(r)
    if text and rs.ritual_block_present(text):
        ritual_row_idx = i
        break

if ritual_row_idx is None:
    print(json.dumps({"applies": True, "ritual_status": "absent", "total_records": total_records}))
    raise SystemExit

next_tool_use_idx = None
for i in range(ritual_row_idx, total_records):
    if rs.role_of(rows[i]) == "assistant" and rs.has_tool_use(rows[i]):
        next_tool_use_idx = i
        break

pause_found = False
if next_tool_use_idx is not None:
    for i in range(ritual_row_idx + 1, next_tool_use_idx):
        if rs.role_of(rows[i]) == "user":
            pause_found = True
            break
else:
    pause_found = True

status = "text_and_pause" if pause_found else "text_only"
print(json.dumps({"applies": True, "ritual_status": status, "total_records": total_records}))
PY
}

# ritual_prompt_names_wp TRANSCRIPT_PATH -> "yes"/"no"/"error": does the
# MOST RECENT user message in the transcript explicitly name a WP
# (РП-NNN / WP-NNN pattern)? Narrow, zero-ambiguity signal for the
# hard-block path (ritual-hard-gate.sh, РП-484 Ф182, 13.10.2026): when the
# pilot names the WP themselves, which WP it is is no longer a judgment
# call, so a synchronous PreToolUse deny is safe there without first
# building the full pre-ritual bookkeeping allowlist a broader hard block
# would need. Scoped to the LATEST user message only (not the whole
# session): cold-review (13.10.2026) found that scanning every prior user
# message arms the gate for every subsequent tool call once ANY message
# ever mentioned a WP, including calls wholly unrelated to that WP --
# narrowing to "what the pilot is asking right now" matches the pilot's own
# framing ("если я номер не называю") and shrinks blast radius to the
# current request. "error" on parse failure is a distinct outcome from
# "no" -- see ritual_block_present_now below for why that distinction
# matters to the caller.
ritual_prompt_names_wp() {
  local transcript_path="$1"
  RITUAL_LIB_DIR="$RITUAL_LIB_DIR" TRANSCRIPT_PATH="$transcript_path" python3 <<'PY' 2>/dev/null || echo "error"
import os, re, sys

sys.path.insert(0, os.environ["RITUAL_LIB_DIR"])
import ritual_signature as rs

try:
    pattern = re.compile(r"\b(?:WP|РП)-\d+\b", re.IGNORECASE)
    last_user_text = ""
    for r in rs.read_transcript(os.environ["TRANSCRIPT_PATH"]):
        if rs.role_of(r) != "user" or r.get("isMeta"):
            continue
        last_user_text = rs.message_text(r)
    print("yes" if (last_user_text and pattern.search(last_user_text)) else "no")
except Exception:
    print("error")
PY
}

# ritual_block_present_now TRANSCRIPT_PATH -> "yes"/"no"/"error": does an
# assistant message ANYWHERE in the transcript so far already contain the
# Ritual signature? No nontriviality threshold (unlike ritual_detect_status)
# -- the hard gate fires on the FIRST tool call of a session, when
# total_records may still be small and no prior tool_use exists yet; that
# threshold exists only to protect the Stop-hook observer against flagging
# sessions long after they ended, which does not apply here.
#
# "error" (transcript unreadable, encoding issue, any unexpected exception)
# is a DISTINCT outcome from "no", not folded into it (cold-review
# 13.10.2026, Critical #2): ritual-hard-gate.sh's deny path must fail OPEN
# on a parse error, same as every other hook in this family (a missing jq
# field already exits 0 elsewhere) -- treating "error" as "no" would make a
# transient parse failure synchronously deny a legitimate Write/Edit/Bash
# call fleet-wide, which is a correctness bug, not a design choice.
ritual_block_present_now() {
  local transcript_path="$1"
  RITUAL_LIB_DIR="$RITUAL_LIB_DIR" TRANSCRIPT_PATH="$transcript_path" python3 <<'PY' 2>/dev/null || echo "error"
import os, sys

sys.path.insert(0, os.environ["RITUAL_LIB_DIR"])
import ritual_signature as rs

try:
    found = False
    for r in rs.read_transcript(os.environ["TRANSCRIPT_PATH"]):
        if rs.role_of(r) != "assistant":
            continue
        text = rs.message_text(r)
        if text and rs.ritual_block_present(text):
            found = True
            break
    print("yes" if found else "no")
except Exception:
    print("error")
PY
}

# ritual_prompt_wp_number TRANSCRIPT_PATH -> "WP-NNN" or "" (empty on no
# match or parse error — fail-open, same discipline as ritual_prompt_names_wp
# above). Same scope/pattern as ritual_prompt_names_wp (latest user message
# only), but returns the actual number instead of yes/no — needed by
# session-handoff-gate.sh (РП-484 Ф197, 16.10) to know WHICH WP's last
# session to check, not just that some WP was named. Multiple distinct
# numbers in one message → first match (same ambiguity the Ritual template
# itself leaves to the agent's judgment call, this gate does not referee it).
ritual_prompt_wp_number() {
  local transcript_path="$1"
  RITUAL_LIB_DIR="$RITUAL_LIB_DIR" TRANSCRIPT_PATH="$transcript_path" python3 <<'PY' 2>/dev/null || echo ""
import os, re, sys

sys.path.insert(0, os.environ["RITUAL_LIB_DIR"])
import ritual_signature as rs

try:
    pattern = re.compile(r"\b(?:WP|РП)-(\d+)\b", re.IGNORECASE)
    last_user_text = ""
    for r in rs.read_transcript(os.environ["TRANSCRIPT_PATH"]):
        if rs.role_of(r) != "user" or r.get("isMeta"):
            continue
        last_user_text = rs.message_text(r)
    m = pattern.search(last_user_text) if last_user_text else None
    print(f"WP-{m.group(1)}" if m else "")
except Exception:
    print("")
PY
}

# transcript_has_read_of TRANSCRIPT_PATH PATH_SUBSTRING -> "yes"/"no": did
# any Read tool_use in the transcript target a file_path containing this
# substring? Used by session-handoff-gate.sh to confirm the agent actually
# opened the flagged report.md, not just that the scanner printed its path.
# Fails open ("no" on parse error is safe here — caller treats "no" as
# "requirement not yet met", not as a reason to crash; the deny path it
# feeds is itself fail-open at the hook's own top-level try/except).
transcript_has_read_of() {
  local transcript_path="$1"
  local needle="$2"
  RITUAL_LIB_DIR="$RITUAL_LIB_DIR" TRANSCRIPT_PATH="$transcript_path" NEEDLE="$needle" python3 <<'PY' 2>/dev/null || echo "no"
import os, sys

sys.path.insert(0, os.environ["RITUAL_LIB_DIR"])
import ritual_signature as rs

try:
    needle = os.environ["NEEDLE"]
    found = False
    for r in rs.read_transcript(os.environ["TRANSCRIPT_PATH"]):
        if rs.role_of(r) != "assistant":
            continue
        for b in rs.text_blocks(r):
            if b.get("type") == "tool_use" and b.get("name") == "Read":
                fp = (b.get("input") or {}).get("file_path", "")
                if needle in fp:
                    found = True
                    break
        if found:
            break
    print("yes" if found else "no")
except Exception:
    print("no")
PY
}
