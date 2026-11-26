#!/usr/bin/env python3
"""UserPromptSubmit: put the pilot's own words into the WP Manager's answer box (WP-626 F7).

Why a hook: an answer to a Manager question must come from the pilot, not from
the agent (DS-my-strategy inbox/WP-626/F6/revision-2-fixes.md section 1). This
hook runs only on a message the pilot typed, so the agent cannot produce it.

Acts only in a Manager session: wp-run-journal.py marks the session in
$IWE_WP_MANAGER_STATE/sessions/<session_id>.json when the Manager takes a run lease.

  "R-12: да" / "Р-12: нет" / "R-plan: вариант 2"  -> protected/pilot-answers.jsonl
  any other message                               -> protected/pilot-messages.jsonl
                                                     (pilot intervention, H-358 number 2)

Answers are ingested into the journal by `wp-run-journal.py ingest-answers`.
The hook never blocks the prompt; on an error it says so in the context.
"""
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ANSWER_LINE = re.compile(
    r"([RrРр]-[\w-]+)\s*[:—–-]\s*(да|нет|yes|no|вариант\s*\d+)\s*[.!]?\s*",
    re.IGNORECASE,
)
REQUEST_LIKE = re.compile(r"^\s*([RrРр]-[\w-]+)\s*[:—–-]", re.MULTILINE)
WRAPPER = re.compile(
    r"</?(?:agent-message|task-notification)\b"
    r"|\[SYSTEM NOTIFICATION\b"
    r"|Another Claude session sent a message:",
    re.IGNORECASE,
)
WORDS = {"да": "yes", "yes": "yes", "нет": "no", "no": "no"}


def state_dir() -> Path:
    return Path(os.environ.get("IWE_WP_MANAGER_STATE")
                or Path.home() / ".iwe-runtime" / "wp-manager")


def normalize(word: str) -> str:
    word = word.strip().lower()
    if word in WORDS:
        return WORDS[word]
    number = re.search(r"\d+", word)
    if word.startswith("вариант") and number:
        return f"choice:{number.group()}"
    return word.replace(" ", "")


def append(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def log_event_keys(run_dir: Path, event: dict) -> None:
    path = run_dir / "protected" / "event-keys.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(path, "x", encoding="utf-8") as handle:
            handle.write(json.dumps({"keys": sorted(event)}, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    except FileExistsError:
        return


def context(text: str) -> None:
    json.dump({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                      "additionalContext": text}}, sys.stdout, ensure_ascii=False)


def answer_matches(prompt: str) -> list[re.Match]:
    return [match for line in prompt.splitlines()
            if (match := ANSWER_LINE.fullmatch(line)) is not None]


def main() -> int:
    event = json.load(sys.stdin)
    session = str(event.get("session_id") or "")
    mark = state_dir() / "sessions" / f"{session}.json"
    if not session or not mark.exists():
        return 0
    run_dir = Path(json.loads(mark.read_text(encoding="utf-8"))["run_dir"])
    prompt = str(event.get("prompt") or "")
    ref = f"{session}:{hashlib.sha256(prompt.encode('utf-8')).hexdigest()[:16]}"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_event_keys(run_dir, event)
    if WRAPPER.search(prompt):
        return 0

    matches = answer_matches(prompt)
    nonempty = [line for line in prompt.strip().splitlines() if line.strip()]
    pure_answers = bool(nonempty) and len(matches) == len(nonempty)
    found: dict[str, set] = {}
    lines: dict[str, str] = {}
    if pure_answers:
        for match in matches:
            rid = request_id(match.group(1))
            found.setdefault(rid, set()).add(normalize(match.group(2)))
            lines[rid] = match.group(0).strip()
    conflicting = sorted(rid for rid, answers in found.items() if len(answers) > 1)
    recorded = {rid: answers.pop() for rid, answers in found.items() if len(answers) == 1}
    for rid, answer in recorded.items():
        append(run_dir / "protected" / "pilot-answers.jsonl",
               {"request_id": rid, "answer": answer, "text": lines[rid], "transcript_ref": ref, "ts": now})
    if not recorded and prompt.strip():
        append(run_dir / "protected" / "pilot-messages.jsonl", {"text_ref": ref, "ts": now})

    notes = []
    if recorded:
        notes.append("Ответы пилота записаны в ящик ответов прогона: "
                     + ", ".join(f"{rid} → {answer}" for rid, answer in recorded.items())
                     + ". Забери их командой wp-run-journal.py ingest-answers.")
    if conflicting:
        notes.append(f"Противоречивые ответы на {', '.join(conflicting)} не записаны: переспроси пилота.")
    if not pure_answers:
        mixed = sorted({request_id(match.group(1)) for match in matches})
        unclear = sorted({request_id(m.group(1)) for m in REQUEST_LIKE.finditer(prompt)} - set(mixed))
        if mixed:
            notes.append(f"Ответ на {', '.join(mixed)} не записан: пришлите ответ отдельным сообщением.")
        if unclear:
            notes.append(f"Ответ на {', '.join(unclear)} не распознан как «да», «нет» или «вариант N» "
                         "без оговорок и не записан: пришлите ответ отдельным сообщением.")
    if notes:
        context(" ".join(notes))
    return 0


def request_id(raw: str) -> str:
    """Request ids are written "R-..." on cards; accept r-, Р-, р- from the pilot."""
    return "R" + raw[1:]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # a broken hook must not hide the pilot's message
        context(f"Ящик ответов Менеджера РП не записал сообщение: {error}. Скажи пилоту.")
        sys.exit(0)
