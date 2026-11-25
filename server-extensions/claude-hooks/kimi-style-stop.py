#!/usr/bin/env python3
# claude-hook: false — Kimi Stop hook wired in ~/.kimi/config.toml and
# ~/.kimi-code/config.toml, not in settings.json; see check-orphan-hooks.sh.
"""Kimi Stop hook: route the just-finished reply through the shared style check
(РП-388 Ф21).

Kimi's Stop payload carries no reply text (only hook_event_name, session_id,
cwd, stop_hook_active), so the text is read from the session journal: the text
blocks of the last assistant message. Two homes, one hook (WP-592 F6, 25.11):
  - Kimi CLI from a terminal: ~/.kimi/sessions/<workspace>/<session_id>/context.jsonl,
    one message per row;
  - Kimi Code in VS Code: $KIMI_CODE_HOME (default ~/.kimi-code)/sessions/
    <wd_...>/<session_id>/agents/main/wire.jsonl, the message wrapped in an
    "agent.message.appended" event; session_id equals the folder name. The check itself is the shared core behind
style-check-text.sh -- this file is the Kimi-side thin entry, not a third
reimplementation (same shape as .codex/hooks/style_check_stop.py).

Wire contract (verified against kimi 1.43.0): a hook blocks by exit code 2 and
its stderr goes back to the model as the reason. Fail-open: any error here must
not block the pilot's turn.
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import tempfile

WRAPPER = os.path.expanduser("~/IWE/.claude/hooks/style-check-text.sh")
ORTHO = os.path.expanduser("~/IWE/.claude/hooks/ortho-check.py")
CLI_SESSIONS = os.path.expanduser("~/.kimi/sessions")
CODE_SESSIONS = os.path.join(os.environ.get("KIMI_CODE_HOME") or os.path.expanduser("~/.kimi-code"), "sessions")
# Kimi Code journal events that carry a whole chat message under row["message"]["message"].
CODE_MESSAGE_EVENTS = ("agent.message.appended", "context.append_message")


def find_journal(session_id: str) -> str:
    """Journal of this session in either Kimi home, or "" if there is none."""
    for pattern in (
        os.path.join(CLI_SESSIONS, "*", session_id, "context.jsonl"),
        os.path.join(CODE_SESSIONS, "*", session_id, "agents", "main", "wire.jsonl"),
    ):
        found = glob.glob(pattern)
        if found:
            return found[0]
    return ""


def _message(row: dict) -> dict:
    """The chat message of a journal row: the row itself (CLI) or the wrapped one (Kimi Code)."""
    if row.get("type") in CODE_MESSAGE_EVENTS:
        outer = row.get("message")
        inner = outer.get("message") if isinstance(outer, dict) else None
        if isinstance(inner, dict):
            return inner
        return outer if isinstance(outer, dict) else {}
    return row


def last_assistant_text(journal_path: str) -> str:
    """Text blocks of the last assistant message that has any (tool-call-only
    messages and the thinking blocks are skipped)."""
    last = ""
    with open(journal_path, encoding="utf-8") as fh:
        for line in fh:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            row = _message(row)
            if row.get("role") != "assistant":
                continue
            content = row.get("content")
            if isinstance(content, str):
                text = content
            else:
                text = "".join(
                    block.get("text", "")
                    for block in content or []
                    if isinstance(block, dict) and block.get("type") == "text"
                )
            if text.strip():
                last = text
    return last


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("stop_hook_active"):
        return 0  # a rewrite was already requested this turn: never ask twice

    session_id = str(payload.get("session_id") or "")
    if not session_id or "/" in session_id or not os.access(WRAPPER, os.X_OK):
        return 0
    journal = find_journal(session_id)
    if not journal:
        return 0
    text = last_assistant_text(journal)
    if not text:
        return 0

    # РП-388 Ф26 (расширение 05.11, запрос пилота «исправить системно»):
    # орфография — журнал + напоминание агенту ДО показа ответа пилоту.
    # Пилот видит только итоговый ответ; напоминание — через механику Ф21
    # (exit 2 + stderr), guard stop_hook_active не даст попросить дважды за ход.
    # До стилевой проверки: даже ответ, который стиль заблокирует, должен
    # попасть в орфо-журнал. В пир-режиме ortho-check.py сам молчит
    # (проверку там делает адаптер, Ф24). Fail-open внутри, timeout 8с, чтобы
    # вместе со стилем (10с) уложиться в лимит хука (20с).
    ortho_flags: list[str] = []
    if os.path.isfile(ORTHO):
        ortho_tmp = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", suffix=".txt", delete=False
            ) as of:
                of.write(text)
                ortho_tmp = of.name
            ortho_done = subprocess.run(
                ["python3", ORTHO, "kimi", ortho_tmp],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=8,
                check=False,
            )
            ortho_flags = [
                line.strip() for line in (ortho_done.stdout or "").splitlines() if line.strip()
            ][:10]
        except Exception:
            pass
        finally:
            if ortho_tmp:
                try:
                    os.unlink(ortho_tmp)
                except OSError:
                    pass

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".txt", delete=False
        ) as fh:
            fh.write(text)
            tmp_path = fh.name
        done = subprocess.run(
            ["bash", WRAPPER, "kimi", tmp_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
            env={**os.environ, "STYLE_WRAPPER_EMIT": "1"},
        )
        decision = json.loads(done.stdout or "{}")
    except Exception:
        return 0
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    if isinstance(decision, dict) and decision.get("decision") == "block":
        print(decision.get("reason", ""), file=sys.stderr)
        return 2
    if ortho_flags:
        words = ", ".join(ortho_flags)
        print(
            f"ОРФО: в предыдущем ответе подозрительные слова — {words}. "
            "Проверь и исправь; если слово корректное, заверши ход повторно.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
