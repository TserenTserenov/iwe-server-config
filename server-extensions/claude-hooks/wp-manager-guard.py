#!/usr/bin/env python3
"""PreToolUse guard for WP Manager runs (WP-626 F7; pilot permission 25.11.2026).

Two rules, from DS-my-strategy inbox/WP-626/F6/revision-2-fixes.md and the
pilot's decision of 25.11 ("everything in the run branch, nothing to main,
nothing deleted"):

1. In every session: only wp-run-journal.py writes a run's journal, lease and
   protected boxes, and the session marks; shell commands do not read the
   protected boxes and the seed; a journal call may not override its clock,
   host, state folder or session id through the environment.
2. In a Manager session (marked by wp-run-journal.py lease): no shell
   wrappers, no push except explicit run/<id> refspecs, no force or branch
   deletion, no merge through gh, no publishing gateways to main, no deletion.

Shell parsing is best-effort by design: the accepted residual risk is caught
by comparing pilot answers with the transcript (revision 2, section 1).
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path

# wp-run-journal.py accepts run folders only at inbox/WP-<N>/runs/<run_id>, so other "runs/" folders are not ours.
RUN_FILE = re.compile(r"WP-\d+/runs/[^/\s'\"]+/(?:events\.jsonl|lease\.json|\.lock|protected/)")
STATE_DIR = re.compile(r"\.iwe-runtime/wp-manager(?:/|$|[\s'\"])")
PROTECTED_READ = re.compile(r"protected/(?:pilot-answers\.jsonl|pilot-messages\.jsonl|seed(?=$|[\s'\";&|)]))")
JOURNAL_CALL = re.compile(r"^\s*python3\s+\S*wp-run-journal\.py\s")
JOURNAL_ENV = re.compile(
    r"(?:\b(?:WP_RUN_JOURNAL_NOW|IWE_WP_MANAGER_(?:STATE|HOST)|CLAUDE_CODE_SESSION_ID)=)"
    r"|\b(?:unset|env\s+-u)\s+(?:WP_RUN_JOURNAL_NOW|IWE_WP_MANAGER_(?:STATE|HOST)|CLAUDE_CODE_SESSION_ID)\b")
SHELL_CHAINING = re.compile(r"[;&|`>\n]|\$\(")
WRITE_TOKENS = re.compile(
    r"(?<![0-9&>])>{1,2}(?!&)|\btee\b|\bsed\s+-i|\bperl\s+-i|\b(?:rm|mv|cp|truncate|dd|install|ln)\b"
    r"|open\(|write_text|\.write\(")
RUN_PATH = r"[^\s'\";&|]*WP-\d+/runs/[^/\s'\"]+/(?:events\.jsonl|lease\.json|\.lock|protected/)"


def writes_into(path_pattern: str) -> re.Pattern:
    """Writes INTO a path: redirection to it, an in-place editor or mv on it, or it as the last cp/ln operand."""
    return re.compile(
        rf"(?<![0-9&>])>{{1,2}}\s*['\"]?{path_pattern}"
        rf"|\b(?:tee|truncate|dd|rm|shred|unlink|mv|sed\s+-i|perl\s+-i)\b[^;&|]*{path_pattern}"
        rf"|\b(?:cp|ln|install)\b[^;&|]*\s['\"]?{path_pattern}[^\s;&|]*\s*(?:$|[;&|])")


RUN_FILE_WRITE = writes_into(RUN_PATH)
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")


def _blank_quoted(match: re.Match) -> str:
    text = match.group(0)
    # "$(cmd)" and "`cmd`" run cmd: keep it visible, except a heredoc commit message "$(cat <<'EOF' ...)".
    if text.startswith('"') and ("$(" in text or "`" in text) and not text.startswith('"$(cat <<'):
        return text[1:-1]
    return "''"
GIT_GLOBAL_OPTS = re.compile(r"\bgit((?:\s+(?:-C|-c|--git-dir|--work-tree)(?:=|\s+)\S+)+)")
WRAPPERS = re.compile(
    r"(?:^|[\s;&|(/])(?:bash|sh|zsh|dash|ksh)(?:\s+(?:-[A-Za-z]*o\s+\w+|-[A-Za-z]+|--[\w-]+))*?\s+-[A-Za-z]*c[A-Za-z]*\b"
    r"|--run(?![\w-])|--command(?![\w-])|\beval\b|\bxargs\b|\bsource\b|(?:^|[;&|]\s*)\.\s"
    r"|\bpython3?\s+-\w*c\b|\bperl\s+-\w*e\b|\bnode\s+-e\b")
DELETION = re.compile(
    r"(?:^|[\s;&|(/])(?:rm|rmdir|unlink|shred)\s|\bgit\s+(?:rm|clean)\b|\bgit\s+branch\s+.*(?:-[dD]\b|--delete\b)"
    r"|\bgit\s+stash\s+(?:drop|clear)\b"
    r"|\bgit\s+reset\s+--hard\b|\bgit\s+checkout\s+--\s|\bgit\s+restore\s+(?!--staged)|-delete\b")
GH_MERGE = re.compile(r"\bgh\s+pr\s+merge\b|\bgh\s+api\b.*\bmerges?\b|\bgh\s+repo\s+delete\b")
MAIN_GATEWAYS = re.compile(r"isolate-push\.sh|ds-publish\.sh|publish-commit|atomic-publish\.py|hot_publish_cas\.py")
PUSH_BAD_OPTS = {"-f", "-d", "--delete", "--mirror", "--all", "--tags", "--prune"}


def deny(reason: str) -> None:
    json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "deny",
                                      "permissionDecisionReason": reason}}, sys.stdout, ensure_ascii=False)


def unquoted(command: str) -> str:
    """The command with quoted text blanked: payloads and commit messages are not commands."""
    return QUOTED.sub(_blank_quoted, command)


def is_manager_session(session: str) -> bool:
    marks = Path(os.environ.get("IWE_WP_MANAGER_STATE")
                 or Path.home() / ".iwe-runtime" / "wp-manager") / "sessions"
    return bool(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", session)) and (marks / f"{session}.json").exists()


def check_file_tool(tool_input: dict) -> str | None:
    path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
    if RUN_FILE.search(path) or STATE_DIR.search(path):
        return (f"Файл прогона Менеджера РП ({path}) пишет только программа wp-run-journal.py. "
                "Используй её команды (append, ingest-answers, views).")
    return None


def check_shell_files(command: str) -> str | None:
    if "wp-run-journal" in command and JOURNAL_ENV.search(unquoted(command)):
        return "Вызов wp-run-journal.py не может подменять часы, машину, папку отметок или номер сессии."
    if JOURNAL_CALL.match(command) and not SHELL_CHAINING.search(unquoted(command)):
        return None
    if PROTECTED_READ.search(unquoted(command)) or STATE_DIR.search(unquoted(command)):
        return "Ящики ответов, зерно отбора и отметки сессий Менеджера доступны только программе wp-run-journal.py."
    if RUN_FILE_WRITE.search(unquoted(command)):
        return "Журнал и аренду прогона меняет только программа wp-run-journal.py."
    return None


def run_destination(refspec: str) -> bool:
    """The refspec writes only to a run/<id> branch (any source, no deletion, no force)."""
    if refspec.startswith("+"):
        return False
    source, _, target = refspec.rpartition(":") if ":" in refspec else ("", "", refspec)
    if ":" in refspec and not source:
        return False  # ":run/x" deletes the branch
    return bool(re.fullmatch(r"(?:refs/heads/)?run/[A-Za-z0-9._-]+", target))


def push_problem(segment: str) -> str | None:
    """Check one `git push ...` segment: only explicit run/<id> refspecs, no force or deletion."""
    try:
        words = shlex.split(segment)
    except ValueError:
        return "Команду git push не удалось разобрать; в сессии Менеджера она не выполняется."
    args = words[words.index("push") + 1:]
    options = [a for a in args if a.startswith("-")]
    positional = [a for a in args if not a.startswith("-")]
    short_bad = any(not o.startswith("--") and re.search(r"[fd]", o[1:]) for o in options)
    if short_bad or any(o in PUSH_BAD_OPTS or o.startswith("--force") for o in options):
        return "В сессии Менеджера РП запрещены принудительная отправка и удаление веток."
    refspecs = positional[1:]
    if not refspecs or not all(run_destination(r) for r in refspecs):
        return ("В сессии Менеджера РП отправка разрешена только явно в ветку прогона: "
                "git push origin run/<run_id>. Главную ветку сливает пилот после приёмки.")
    return None


def marked_run_dir(session: str) -> str:
    marks = Path(os.environ.get("IWE_WP_MANAGER_STATE")
                 or Path.home() / ".iwe-runtime" / "wp-manager") / "sessions"
    return json.loads((marks / f"{session}.json").read_text(encoding="utf-8")).get("run_dir", "")


def check_run_dir_access(command: str, run_dir: str) -> str | None:
    """A Manager session does not cd into or write inside its run folder by hand."""
    if not run_dir or (JOURNAL_CALL.match(command) and not SHELL_CHAINING.search(unquoted(command))):
        return None
    run_id = Path(run_dir).name
    folder = rf"[^\s'\";&|]*(?:{re.escape(run_dir)}|runs/{re.escape(run_id)})(?:/|\b)"
    entered = re.search(r"\b(?:cd|pushd)\b", command) and run_id in command
    touched_protected = "protected" in command and (run_dir in command or f"runs/{run_id}" in command)
    relative = rf"(?<![\w/-]){re.escape(run_id)}/(?:events\.jsonl|lease\.json|\.lock|protected/)"
    aliased = re.search(rf"\b\w+=['\"]?{folder}", command) and WRITE_TOKENS.search(unquoted(command))
    if entered or touched_protected or aliased or writes_into(folder).search(command) \
            or writes_into(relative).search(command):
        return "В сессии Менеджера РП в папку прогона не заходят и не пишут руками — только через wp-run-journal.py."
    return None


def check_manager_shell(command: str) -> str | None:
    command = GIT_GLOBAL_OPTS.sub("git", unquoted(command))
    if WRAPPERS.search(command):
        return "В сессии Менеджера РП запрещены обёртки команд (bash -c, eval, xargs, python -c и подобные)."
    if DELETION.search(command):
        return ("В сессии Менеджера РП ничего не удаляется (решение пилота 25.11): откат — новая попытка "
                "или обратный коммит в ветке прогона.")
    if GH_MERGE.search(command) or MAIN_GATEWAYS.search(command):
        return "В сессии Менеджера РП слияние и публикация в главную ветку запрещены: всё идёт в ветку прогона run/…."
    for segment in re.split(r"[;&|\n]+", command):
        if re.search(r"\bgit\s+push\b", segment):
            problem = push_problem(segment.strip())
            if problem:
                return problem
    return None


def main() -> int:
    event = json.load(sys.stdin)
    tool = event.get("tool_name")
    tool_input = event.get("tool_input") if isinstance(event.get("tool_input"), dict) else {}
    if tool == "Bash":
        command = str(tool_input.get("command") or "")
        reason = check_shell_files(command)
        session = str(event.get("session_id") or "")
        if not reason and is_manager_session(session):
            reason = check_run_dir_access(command, marked_run_dir(session)) or check_manager_shell(command)
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
