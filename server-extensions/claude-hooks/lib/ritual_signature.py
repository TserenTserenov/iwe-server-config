"""Shared Ritual-block signature matching (TACT-01).

Single source of truth for "does this transcript text contain the Ritual
согласования block" (protocol-open.md §Ритуал согласования, Шаг 1) --
reused by ritual-detect.sh's bash functions so the Stop-hook observer, the
warn-only pre-gate, and the hard gate never drift apart on what counts as
"shown".
"""
import json
import re

FIELD_PATTERNS = [
    re.compile(r"^>\s*\*\*Роль\s+(пользователя|Claude)\s*:\*\*", re.IGNORECASE | re.MULTILINE),
    re.compile(r"^>\s*\*\*РП\s*:\*\*", re.IGNORECASE | re.MULTILINE),
    re.compile(r"^>\s*\*\*Целевой переход состояния\s*:\*\*", re.IGNORECASE | re.MULTILINE),
]
PROXIMITY_WINDOW_LINES = 15


def ritual_block_present(text):
    """All three field labels present within one 15-line window of text."""
    lines = text.split("\n")
    match_lines = []
    for pattern in FIELD_PATTERNS:
        found_at = None
        for i, line in enumerate(lines):
            if pattern.search(line):
                found_at = i
                break
        if found_at is None:
            return False
        match_lines.append(found_at)
    return max(match_lines) - min(match_lines) <= PROXIMITY_WINDOW_LINES


def role_of(record):
    return record.get("type") or record.get("role") or ""


def text_blocks(record):
    content = record.get("message", {}).get("content", record.get("content", []))
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def has_tool_use(record):
    return any(b.get("type") == "tool_use" for b in text_blocks(record))


def message_text(record):
    return "\n".join(b.get("text", "") for b in text_blocks(record) if b.get("type") == "text")


def read_transcript(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    return rows
