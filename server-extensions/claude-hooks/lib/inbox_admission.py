#!/usr/bin/env python3
"""Inbox admission gate: logic behind .claude/hooks/inbox-admission-gate.sh.

WP-561 Ф94 part 2 (pilot decision 28.11.2026, design agreed with Codex in a
peer session). The hook is the only caller. It runs in interactive Claude Code
sessions (hooks of .claude/settings.json); Codex and Kimi do not read that
file, so they are NOT covered by this gate.

Both commands print one JSON object and exit 0. Any other exit code is an
internal failure, which the hook turns into a logged allow (the gate must never
lock the pilot out because of its own bug).

  prepare --view FILE
      stdin: the PreToolUse input. A call that is allowed before admission
      whatever the WP is (reads, the triage commands, see bash_allowed) gives
      {"action": "allow"} without touching the transcript. Otherwise the latest
      message the pilot typed is written to FILE (JSONL, at most one record),
      so lib/ritual-detect.sh can run its shared WP detection over the pilot's
      own words only, and the answer is
      {"action": "check", "target_wp": "WP-N" or "", "blocked": "<the call>"}.

  admit --wp WP-N ...
      Checks admission for the named WP against the server inbox, the working
      copies of this conversation and its deferral record:
      {"decision": "allow"|"deny", "basis": "...", "message": "..."}.
"""

import argparse
import glob
import hashlib
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import time
import unicodedata

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
CODE_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(LIB_DIR)))
sys.path.insert(0, LIB_DIR)
import ritual_signature as rs

SHA_RE = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
SERVER_HEADER_RE = re.compile(r"^## И-(\d+) · (.*)$")
SUMMARY_RE = re.compile(r"^Выжимка: (.*)$")
CARD_PATH_RE = re.compile(r"(?:^|/)inbox/WP-(\d+)/(?:WP-(\d+)\.md|INBOX\.md)$")


class NotAllowed(Exception):
    """A Bash command outside the pre-admission allowlist; the text says why."""


class ReadError(Exception):
    """The server inbox could not be read; never treated as "no entries"."""


# --------------------------------------------------------------------------
# Transcript: the pilot's own messages
# --------------------------------------------------------------------------


def is_pilot_message(record):
    """True for a message the pilot typed himself.

    Claude Code also stores tool results, background-task notifications,
    subagent hand-backs, skill text and compaction summaries as "user"
    records. None of them are the pilot's words: ritual_prompt_wp_number taken
    over the raw transcript resets to "no WP" on the first tool result of a
    turn, and a quote found in a tool result could be the agent's own echo.
    """
    try:
        if not isinstance(record, dict) or rs.role_of(record) != "user":
            return False
        if (
            record.get("isMeta")
            or record.get("isCompactSummary")
            or record.get("isSidechain")
        ):
            return False
        origin = record.get("origin")
        if origin is not None and not (
            isinstance(origin, dict) and origin.get("kind") == "human"
        ):
            return False
        return not any(b.get("type") == "tool_result" for b in rs.text_blocks(record))
    except (
        TypeError,
        AttributeError,
        KeyError,
    ):  # malformed JSON shape is not a pilot message
        return False


def _parse_line(raw):
    raw = raw.strip()
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None


def latest_pilot_record(path, chunk=1 << 16):
    """The last pilot message of a JSONL transcript, read from the end."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        head = b""
        while pos > 0:
            step = min(chunk, pos)
            pos -= step
            f.seek(pos)
            lines = (f.read(step) + head).split(b"\n")
            head = lines[0]  # may be cut in the middle; completed by the next read
            for raw in reversed(lines[1:]):
                record = _parse_line(raw)
                if record is not None and is_pilot_message(record):
                    return record
        record = _parse_line(head)
        if record is not None and is_pilot_message(record):
            return record
    return None


def _normalize(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е")
    return " ".join(text.split())


QUOTE_EDGE_CHARS = " «»\"'“”„‘’.,;:!?…()[]"


def quote_found(quote, texts):
    """The quote occurs in one of the texts as whole words (case and spaces ignored)."""
    needle = _normalize(quote).strip(QUOTE_EDGE_CHARS)
    if not any(ch.isalnum() for ch in needle):
        return False
    for text in texts:
        hay = _normalize(text)
        start = hay.find(needle)
        while start >= 0:
            end = start + len(needle)
            before = hay[start - 1] if start > 0 else " "
            after = hay[end] if end < len(hay) else " "
            if not before.isalnum() and not after.isalnum():
                return True
            start = hay.find(needle, start + 1)
    return False


# --------------------------------------------------------------------------
# Calls allowed before admission
# --------------------------------------------------------------------------

ENV_PREFIX_ALLOWED = frozenset(
    ("IWE_GOVERNANCE_REPO_PATH", "IWE_GOVERNANCE_REPO", "IWE_WORKSPACE", "IWE_AGENT")
)
# Commands that only read or print. echo/pwd/true change nothing either; they are
# here so that `grep … || true` and `echo ---` separators do not fail a chain.
PLAIN_READERS = frozenset(
    ("cat", "grep", "egrep", "fgrep", "head", "tail", "ls", "wc", "echo", "pwd", "true")
)
GIT_READ_SUBCOMMANDS = frozenset(
    ("fetch", "log", "show", "status", "diff", "rev-parse", "ls-tree", "cat-file")
)
# The triage itself; None = any arguments.
TRIAGE_SCRIPTS = {
    "wp-inbox.sh": frozenset(("list", "count", "digest", "mark")),
    "declare-intent.sh": None,
    "session-guard.sh": frozenset(("open", "note-file")),
    "wp-sync-bundle.sh": None,
    "wp-reopen-gate.sh": None,
}
INTERPRETERS = frozenset(("bash", "sh"))
SYSTEM_BIN_DIRS = frozenset(
    (
        "/bin",
        "/usr/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/run/current-system/sw/bin",
    )
)
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# `sed -n` scripts limited to printing line ranges: `w`, `e` and `s///w` would write or run.
SED_PRINT_RE = re.compile(r"^(?:\s*(?:\d+|\$)(?:\s*,\s*(?:\d+|\$))?\s*[pq]\s*;?)+\s*$")
SEPARATOR_CHARS = " \t\r\n;&|"

ALLOWLIST_TEXT = (
    "Read, Grep, Glob; в Bash: wp-inbox.sh list|count|digest|mark, declare-intent.sh, "
    "session-guard.sh open|note-file, wp-sync-bundle.sh, wp-reopen-gate.sh, "
    "git fetch|log|show|status|diff|rev-parse|ls-tree|cat-file, cat, sed -n 'N,Mp', grep, "
    "head, tail, ls, wc, echo, pwd, true (цепочки через &&, ;, | только из этих команд, "
    "без подстановки $(...) и без вывода в файл, кроме /dev/null)"
)


def _braced_end(cmd, i):
    """cmd[i:i+2] == '${': index after the matching '}' (no quotes or substitutions inside)."""
    depth, j, n = 1, i + 2, len(cmd)
    while j < n and depth:
        ch = cmd[j]
        if ch in "'\"\\`":
            raise NotAllowed("кавычки или подстановка внутри ${...}")
        if ch == "$" and cmd[j + 1 : j + 2] in ("(", "["):
            raise NotAllowed("подстановка команды $(...)")
        if ch == "$" and cmd[j + 1 : j + 2] == "{":
            depth += 1
            j += 2
            continue
        if ch == "}":
            depth -= 1
        j += 1
    if depth:
        raise NotAllowed("незакрытая ${...}")
    return j


def _dollar(cmd, i, word):
    nxt = cmd[i + 1 : i + 2]
    if nxt in ("(", "["):
        raise NotAllowed("подстановка команды $(...)")
    if nxt == "{":
        end = _braced_end(cmd, i)
        word.append(cmd[i:end])
        return end
    word.append("$")
    return i + 1


def _double_quoted(cmd, i, word):
    n = len(cmd)
    while i < n:
        ch = cmd[i]
        if ch == '"':
            return i + 1
        if ch == "\\" and cmd[i + 1 : i + 2] in ('"', "\\", "$", "`", "\n"):
            if cmd[i + 1] != "\n":
                word.append(cmd[i + 1])
            i += 2
        elif ch == "`":
            raise NotAllowed("подстановка команды `...`")
        elif ch == "$":
            i = _dollar(cmd, i, word)
        else:
            word.append(ch)
            i += 1
    raise NotAllowed("незакрытая кавычка")


def _devnull_target(cmd, j):
    n = len(cmd)
    while j < n and cmd[j] in " \t":
        j += 1
    for form in ("/dev/null", "'/dev/null'", '"/dev/null"'):
        if cmd.startswith(form, j):
            end = j + len(form)
            if end == n or cmd[end] in SEPARATOR_CHARS:
                return end
    raise NotAllowed("вывод в файл (разрешён только /dev/null)")


def split_simple_commands(cmd):
    """Words of every simple command in a shell command line, quotes removed.

    Conservative by construction: a construct this parser does not model
    (subshell, substitution, redirection to a file, heredoc, unclosed quote)
    raises NotAllowed instead of being guessed. Expansions such as $HOME or
    ${X:-y} stay literal; they cannot start a new command.
    """
    commands, words, word = [], [], []
    flags = {"in_word": False, "quoted": False}

    def end_word():
        if flags["in_word"]:
            words.append("".join(word))
        del word[:]
        flags["in_word"] = flags["quoted"] = False

    def end_command():
        end_word()
        if words:
            commands.append(list(words))
        del words[:]

    i, n = 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if ch in " \t\r":
            end_word()
            i += 1
        elif ch == "\n" or ch == ";":
            end_command()
            i += 1
        elif ch == "\\":
            if cmd[i + 1 : i + 2] == "\n":
                i += 2
                continue
            if i + 1 >= n:
                raise NotAllowed("обратная косая черта в конце команды")
            word.append(cmd[i + 1])
            flags["in_word"] = flags["quoted"] = True
            i += 2
        elif ch == "'":
            end = cmd.find("'", i + 1)
            if end < 0:
                raise NotAllowed("незакрытая кавычка")
            word.append(cmd[i + 1 : end])
            flags["in_word"] = flags["quoted"] = True
            i = end + 1
        elif ch == '"':
            i = _double_quoted(cmd, i + 1, word)
            flags["in_word"] = flags["quoted"] = True
        elif ch == "`":
            raise NotAllowed("подстановка команды `...`")
        elif ch == "#":
            raise NotAllowed("комментарий вне кавычек: разделите команды для проверки")
        elif ch == "$":
            i = _dollar(cmd, i, word)
            flags["in_word"] = True
        elif ch in "()":
            raise NotAllowed("подоболочка ( )")
        elif ch == "|":
            end_command()
            i += 2 if cmd[i + 1 : i + 2] in ("|", "&") else 1
        elif ch == "&":
            if cmd[i + 1 : i + 2] == "&":
                end_command()
                i += 2
            elif cmd[i + 1 : i + 2] == ">":
                end_word()
                i = _devnull_target(
                    cmd, i + 2 + (1 if cmd[i + 2 : i + 3] == ">" else 0)
                )
            else:
                end_command()
                i += 1
        elif ch == ">":
            if flags["in_word"] and not flags["quoted"] and "".join(word).isdigit():
                del word[:]  # "2>": the digits are the descriptor, not a word
                flags["in_word"] = False
            else:
                end_word()
            j = i + 1
            nxt = cmd[j : j + 1]
            if nxt == "&":
                if cmd[j + 1 : j + 2] not in ("1", "2") or (
                    j + 2 < n and cmd[j + 2] not in SEPARATOR_CHARS
                ):
                    raise NotAllowed("перенаправление вывода")
                i = j + 2
            elif nxt == "(":
                raise NotAllowed("подстановка процесса")
            else:
                if nxt in (">", "|"):
                    j += 1
                i = _devnull_target(cmd, j)
        elif ch == "<":
            raise NotAllowed("перенаправление ввода")
        else:
            word.append(ch)
            flags["in_word"] = True
            i += 1
    end_command()
    return commands


def _basename(word):
    return word.rstrip("/").rsplit("/", 1)[-1]


def _system_command(word, names):
    """A plain tool called by name or from a system bin directory (not ./cat)."""
    base = _basename(word)
    if base not in names:
        return ""
    if word == base or os.path.dirname(word) in SYSTEM_BIN_DIRS:
        return base
    return ""


def _abbrev_of(name, option):
    """git accepts unique abbreviations of long options: --outp means --output."""
    return name.startswith(option) or (len(name) >= 4 and option.startswith(name))


def _check_git(args):
    i = 0
    no_pager = False
    while i < len(args) and args[i].startswith("-"):
        if args[i] == "-C" and i + 1 < len(args):
            i += 2
        elif args[i] == "--no-pager":
            no_pager = True
            i += 1
        else:
            raise NotAllowed("параметр git " + args[i])
    if i >= len(args) or args[i] not in GIT_READ_SUBCOMMANDS:
        raise NotAllowed("git " + (args[i] if i < len(args) else "без команды"))
    if args[i] in ("diff", "show", "log"):
        required = ["--no-ext-diff", "--no-textconv"]
        if args[i] in ("show", "log"):
            required.append("--no-show-signature")
        if args[i + 1 : i + 1 + len(required)] != required or not no_pager:
            raise NotAllowed(
                "git: используйте --no-pager и сразу после команды "
                + " ".join(required)
            )
    for arg in args[i + 1 :]:
        name = arg.split("=", 1)[0]
        if not name.startswith("--"):
            continue
        if name.startswith("--no-no-"):
            raise NotAllowed("двойное отрицание параметра git")
        for option in (
            "--output",
            "--upload-pack",
            "--exec",
            "--textconv",
            "--ext-diff",
            "--filters",
            "--show-signature",
        ):
            if _abbrev_of(name, option):
                raise NotAllowed("git " + name + " пишет файл или запускает программу")


def _check_sed(args):
    quiet, scripts, positional, i = False, [], [], 0
    while i < len(args):
        arg = args[i]
        if arg in ("-n", "--quiet", "--silent"):
            quiet = True
        elif re.fullmatch(r"-[nErsu]*e", arg) and i + 1 < len(
            args
        ):  # -e SCRIPT, -ne SCRIPT
            quiet = quiet or "n" in arg
            scripts.append(args[i + 1])
            i += 1
        elif arg.startswith("--expression="):
            scripts.append(arg.split("=", 1)[1])
        elif arg in (
            "-E",
            "-r",
            "--regexp-extended",
            "-s",
            "--separate",
            "-u",
            "--unbuffered",
            "--posix",
            "--",
        ):
            pass
        elif re.fullmatch(r"-[nErsu]+", arg):
            quiet = quiet or "n" in arg
        elif arg.startswith("-") and arg != "-":
            raise NotAllowed("sed " + arg)
        else:
            positional.append(arg)
        i += 1
    if not scripts and positional:
        scripts.append(positional.pop(0))
    if not quiet or not scripts or not all(SED_PRINT_RE.match(s) for s in scripts):
        raise NotAllowed("sed разрешён только как sed -n 'N,Mp'")


def _trusted_script(command, cwd):
    if "$" in command or "/" not in command:
        return False
    relative = (
        ".claude/scripts/" if _basename(command) == "wp-sync-bundle.sh" else "scripts/"
    ) + _basename(command)
    candidate = os.path.expanduser(command)
    if not os.path.isabs(candidate):
        candidate = os.path.join(cwd, candidate)
    roots = {CODE_ROOT, os.environ.get("IWE_WORKSPACE") or CODE_ROOT}
    return any(
        os.path.realpath(candidate) == os.path.join(os.path.realpath(root), relative)
        for root in roots
    )


def _check_simple(words, cwd):
    k = 0
    while k < len(words) and ASSIGNMENT_RE.match(words[k]):
        name = words[k].split("=", 1)[0]
        if name not in ENV_PREFIX_ALLOWED:
            raise NotAllowed("переменная окружения " + name)
        k += 1
    if k == len(words):
        raise NotAllowed("присваивание переменной без команды")
    command, args = words[k], words[k + 1 :]
    if _system_command(command, INTERPRETERS):
        if not args or args[0].startswith("-"):
            raise NotAllowed(_basename(command) + " без пути к скрипту разбора")
        command, args = args[0], args[1:]
        if _basename(command) not in TRIAGE_SCRIPTS:
            raise NotAllowed("скрипт " + _basename(command))
    base = _basename(command)
    if base in TRIAGE_SCRIPTS:
        if not _trusted_script(command, cwd):
            raise NotAllowed("нужен точный путь к штатному скрипту " + base)
        subcommands = TRIAGE_SCRIPTS[base]
        if subcommands is not None and (not args or args[0] not in subcommands):
            raise NotAllowed(base + " " + (args[0] if args else "без команды"))
        return
    if _system_command(command, ("git",)):
        _check_git(args)
        return
    if _system_command(command, ("sed",)):
        _check_sed(args)
        return
    if _system_command(command, PLAIN_READERS):
        return
    raise NotAllowed("команда " + base)


def bash_allowed(command, cwd):
    """(True, "") when every part of the command is allowed before admission."""
    try:
        for words in split_simple_commands(command or ""):
            _check_simple(words, cwd)
    except NotAllowed as refusal:
        return False, str(refusal)
    return True, ""


def card_target_wp(path, cwd):
    """ "WP-N" when an Edit/Write targets inbox/WP-N/WP-N.md or inbox/WP-N/INBOX.md."""
    if not path:
        return ""
    if not os.path.isabs(path):
        path = os.path.join(cwd or "/", path)
    match = CARD_PATH_RE.search(os.path.normpath(path))
    if not match or (match.group(2) is not None and match.group(2) != match.group(1)):
        return ""
    return "WP-" + match.group(1)


def _short(text, limit=160):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def cmd_prepare(opts):
    data = json.load(sys.stdin)
    tool = data.get("tool_name") or ""
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    if tool in ("Read", "Grep", "Glob"):
        return {"action": "allow"}
    target_wp = ""
    if tool == "Bash":
        command = tool_input.get("command") or ""
        allowed, why = bash_allowed(command, data.get("cwd") or os.getcwd())
        if allowed:
            return {"action": "allow"}
        blocked = "Bash `" + _short(command) + "` (вне списка: " + why + ")"
    elif tool in ("Edit", "Write", "MultiEdit"):
        path = tool_input.get("file_path") or ""
        target_wp = card_target_wp(path, data.get("cwd") or "")
        blocked = tool + " " + (path or "(путь не указан)")
    else:
        blocked = (
            tool
            + " "
            + (tool_input.get("notebook_path") or tool_input.get("file_path") or "")
        )
    record = latest_pilot_record(data["transcript_path"])
    with open(opts.view, "w", encoding="utf-8") as out:
        if record is not None:
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
    return {"action": "check", "target_wp": target_wp, "blocked": blocked.strip()}


# --------------------------------------------------------------------------
# Admission
# --------------------------------------------------------------------------


def run(argv, timeout):
    """(exit code, stdout bytes); 124 on timeout, 127 when it cannot start.

    stderr is dropped on purpose: git messages may carry the remote URL with a token.
    """
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
    except OSError:
        return 127, b""
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return 124, b""
    return proc.returncode, out


def commit_present(gov, sha):
    return run(["git", "-C", gov, "cat-file", "-e", sha + "^{commit}"], 10)[0] == 0


def cache_path(runtime_dir, name):
    return os.path.join(runtime_dir, "inbox-admission", name)


def write_cache(path, text):
    """Best effort: a cache that cannot be written only costs a re-read next time."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError as error:
        sys.stderr.write(f"inbox_admission: cache {path} not written: {error}\n")


def repo_key(gov):
    return hashlib.sha1(os.path.realpath(gov).encode("utf-8")).hexdigest()[:16]


def server_head(gov):
    """The fresh commit of origin's main; positive admission is never cached.

    ls-remote asks the server without touching refs, so parallel sessions do
    not fight over ref locks; fetch only when the commit is missing locally.
    """
    if not os.path.isdir(gov):
        raise ReadError(f"репозиторий планов {gov} не найден")
    code, out = run(
        ["git", "-C", gov, "ls-remote", "--exit-code", "origin", "refs/heads/main"], 10
    )
    if code != 0:
        raise ReadError(
            f"сервер не ответил на запрос ветки main (git ls-remote, код {code})"
        )
    sha = ""
    for line in out.decode("ascii", "replace").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "refs/heads/main":
            sha = parts[0]
    if not SHA_RE.fullmatch(sha):
        raise ReadError("ответ сервера о ветке main не разобран")
    if not commit_present(gov, sha):
        code = run(["git", "-C", gov, "fetch", "-q", "origin", "main"], 25)[0]
        if not commit_present(gov, sha):
            time.sleep(1)  # a parallel fetch may hold the ref lock and bring the commit
            if not commit_present(gov, sha):
                raise ReadError(f"коммит сервера не загружен (git fetch, код {code})")
    return sha


def parse_entries(text):
    entries = []
    for line in text.splitlines():
        header = SERVER_HEADER_RE.match(line)
        if header:
            entries.append({"id": header.group(1), "summary": header.group(2)})
            continue
        summary = SUMMARY_RE.match(line)
        if summary and entries and not entries[-1].get("has_summary"):
            entries[-1]["summary"] = summary.group(1)
            entries[-1]["has_summary"] = True
    return entries


def server_entries(gov, inbox_script, runtime_dir, num, sha):
    """(fingerprint, «новое» entries) of the WP inbox at the server commit.

    A missing inbox file is zero entries; any git or script failure is a
    ReadError (`wp-inbox.sh count/list` alone cannot tell an error from zero).
    The answer for one commit never changes, so it is kept per WP until the
    server head moves.
    """
    cache = cache_path(runtime_dir, f"entries-{repo_key(gov)}-WP-{num}.json")
    try:
        with open(cache, encoding="utf-8") as f:
            kept = json.load(f)
        valid = (
            isinstance(kept, dict)
            and kept.get("schema") == 2
            and kept.get("sha") == sha
            and isinstance(kept.get("fingerprint"), str)
            and isinstance(kept.get("entries"), list)
        )
        entries = kept.get("entries") if valid else []
        valid = valid and all(
            isinstance(entry, dict)
            and isinstance(entry.get("id"), str)
            and re.fullmatch(r"[0-9]+", entry["id"])
            and isinstance(entry.get("summary"), str)
            and isinstance(entry.get("hash"), str)
            and re.fullmatch(r"[0-9a-f]{12}", entry["hash"])
            for entry in entries
        )
        valid = valid and len({entry["id"] for entry in entries}) == len(entries)
        if valid and bool(kept["fingerprint"]) == bool(entries):
            return kept["fingerprint"], kept["entries"]
    except (OSError, ValueError, KeyError, TypeError):
        pass  # no usable cache: read the commit
    rel = f"inbox/WP-{num}/INBOX.md"
    code, out = run(["git", "-C", gov, "ls-tree", "--name-only", sha, "--", rel], 10)
    if code != 0:
        raise ReadError(f"дерево сервера не прочитано (git ls-tree, код {code})")
    fingerprint, entries = "", []
    if out.strip():
        code, digest = run(
            ["bash", inbox_script, "digest", "--wp", num, "--repo", gov, "--rev", sha],
            20,
        )
        if code != 0:
            raise ReadError(
                f"отпечаток ящика не получен (wp-inbox.sh digest, код {code})"
            )
        code, listing = run(
            ["bash", inbox_script, "list", "--wp", num, "--repo", gov, "--rev", sha], 20
        )
        if code != 0:
            raise ReadError(f"список записей не получен (wp-inbox.sh list, код {code})")
        fingerprint = digest.decode("ascii", "replace").strip()
        entries = parse_entries(listing.decode("utf-8", "replace"))
        code, raw = run(["git", "-C", gov, "show", sha + ":" + rel], 10)
        if code != 0:
            raise ReadError(f"текст ящика не прочитан (git show, код {code})")
        parser = decision_parser(gov)
        try:
            source_entries = parser.parse_mailbox(raw)
            for entry in entries:
                entry["id"] = str(int(entry["id"]))
                source = source_entries[entry["id"]]
                if source.status != "новое":
                    raise ReadError("список и текст записей ящика не сходятся")
                entry["hash"] = source.content_hash()
        except (parser.Unparseable, KeyError, ValueError) as error:
            raise ReadError(f"текст ящика не разобран: {error}") from error
        if bool(fingerprint) != bool(entries):
            raise ReadError("отпечаток и список записей ящика не сходятся")
    write_cache(
        cache,
        json.dumps(
            {"schema": 2, "sha": sha, "fingerprint": fingerprint, "entries": entries},
            ensure_ascii=False,
        ),
    )
    return fingerprint, entries


def _field(lines, name):
    prefix = name + ": "
    for line in lines:
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    return ""


def working_copies(sessions_dir, session):
    """Governance copies named by this conversation's open session semaphores."""
    copies = []
    for path in sorted(glob.glob(os.path.join(sessions_dir, "*.open"))):
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeError):
            continue
        if "harness_session_id: " + session not in lines:
            continue
        copy = _field(lines, "governance_worktree") or _field(
            lines, "isolated_worktree"
        )
        if copy and copy not in copies:
            copies.append(copy)
    return copies


def decision_parser(gov):
    """Use the published close-accounting definition of entry identity."""
    path = os.path.join(gov, "scripts", "wp-inbox-decision.py")
    try:
        spec = importlib.util.spec_from_file_location("inbox_admission_decision", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module  # dataclasses resolve their module here
        spec.loader.exec_module(module)
        return module
    except (OSError, ImportError, SyntaxError, AttributeError) as error:
        raise ReadError(
            f"модуль учёта ящика недоступен: {type(error).__name__}"
        ) from error


def locally_accounted(copy, num, entries, parser):
    """Every server entry's exact text is marked «учтено» in the session copy.

    A missing or unreadable file means "not marked", which keeps the denial.
    """
    try:
        with open(os.path.join(copy, "inbox", f"WP-{num}", "INBOX.md"), mode="rb") as f:
            local = parser.parse_mailbox(f.read())
    except (OSError, parser.Unparseable):
        return False
    return all(
        entry["id"] in local
        and local[entry["id"]].status == "учтено"
        and local[entry["id"]].content_hash() == entry["hash"]
        for entry in entries
    )


def deferral_status(runtime_dir, session, wp, fingerprint, transcript):
    """(admitted, note): the deferral record of this conversation for this WP."""
    path = os.path.join(runtime_dir, "intent-declarations", session + ".json")
    try:
        with open(path, encoding="utf-8") as f:
            record = json.loads(f.read())  # exactly one JSON document
    except (OSError, UnicodeError, ValueError):
        return False, ""
    deferral = record.get("inbox_deferral") if isinstance(record, dict) else None
    if (
        not isinstance(deferral, dict)
        or record.get("session_id") != session
        or deferral.get("session_id") != session
        or deferral.get("wp") != wp
    ):
        return False, ""
    if not fingerprint or deferral.get("fingerprint") != fingerprint:
        return False, (
            "Отсрочка разбора из записи беседы выдана для прежнего состава ящика: "
            "после неё на сервер пришли новые записи, она больше не действует."
        )
    quote = deferral.get("quote")
    if not isinstance(quote, str) or not quote_in_transcript(
        runtime_dir, session, transcript, quote, wp, fingerprint
    ):
        return False, (
            "Отсрочка разбора записана, но её цитата «{}» не найдена в сообщениях "
            "пилота этой беседы: нужны его собственные слова дословно.".format(
                _short(quote or "", 80)
            )
        )
    return True, ""


def deferral_phrase(text, wp):
    phrase = _normalize(text).strip(" «»\"'“”„‘’").rstrip(".!")
    match = re.fullmatch(r"разбор ящика(?: (?:рп|wp)[-–— ]?(\d+))? отложить", phrase)
    return bool(
        match and (match.group(1) is None or int(match.group(1)) == int(wp[3:]))
    )


def read_json_object(path):
    try:
        with open(path, encoding="utf-8") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, UnicodeError):
        return {}


def quote_in_transcript(runtime_dir, session, transcript, quote, wp, fingerprint):
    """Bind one explicit human decision to one inbox snapshot, never to a later one."""
    if not deferral_phrase(quote, wp):
        return False
    key = hashlib.sha256(
        f"{session}\x00{transcript}\x00{wp}\x00{fingerprint}\x00{quote}".encode()
    ).hexdigest()
    grant_path = cache_path(runtime_dir, "deferral-grant-" + key)
    grant = read_json_object(grant_path)
    expected = {"wp": wp, "fingerprint": fingerprint}
    witness = grant.get("witness")
    if (
        isinstance(witness, str)
        and re.fullmatch(r"[0-9a-f]{64}", witness)
        and read_json_object(cache_path(runtime_dir, "deferral-used-" + witness))
        == expected
    ):
        return True
    latest = None
    try:
        with open(transcript, "rb") as stream:
            for position, raw in enumerate(stream):
                record = _parse_line(raw)
                if is_pilot_message(record):
                    latest = (position, record)
    except OSError:
        return False
    if latest is None:
        return False
    text = rs.message_text(latest[1])
    if not any(
        deferral_phrase(line, wp) and quote_found(quote, [line])
        for line in text.splitlines()
    ):
        return False
    witness = hashlib.sha256(
        json.dumps((session, transcript, latest), sort_keys=True).encode()
    ).hexdigest()
    used_path = cache_path(runtime_dir, "deferral-used-" + witness)
    try:
        os.makedirs(os.path.dirname(used_path), exist_ok=True)
        with open(used_path, "x", encoding="utf-8") as stream:
            json.dump(expected, stream)
    except FileExistsError:
        if read_json_object(used_path) != expected:
            return False
    except OSError:
        return False
    write_cache(grant_path, json.dumps({**expected, "witness": witness}))
    return True


def _ways_out(num, root, copies, session):
    inbox_script = os.path.join(root, "scripts", "wp-inbox.sh")
    declare = os.path.join(root, "scripts", "declare-intent.sh")
    if copies:
        mark = f'bash {inbox_script} mark --wp {num} --id K --repo {copies[0]} --by "session={session}; <что решено>"'
        first = (
            "Выход 1: с согласия пилота разберите каждую запись (перенести выжимку и указатель "
            "в «Осталось» карточки или «учтено») и пометьте её в рабочей копии этой сессии: "
            + mark
            + "."
        )
    else:
        first = (
            "Выход 1: с согласия пилота разберите каждую запись (перенести в «Осталось» карточки "
            "или «учтено») и пометьте её в рабочей копии этой сессии. Отметка сессии этой беседы "
            f"не найдена: сначала откройте сессию (session-guard.sh open --wp WP-{num}), затем "
            f'bash {inbox_script} mark --wp {num} --id K --repo <копия из отметки сессии> --by "session={session}; <что решено>".'
        )
    second = (
        f"Выход 2: пилот пишет отдельной строкой «Разбор ящика РП-{num} отложить». "
        "Запишите эту строку дословно: "
        f'bash {declare} WP-{num} --inbox-deferred "<цитата пилота>". Цитата сверяется с его '
        "последним сообщением в этой беседе; новая запись на сервере требует нового решения."
    )
    return first, second


def entries_message(opts, num, entries, copies, note):
    lines = [
        (
            f"Допуск к работе по РП-{num} не получен: в ящике входящих РП-{num} на сервере записей "
            f"«новое»: {len(entries)}. По решению пилота от 28.11.2026 (РП-561 Ф94) их разбирают до работы "
            "(шаг 3 протокола открытия сессии)."
        )
    ]
    for entry in entries:
        lines.append("  И-{}: {}".format(entry["id"], _short(entry["summary"], 140)))
    lines.append(f"Не выполнено: {opts.blocked}.")
    lines.append(
        f"До допуска разрешены только чтение и сам разбор: {ALLOWLIST_TEXT}; Edit и Write только "
        f"карточки inbox/WP-{num}/WP-{num}.md и inbox/WP-{num}/INBOX.md."
    )
    lines.extend(_ways_out(num, opts.root, copies, opts.session))
    if note:
        lines.append(note)
    return "\n".join(lines)


def read_error_message(opts, num, reason, copies):
    first, second = _ways_out(num, opts.root, copies, opts.session)
    return "\n".join(
        [
            (
                f"Допуск к работе по РП-{num} не проверен: ящик входящих на сервере не прочитан ({reason}). "
                "Ошибка чтения не равна пустому ящику, поэтому работа не допускается."
            ),
            f"Не выполнено: {opts.blocked}.",
            (
                f"Проверьте связь с сервером (разрешено: git -C {opts.gov_repo} fetch origin) и повторите. До допуска "
                f"разрешены только чтение и сам разбор: {ALLOWLIST_TEXT}."
            ),
            "Когда сервер прочитается, выходов два.",
            first,
            second,
        ]
    )


def evaluate(opts, num):
    sha = server_head(opts.gov_repo)
    fingerprint, entries = server_entries(
        opts.gov_repo, opts.inbox_script, opts.runtime_dir, num, sha
    )
    if not entries:
        return {"decision": "allow", "basis": "no_new_entries"}
    copies = working_copies(opts.sessions_dir, opts.session)
    parser = decision_parser(opts.gov_repo)
    for copy in copies:
        if locally_accounted(copy, num, entries, parser):
            return {"decision": "allow", "basis": "marked_in_session_copy"}
    admitted, note = deferral_status(
        opts.runtime_dir, opts.session, opts.wp, fingerprint, opts.transcript
    )
    if admitted:
        return {"decision": "allow", "basis": "deferred_by_pilot"}
    return {
        "decision": "deny",
        "basis": "new_entries",
        "message": entries_message(opts, num, entries, copies, note),
    }


def cmd_admit(opts):
    if not re.fullmatch(r"WP-\d+", opts.wp):
        raise ValueError("bad --wp " + opts.wp)
    num = opts.wp[3:]
    try:
        result = evaluate(opts, num)
    except ReadError as error:
        copies = working_copies(opts.sessions_dir, opts.session)
        return {
            "decision": "deny",
            "basis": "read_error",
            "message": read_error_message(opts, num, str(error), copies),
        }
    return result


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command")
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--view", required=True)
    admit = sub.add_parser("admit")
    for name in (
        "--wp",
        "--session",
        "--transcript",
        "--gov-repo",
        "--root",
        "--runtime-dir",
        "--sessions-dir",
        "--blocked",
    ):
        admit.add_argument(name, required=True)
    opts = parser.parse_args(argv)
    if opts.command == "prepare":
        result = cmd_prepare(opts)
    elif opts.command == "admit":
        opts.inbox_script = os.path.join(opts.root, "scripts", "wp-inbox.sh")
        result = cmd_admit(opts)
    else:
        parser.error("command required")
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
