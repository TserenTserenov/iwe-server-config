#!/usr/bin/env python3
"""Is the prompt being recorded a ScheduleWakeup prompt? (WP-484 I-47)

Called by pilot-witness-recorder.sh with the conversation transcript (JSONL) as the
argument and the prompt text in WITNESS_PROMPT. Prints one word:

  skip      -- direct sign: the transcript's latest prompt entry has this exact text,
               is marked as a wakeup (wakeupSource set or turnOrigin == "scheduled")
               and was written at most FRESH_SECONDS ago;
  suspected -- no direct sign, but the text equals the prompt of a ScheduleWakeup
               call in this transcript (recorded anyway, marked for diagnostics);
  keep      -- neither.

The latest prompt entry is the last user entry with text content in the transcript's
tail, whatever its text: if the current message is not written yet, that entry is an
older one and the verdict is never "skip" (a pilot reply equal to an earlier wakeup
text is kept). Only lines that contain "ScheduleWakeup" or "user" are parsed.
"""
import json
import os
import sys
from datetime import datetime, timezone

FRESH_SECONDS = 10
# The current prompt, if already written, is at the very end; 2 MB holds many turns.
TAIL_BYTES = 2_000_000


def _prompt_text(entry):
    """Text of a user prompt entry; None for tool results and other non-prompt entries."""
    if entry.get("type") != "user":
        return None
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list) and content and all(
            isinstance(part, dict) and part.get("type") == "text" for part in content):
        return "".join(part.get("text", "") for part in content)
    return None


def _scheduled_prompts(entry):
    if entry.get("type") != "assistant":
        return []
    content = (entry.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    return [part.get("input", {}).get("prompt") for part in content
            if isinstance(part, dict) and part.get("type") == "tool_use"
            and part.get("name") == "ScheduleWakeup"]


def _age_seconds(stamp, now):
    try:
        written = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return None
    return (now - written).total_seconds()


def _entries(lines, needle):
    """JSON objects of the lines that contain the byte string needle (cheap prefilter)."""
    for raw in lines:
        if needle not in raw:
            continue
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if isinstance(entry, dict):
            yield entry


def _latest_prompt_entry(transcript_path):
    """The last user prompt entry in the tail of the transcript (None if the tail has none)."""
    latest = None
    with open(transcript_path, "rb") as fh:
        size = fh.seek(0, os.SEEK_END)
        fh.seek(max(0, size - TAIL_BYTES))
        if size > TAIL_BYTES:
            fh.readline()  # drop the partial first line
        for entry in _entries(fh, b'"user"'):
            if _prompt_text(entry) is not None:
                latest = entry
    return latest


def verdict(transcript_path, prompt, now=None):
    now = now or datetime.now(timezone.utc)
    wanted = prompt.strip()
    with open(transcript_path, "rb") as fh:
        scheduled = any(isinstance(p, str) and p.strip() == wanted
                        for entry in _entries(fh, b"ScheduleWakeup") for p in _scheduled_prompts(entry))
    latest = _latest_prompt_entry(transcript_path)
    if latest is not None and (_prompt_text(latest) or "").strip() == wanted \
            and (latest.get("wakeupSource") or latest.get("turnOrigin") == "scheduled"):
        age = _age_seconds(latest.get("timestamp"), now)
        if age is not None and -FRESH_SECONDS <= age <= FRESH_SECONDS:
            return "skip"
    return "suspected" if scheduled else "keep"


def main():
    if len(sys.argv) != 2:
        print("usage: wakeup_prompt_check.py <transcript.jsonl>  (prompt in WITNESS_PROMPT)", file=sys.stderr)
        return 2
    print(verdict(sys.argv[1], os.environ.get("WITNESS_PROMPT", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
