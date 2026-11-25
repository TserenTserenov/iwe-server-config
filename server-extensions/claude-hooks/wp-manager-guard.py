#!/usr/bin/env python3
"""PreToolUse guard for WP Manager runs (WP-626 F7; pilot permission 25.11.2026).

Two rules, from DS-my-strategy inbox/WP-626/F6/revision-2-fixes.md and the
pilot's decision of 25.11 ("everything in the run branch, nothing to main,
nothing deleted"):

1. In every session: only wp-run-journal.py writes a run's journal, lease,
   protected boxes and views, and the session marks. Direct file writes and
   shell commands that write them are denied; the seed and the answer boxes
   are not even read by shell commands.
2. In a Manager session (marked by wp-run-journal.py lease): no push except to
   a run/<...> branch, no force or history rewrite, no publishing gateways to
   main, no deletion.

Shell parsing is best-effort by design: the accepted residual risk is caught
by comparing pilot answers with the transcript (revision 2, section 1).
"""
import json
import os
import re
import sys
from pathlib import Path

RUN_FILE = re.compile(r"/runs/[^/\s'\"]+/(events\.jsonl|lease\.json|\.lock|protected/|views/)")
STATE = re.compile(r"\.iwe-runtime/wp-manager(/|\b)")
SECRET_NAMES = re.compile(r"pilot-answers\.jsonl|pilot-messages\.jsonl|protected/seed|\.iwe-runtime/wp-manager")
JOURNAL_CALL = re.compile(r"^\s*(?:[A-Z_]+=\S+\s+)*python3\s+\S*wp-run-journal\.py\s")
SHELL_CHAINING = re.compile(r"[;&|`>]|\$\(")
WRITE_TOKENS = re.compile(
    r">>?|\btee\b|\bsed\s+-i|\bperl\s+-i|\b(rm|mv|cp|truncate|dd|install|ln)\b|open\(|write_text|\.write\(")
DELETION = re.compile(
    r"(^|[\s;&|(])(rm|rmdir|unlink|shred)\s|\bgit\s+(rm|clean)\b|\bgit\s+branch\s+.*-[dD]\b"
    r"|\bgit\s+reset\s+--hard\b|\bgit\s+checkout\s+--\s|\bgit\s+restore\s+(?!--staged)|-delete\b")
PUSH = re.compile(r"\bgit\b[^;&|]*\bpush\b([^;&|]*)")
MAIN_GATEWAYS = re.compile(r"isolate-push\.sh|ds-publish\.sh|publish-commit|atomic-publish\.py|hot_publish_cas\.py")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")


def unquoted(command: str) -> str:
    """The command with quoted text blanked: payloads and commit messages are not commands."""
    return QUOTED.sub("''", command)


def deny(reason: str) -> None:
    json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "deny",
                                      "permissionDecisionReason": reason}}, sys.stdout, ensure_ascii=False)


def is_manager_session(session: str) -> bool:
    marks = Path(os.environ.get("IWE_WP_MANAGER_STATE")
                 or Path.home() / ".iwe-runtime" / "wp-manager") / "sessions"
    return bool(session) and (marks / f"{session}.json").exists()


def protected_path(path: str) -> bool:
    return bool(RUN_FILE.search(path) or STATE.search(path))


def check_file_tool(tool_input: dict) -> str | None:
    path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
    if protected_path(path):
        return (f"Файл прогона Менеджера РП ({path}) пишет только программа wp-run-journal.py. "
                "Используй её команды (append, ingest-answers, views).")
    return None


def journal_call_only(command: str) -> bool:
    return bool(JOURNAL_CALL.match(command)) and not SHELL_CHAINING.search(unquoted(command))


def check_shell_files(command: str) -> str | None:
    if journal_call_only(command):
        return None
    if SECRET_NAMES.search(command):
        return "Ящики ответов, зерно отбора и отметки сессий Менеджера доступны только программе wp-run-journal.py."
    if RUN_FILE.search(command) and WRITE_TOKENS.search(command):
        return "Журнал, аренду и представления прогона меняет только программа wp-run-journal.py."
    return None


def check_manager_shell(command: str) -> str | None:
    command = unquoted(command)
    if DELETION.search(command):
        return ("В сессии Менеджера РП ничего не удаляется (решение пилота 25.11): откат — новая попытка "
                "или обратный коммит в ветке прогона.")
    if MAIN_GATEWAYS.search(command):
        return "В сессии Менеджера РП публикация в главную ветку запрещена: всё идёт в ветку прогона run/…."
    for match in PUSH.finditer(command):
        args = match.group(1)
        if re.search(r"(^|\s)(-f|--force\S*|--delete|--mirror|--all|--tags)\b", args) or re.search(r"\s\+\S", args):
            return "В сессии Менеджера РП запрещены принудительная отправка и удаление веток."
        if not re.search(r"(^|[\s:])run/\S+", args) or re.search(r"\b(main|master)\b", args):
            return ("В сессии Менеджера РП отправка разрешена только в ветку прогона: "
                    "git push origin run/<run_id>. Главную ветку сливает пилот после приёмки.")
    return None


def main() -> int:
    event = json.load(sys.stdin)
    tool, tool_input = event.get("tool_name"), event.get("tool_input") or {}
    if tool == "Bash":
        command = str(tool_input.get("command") or "")
        reason = check_shell_files(command)
        if not reason and is_manager_session(str(event.get("session_id") or "")):
            reason = check_manager_shell(command)
    else:
        reason = check_file_tool(tool_input)
    if reason:
        deny(reason)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # fail closed: a guard that crashed must not let the action through
        deny(f"Проверка Менеджера РП упала ({error}); действие остановлено. Скажи пилоту.")
        sys.exit(0)
