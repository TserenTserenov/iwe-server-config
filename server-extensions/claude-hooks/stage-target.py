#!/usr/bin/env python3
"""Decide which git index a staging call (`git add`, `git restore --staged`) writes.

Used by destructive-guard.sh (WP-561 Ф54, peer-session 2026-10-29-29 with
Kimi+Codex, pilot decision 29.10: unresolved target = block). The hook refuses
staging in a frozen canonical checkout because the index is shared. The old
check took the repository from `-C` or from the hook's cwd and so (a) refused
`(cd <other repo> && git add f)` and (b) missed `GIT_DIR=<canon>/.git git add f`.

Contract
--------
stdin  : the Bash command text (heredoc bodies already removed by the hook)
argv   : --cwd <dir>  --frozen <canonical checkout> [--frozen ...]
stdout : one line
         "ALLOW"                    -- every staging call provably writes an index outside the frozen ones
         "FROZEN\t<checkout>"        -- some staging call writes the index of that frozen checkout
         "UNKNOWN\t<reason>"         -- the target index could not be established
exit   : always 0. The caller treats empty output as UNKNOWN.

What it models, in order of execution: subshells `( ... )` (their `cd` is lost
at the closing parenthesis), `cd` joined by `&&` (the next command runs only if
the `cd` succeeded) versus `;` (it may have failed, both directories stay
possible), `-C` applied one after another, `--git-dir`, `GIT_DIR`,
`GIT_INDEX_FILE` (prefix assignment, `export`, `env`), and plain assignments
`NAME=literal` earlier in the same call. The target is the real index file
reported by `git rev-parse --git-path index`, compared as a resolved path with
the index of each frozen checkout, so linked worktrees (own index), submodules
and clones are not confused with the canon.

`bash -c '...'`, `sh -c`, `eval`, `env -S` are analysed recursively (shell options are
parsed as bash does: `-o pipefail`, `+x`, redirections, `--`); a shell fed through a pipe or
a here-string, `env -C` and `sudo --chdir` are UNKNOWN (WP-484 Ф298, 10.11); assignments that are
conditional (after `&&`/`||`) for GIT_DIR/GIT_INDEX_FILE, or run inside a
pipeline or in the background, are not trusted. A `GIT_DIR`/`GIT_INDEX_FILE`
inherited by the hook process counts as set.

Not modelled: `source`, aliases, and deliberate obfuscation of the command name
(`g''it add`): the hook guards against accidental staging in the frozen checkout,
not against a caller who hides the command on purpose. Anything it cannot
resolve (a shell variable with no literal value in the same call, `$(...)`,
`cd -`, an error computing an index) is UNKNOWN, never a guess. A `cd` joined by
`;` keeps both directories possible, so `cd <other>; git add` from the canon
stays blocked even when the `cd` succeeds (conservative by decision of 29.10).
"""

import os
import re
import subprocess
import sys

UNKNOWN = object()  # an unresolved value; also the "unknown directory" member of a dir set

WRAPPERS = {
    "command", "builtin", "exec", "nohup", "time", "sudo", "doas", "timeout",
    "nice", "ionice", "stdbuf", "setsid", "xargs", "env",
}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
# Options of the wrappers above that take a separate argument.
WRAPPER_OPTION_ARG = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-r", "-t",
             "--user", "--group", "--host", "--prompt", "--close-from", "--role", "--type"},
    "doas": {"-u", "-C"},
    "env": {"-u"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "xargs": {"-n", "-P", "-I", "-L", "-s", "-E", "-d", "-a",
              "--max-args", "--max-procs", "--max-lines", "--max-chars", "--eof", "--delimiter", "--arg-file"},
}
# Wrapper options that change the working directory of the wrapped command.
WRAPPER_CHDIR = {"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}
# Shell options that take the next word as their argument (`bash -o pipefail -c ...`).
SHELL_OPTION_ARG = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
def is_stdin_redirection(word):
    """`<file`, `<<<text`, `<<EOF`, `0<file`: the command reads its stdin from there."""
    stripped = word.lstrip("0123456789")
    return stripped.startswith("<") and not stripped.startswith("<>") and word[:len(word) - len(stripped)] in ("", "0")


# A redirection word: `2>/dev/null`, `>x`, `<<<text`; a bare operator takes the next word.
REDIRECTION = re.compile(r"^[0-9]*(?:&>>?|>>?|<<<|<<-?|<>|<|>&|<&)")
BARE_REDIRECTION = re.compile(r"^[0-9]*(?:&>>?|>>?|<<<|<<-?|<>|<|>&|<&)$")
GIT_OPTION_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"}
GIT_ENV_NAMES = ("GIT_DIR", "GIT_INDEX_FILE")
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)


# ---------------------------------------------------------------- lexer
# A word is a list of parts: ("lit", text) | ("var", name) | ("dyn", reason) | ("sub", inner_text).

# Constructs the lexer could not close: the rest of the text became one part, so whatever
# followed is not analysed and the whole verdict is UNKNOWN (third cold review 10.11).
LEX_ERRORS = []


def _find_close(text, i, opener, closer):
    """Index of the closer matching text[i] == opener, skipping quotes; -1 if none."""
    depth, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                return -1
            i = j + 1
            continue
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _find_brace_close(text, i):
    """Index of the `}` closing a `${` whose body starts at text[i]; -1 if none.  As in bash,
    quotes and backslashes protect a `}`, a nested `${` must close first, a bare `{` does not
    count (`${X%%{*}`, `${X:-'}'}`, `${X:-$'\''}` -- third cold review 10.11)."""
    depth, n = 1, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
        elif c == "$" and text[i + 1:i + 2] == "'":
            i += 2
            while i < n and text[i] != "'":
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                return -1
            i = j + 1
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif c == "$" and text[i + 1:i + 2] == "{":
            depth += 1
            i += 2
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
            i += 1
        else:
            i += 1
    return -1


def _expansion(text, i, parts, in_dquote=False):
    """Handle `$...` at text[i]; append to parts; return the next index."""
    n = len(text)
    nxt = text[i + 1] if i + 1 < n else ""
    if nxt in "'\"" and nxt:
        if in_dquote:  # `"...$"`: a literal dollar before the closing quote
            parts.append(("lit", "$"))
            return i + 1
        if nxt == '"':  # $"..." (locale string) lexes as "..." (cold review 10.11)
            return i + 1
        # $'...' (ANSI-C string).  Only \\ \' \" are decoded; `\n`, `\x2f`, ... would change
        # the command text (third cold review 10.11: `bash -c $'a\ngit add f'`), so they leave
        # the word unresolved.
        j, out, exact = i + 2, [], True
        while j < n and text[j] != "'":
            if text[j] == "\\" and j + 1 < n:
                exact = exact and text[j + 1] in "\\'\""
                out.append(text[j + 1])
                j += 2
            else:
                out.append(text[j])
                j += 1
        if j >= n:
            LEX_ERRORS.append("незакрытая строка $'...'")
        parts.append(("lit", "".join(out)) if exact else ("dyn", "строка $'...' с управляющими последовательностями"))
        return j + 1
    if nxt == "(":
        end = _find_close(text, i + 1, "(", ")")
        if end < 0:
            LEX_ERRORS.append("незакрытая подстановка команды $(...)")
            parts.append(("dyn", "незакрытая подстановка команды"))
            return n
        parts.append(("sub", text[i + 2:end]))
        parts.append(("dyn", "подстановка команды $(...)"))
        return end + 1
    if nxt == "{":
        end = _find_brace_close(text, i + 2)
        if end < 0:
            LEX_ERRORS.append("незакрытая подстановка ${...}")
            parts.append(("dyn", "незакрытая ${...}"))
            return n
        name = text[i + 2:end]
        parts.append(("var", name) if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name)
                     else ("dyn", "подстановка ${%s}" % name))
        return end + 1
    m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i + 1:])
    if m:
        parts.append(("var", m.group(0)))
        return i + 1 + len(m.group(0))
    parts.append(("dyn", "специальный параметр $%s" % nxt))
    return i + 2 if nxt else i + 1


def lex(text):
    """Return a flat token list: ("op", str) | ("word", parts)."""
    toks, parts, buf = [], [], []
    state = {"inword": False, "quoted": False}
    n, i = len(text), 0

    def flush():
        if buf:
            parts.append(("lit", "".join(buf)))
            buf.clear()

    def redirection_break():
        """End the current word before a redirection operator, unless it is an fd number."""
        if state["inword"] and not (not parts and buf and "".join(buf).isdigit()):
            if not (buf and buf[-1] in "<>&"):
                end_word()

    def end_word():
        flush()
        if state["inword"]:
            if not state["quoted"] and parts in ([("lit", "{")], [("lit", "}")]):
                toks.append(("op", parts[0][1]))
            else:
                toks.append(("word", list(parts)))
        parts.clear()
        state["inword"] = state["quoted"] = False

    while i < n:
        c = text[i]
        if c in " \t":
            end_word()
            i += 1
        elif c == "\n":
            end_word()
            toks.append(("op", "\n"))
            i += 1
        elif c == "#" and not state["inword"]:
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == "\\":
            state["inword"] = True
            if i + 1 < n and text[i + 1] != "\n":
                buf.append(text[i + 1])
            i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            state["inword"] = state["quoted"] = True
            if j < 0:
                buf.append(text[i + 1:])
                i = n
            else:
                buf.append(text[i + 1:j])
                i = j + 1
        elif c == '"':
            state["inword"] = state["quoted"] = True
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] in '"\\$`':
                        buf.append(text[i + 1])
                    else:
                        buf.append(text[i:i + 2])
                    i += 2
                elif text[i] == "$":
                    flush()
                    i = _expansion(text, i, parts, in_dquote=True)
                elif text[i] == "`":
                    end = text.find("`", i + 1)
                    flush()
                    parts.append(("sub", text[i + 1:end] if end > 0 else ""))
                    parts.append(("dyn", "подстановка команды в обратных кавычках"))
                    i = end + 1 if end > 0 else n
                else:
                    buf.append(text[i])
                    i += 1
            i += 1
        elif c == "$":
            state["inword"] = True
            flush()
            i = _expansion(text, i, parts)
        elif c == "`":
            state["inword"] = True
            end = text.find("`", i + 1)
            flush()
            parts.append(("sub", text[i + 1:end] if end > 0 else ""))
            parts.append(("dyn", "подстановка команды в обратных кавычках"))
            i = end + 1 if end > 0 else n
        elif c in "<>" and i + 1 < n and text[i + 1] == "(":
            # <(...) / >(...) run their own command list (cold review 10.11: it was not analysed)
            redirection_break()
            state["inword"] = True
            end = _find_close(text, i + 1, "(", ")")
            if end < 0:
                LEX_ERRORS.append("незакрытая подстановка процесса")
                parts.append(("dyn", "незакрытая подстановка процесса"))
                i = n
            else:
                parts.append(("sub", text[i + 2:end]))
                parts.append(("dyn", "подстановка процесса"))
                i = end + 1
        elif c in "<>":
            # `cd ..>/dev/null`: the redirection is not part of the path (cold review 10.11)
            redirection_break()
            state["inword"] = True
            buf.append(c)
            i += 1
        elif c == ";":
            end_word()
            toks.append(("op", ";"))
            i += 1
        elif c == "&":
            if state["inword"] and buf and buf[-1] == ">":
                buf.append(c)  # `2>&1` is a redirection, not a separator
                i += 1
            elif i + 1 < n and text[i + 1] == "&":
                end_word()
                toks.append(("op", "&&"))
                i += 2
            elif i + 1 < n and text[i + 1] == ">":
                redirection_break()
                state["inword"] = True
                buf.append(c)
                i += 1
            else:
                end_word()
                toks.append(("op", "&"))
                i += 1
        elif c == "|":
            end_word()
            if i + 1 < n and text[i + 1] == "|":
                toks.append(("op", "||"))
                i += 2
            elif i + 1 < n and text[i + 1] == "&":
                toks.append(("op", "|"))  # `|&` pipes stdout and stderr
                i += 2
            else:
                toks.append(("op", "|"))
                i += 1
        elif c in "()":
            end_word()
            toks.append(("op", c))
            i += 1
        else:
            state["inword"] = True
            buf.append(c)
            i += 1
    end_word()
    return toks


# ---------------------------------------------------------------- analysis

class Frame:
    """Shell state of one scope: possible working directories and variables."""

    def __init__(self, dirs, variables=None, exported=None):
        self.dirs = set(dirs)          # possible cwd's; UNKNOWN member = not established
        self.chain = None              # dirs valid only inside the current `&&` chain
        self.vars = dict(variables or {})   # name -> str | UNKNOWN
        self.exported = set(exported or ())

    def copy(self):
        f = Frame(self.dirs, self.vars, self.exported)
        f.chain = None if self.chain is None else set(self.chain)
        return f

    def current(self, joined_by_and):
        if joined_by_and and self.chain is not None:
            return set(self.chain)
        return self.dirs | (self.chain or set())


class Analyzer:
    def __init__(self, cwd, frozen_indexes):
        self.cwd = cwd
        self.frozen = frozen_indexes   # {realpath of index file: checkout}
        self.verdicts = []             # ("FROZEN", checkout) | ("UNKNOWN", reason)
        self.depth = 0

    # -- word resolution
    def text_of(self, word, frame):
        """Resolve a word to a string, or (UNKNOWN, reason)."""
        out = []
        for kind, val in word:
            if kind == "lit":
                out.append(val)
            elif kind == "var":
                v = frame.vars.get(val, "missing")
                if v == "missing":
                    if val == "HOME" and os.environ.get("HOME"):
                        out.append(os.environ["HOME"])
                    else:
                        return UNKNOWN, "переменная $%s без значения в этой же команде" % val
                elif v is UNKNOWN:
                    return UNKNOWN, "переменная $%s задана нелитерально" % val
                else:
                    out.append(v)
            elif kind == "dyn":
                return UNKNOWN, val
            # ("sub", ...) is analysed separately; its value comes via the following dyn part
        s = "".join(out)
        if s.startswith("~"):
            home = os.environ.get("HOME", "")
            s = home + s[1:] if home and (len(s) == 1 or s[1] == "/") else s
        return s, None

    def scan_subs(self, word, frame):
        for kind, val in word:
            if kind == "sub" and self.depth < 8:
                self.depth += 1
                self.run(lex(val), frame.copy())
                self.depth -= 1

    # -- running a token list
    def run(self, toks, frame):
        stack, cmd, prev_op = [], [], ";"
        for tok in toks + [("op", ";")]:
            if tok[0] == "word":
                cmd.append(tok[1])
                continue
            op = tok[1]
            if cmd:
                self.simple(cmd, frame, prev_op, op)
                cmd = []
            if op == "(":
                stack.append(frame)
                frame = frame.copy()
                frame.dirs = frame.current(prev_op == "&&")
                frame.chain = None
            elif op == ")":
                if stack:
                    frame = stack.pop()
            elif op in ("{", "}"):
                continue
            else:
                if op != "&&" and frame.chain is not None:
                    frame.dirs |= frame.chain
                    frame.chain = None
            prev_op = op
        return frame

    def simple(self, words, frame, prev_op, next_op):
        for w in words:
            self.scan_subs(w, frame)
        # leading NAME=value assignments
        prefix_env, idx = {}, 0
        while idx < len(words):
            lit = words[idx][0][1] if words[idx] and words[idx][0][0] == "lit" else ""
            m = ASSIGNMENT.match(lit)
            if not m:
                break
            value_word = [("lit", m.group(2))] + words[idx][1:]
            prefix_env[m.group(1)] = self.text_of(value_word, frame)[0]
            idx += 1
        words = words[idx:]
        if not words:
            if "|" in (prev_op, next_op) or next_op == "&":
                return  # runs in a subshell: the assignment is lost
            conditional = prev_op in ("&&", "||")
            for name, value in prefix_env.items():
                frame.vars[name] = UNKNOWN if conditional and name in GIT_ENV_NAMES else value
            return
        leading_words = words  # before the wrappers: `<<<text bash` keeps its redirection here
        words = self.strip_wrappers(words, frame, prefix_env)
        if not words:
            return
        head, head_reason = self.text_of(words[0], frame)
        if head is UNKNOWN:
            # An unresolved command name may itself be `git` (WP-484 Ф298: it used to crash).
            self.verdicts.append(("UNKNOWN", "имя команды не установлено (%s)" % head_reason))
            return
        args = words[1:]
        in_pipe = "|" in (prev_op, next_op)
        base = os.path.basename(head) if head else head
        if base == "export":
            if in_pipe or next_op == "&":
                return  # runs in a subshell: the state change is lost
            conditional = prev_op in ("&&", "||")
            for w in args:
                lit = w[0][1] if w and w[0][0] == "lit" else ""
                m = ASSIGNMENT.match(lit)
                if m:
                    value = self.text_of([("lit", m.group(2))] + w[1:], frame)[0]
                    frame.vars[m.group(1)] = UNKNOWN if conditional and m.group(1) in GIT_ENV_NAMES else value
                    frame.exported.add(m.group(1))
                elif lit:
                    frame.exported.add(lit)
        elif base in ("cd", "pushd", "popd"):
            self.change_dir(base, args, frame, prev_op, next_op, in_pipe)
        elif base == "git":
            self.git(args, frame, prefix_env, prev_op)
        elif base in SHELLS or base == "eval":
            # stdin is not the terminal: a pipe (also into `( ... )`), or `<<<text bash`
            fed = prev_op in ("|", "(") or any(
                isinstance(t, str) and REDIRECTION.match(t) and is_stdin_redirection(t)
                for t, _ in (self.text_of(w, frame) for w in leading_words))
            self.nested_shell(base, args, frame, fed)

    def nested_shell(self, base, args, frame, piped=False):
        """`bash -c '<text>'` / `eval <text>`: analyse the text as a command list.  A shell
        that reads its commands from a pipe (`echo ... | bash`) gets text the hook cannot see."""
        if base == "eval":
            parts = [self.text_of(a, frame) for a in args]
        else:
            kind, text_word = self.shell_command_text(args, frame)
            if kind == "stdin" and piped:
                text_word = (UNKNOWN, "текст для оболочки подан через конвейер")
            elif kind != "text":
                return
            parts = [text_word]
        if any(t is UNKNOWN for t, _ in parts):
            reason = next(r for t, r in parts if t is UNKNOWN)
            self.verdicts.append(("UNKNOWN", "текст для оболочки не установлен (%s)" % reason))
            return
        if self.depth < 8:
            self.depth += 1
            self.run(lex(" ".join(t for t, _ in parts)), frame.copy())
            self.depth -= 1

    def shell_command_text(self, args, frame):
        """("text", (text, reason)) for the `-c` text of a shell call, ("script", None) when it
        runs a script file, ("stdin", None) when it reads commands from stdin.  bash rules (WP-484 Ф298, cold review 10.11): options come
        before the first operand, `-o`/`+o`/`-O`/`+O`/`--rcfile`/`--init-file` take the next
        word, redirections are skipped, `--` or `-` end the options; with `-c` the first
        operand is the command text, without it the script file.  A word that cannot be
        resolved among the options, or a here-string/here-doc feeding a shell without `-c`,
        is (UNKNOWN, reason)."""
        has_c, has_s, stdin_text, k = False, False, False, 0
        while k < len(args):
            word, reason = self.text_of(args[k], frame)
            if word is UNKNOWN:
                return ("text", (UNKNOWN, "аргумент оболочки не установлен (%s)" % reason))
            if word in ("--", "-"):
                k += 1
                while k < len(args):  # `bash - <<<text`: redirections still follow
                    rest, _ = self.text_of(args[k], frame)
                    if not (isinstance(rest, str) and REDIRECTION.match(rest)):
                        break
                    stdin_text = stdin_text or is_stdin_redirection(rest)
                    k += 2 if BARE_REDIRECTION.match(rest) else 1
                break
            if REDIRECTION.match(word):
                stdin_text = stdin_text or is_stdin_redirection(word)
                k += 2 if BARE_REDIRECTION.match(word) else 1
                continue
            if word.startswith("--"):
                k += 2 if word in SHELL_OPTION_ARG else 1
                continue
            if len(word) > 1 and word[0] in "-+":
                cluster = word[1:]
                has_c = has_c or (word[0] == "-" and "c" in cluster)
                has_s = has_s or (word[0] == "-" and "s" in cluster)
                k += 2 if (word in SHELL_OPTION_ARG or "o" in cluster or "O" in cluster) else 1
                continue
            break
        if has_c:
            return ("text", self.text_of(args[k], frame)) if k < len(args) else ("script", None)
        if stdin_text:
            return ("text", (UNKNOWN, "текст для оболочки подан через перенаправление ввода"))
        if k < len(args) and not has_s:
            return ("script", None)  # a script file; its arguments follow
        return ("stdin", None)  # reads commands from stdin (`-s`: operands are positional args)

    def strip_wrappers(self, words, frame, prefix_env):
        while words:
            head, _ = self.text_of(words[0], frame)
            if head is UNKNOWN:
                return words  # simple() reports the unresolved command name
            if REDIRECTION.match(head):
                # `>/dev/null git add` (cold review 10.11: the redirection was taken as the command)
                words = words[2:] if BARE_REDIRECTION.match(head) else words[1:]
                continue
            base = os.path.basename(head) if head else ""
            if base in KEYWORDS:
                words = words[1:]
                continue
            if base not in WRAPPERS:
                break
            skip_args = WRAPPER_OPTION_ARG.get(base, set())
            words = words[1:]
            while words:
                t, reason = self.text_of(words[0], frame)
                if t is UNKNOWN:
                    if base == "env":
                        # `env ${ARR[@]}` may set GIT_DIR/GIT_INDEX_FILE (WP-484 Ф298: it used to crash).
                        self.verdicts.append(("UNKNOWN", "аргумент env не установлен (%s)" % reason))
                        return []
                    break  # the wrapped command itself; simple() reports its unresolved name
                lit = t or ""
                chdir = WRAPPER_CHDIR.get(base, ())
                if chdir and (lit in chdir or lit.startswith(tuple(o + "=" for o in chdir if o.startswith("--")))
                              or (len(chdir[0]) == 2 and lit.startswith(chdir[0]) and len(lit) > 2)):
                    self.verdicts.append(("UNKNOWN", "%s меняет рабочий каталог (%s)" % (base, lit)))
                    return []
                if base == "env" and (lit in ("-S", "--split-string") or lit.startswith("--split-string=")
                                      or (lit.startswith("-S") and len(lit) > 2)):
                    # `env -S 'git add f'` runs its operand as a command line (cold review 10.11).
                    if lit in ("-S", "--split-string"):
                        split, rest = (self.text_of(words[1], frame) if len(words) > 1 else ("", None)), words[2:]
                    else:
                        split, rest = (lit.split("=", 1)[1] if lit.startswith("--") else lit[2:], None), words[1:]
                    pieces = [split] + [self.text_of(w, frame) for w in rest]
                    unknown = next((r for t2, r in pieces if t2 is UNKNOWN), None)
                    if unknown is not None or split[0] is UNKNOWN:
                        self.verdicts.append(("UNKNOWN", "строка env -S не установлена (%s)" % unknown))
                    elif self.depth < 8:
                        self.depth += 1
                        self.run(lex(" ".join(t2 for t2, _ in pieces)), frame.copy())
                        self.depth -= 1
                    return []
                if REDIRECTION.match(lit):
                    words = words[2:] if BARE_REDIRECTION.match(lit) else words[1:]
                    continue
                m = ASSIGNMENT.match(lit) if base == "env" else None
                if m:
                    prefix_env[m.group(1)] = m.group(2)
                    words = words[1:]
                elif base == "env" and lit in ("-u", "--unset") and len(words) > 1:
                    prefix_env[self.text_of(words[1], frame)[0] or ""] = ""  # empty = absent
                    words = words[2:]
                elif base == "env" and lit in ("-i", "--ignore-environment", "-"):
                    for name in GIT_ENV_NAMES:
                        prefix_env[name] = ""
                    words = words[1:]
                elif lit.startswith("-") and lit != "-":
                    words = words[2:] if lit in skip_args else words[1:]
                elif base == "timeout" and re.fullmatch(r"[0-9.]+[smhd]?", lit):
                    words = words[1:]
                    break
                else:
                    break
        return words

    def change_dir(self, kind, args, frame, prev_op, next_op, in_pipe):
        cur = frame.current(prev_op == "&&")
        # `cd -P -- dir`: options are not directories
        while args and self.text_of(args[0], frame)[0] in ("-L", "-P", "-e", "-@", "--"):
            args = args[1:]
        if kind == "popd":
            new = {UNKNOWN}
        else:
            target = args[0] if args and self.text_of(args[0], frame)[0] != "-" else None
            if not args:
                home = os.environ.get("HOME")
                new = {home} if home else {UNKNOWN}
            elif target is None:
                new = {UNKNOWN}
            else:
                path, _ = self.text_of(target, frame)
                new = {UNKNOWN if (path is UNKNOWN or d is UNKNOWN)
                       else os.path.normpath(os.path.join(d, path)) for d in cur}
        if in_pipe or next_op == "&":
            return  # runs in a subshell: the directory change is lost
        if next_op == "&&":
            frame.chain = new
        else:
            frame.dirs = cur | new
            frame.chain = None

    def git(self, args, frame, prefix_env, prev_op):
        cur = frame.current(prev_op == "&&")
        c_chain, git_dir, i = [], "unset", 0
        sub, rest = None, []
        while i < len(args):
            t, reason = self.text_of(args[i], frame)
            if t is UNKNOWN:
                if sub is None:
                    # An unresolved global option or subcommand may hide a staging call.
                    self.verdicts.append(("UNKNOWN", reason))
                    return
                rest.append(t)
                i += 1
                continue
            if sub is None and REDIRECTION.match(t):
                # `git 2>/dev/null add f` (cold review 10.11: the redirection became the subcommand)
                i += 2 if BARE_REDIRECTION.match(t) else 1
                continue
            if sub is None:
                if t.startswith("-C") and len(t) > 2:  # `-C/path`, joined form
                    c_chain.append((t[2:], None))
                    i += 1
                    continue
                if t in GIT_OPTION_ARG:
                    val = self.text_of(args[i + 1], frame) if i + 1 < len(args) else ("", None)
                    if t == "-C":
                        c_chain.append(val)
                    elif t == "--git-dir":
                        git_dir = val
                    i += 2
                    continue
                if t.startswith("--git-dir="):
                    git_dir = (t.split("=", 1)[1], None)
                    i += 1
                    continue
                if t.startswith("-"):
                    i += 1
                    continue
                sub = t
            else:
                rest.append(t)
            i += 1
        if sub in ("add", "stage"):
            pass
        elif sub == "restore" and any(r is not UNKNOWN and (r == "--staged" or (r.startswith("-") and not r.startswith("--") and "S" in r))
                                      for r in rest if r and r != "--"):
            pass
        elif sub == "restore" and any(r is UNKNOWN for r in rest):
            # An unresolved argument may be --staged (WP-484 Ф298: it used to crash).
            self.verdicts.append(("UNKNOWN", "аргумент git restore не установлен"))
            return
        else:
            return
        self.resolve_index(cur, c_chain, git_dir, frame, prefix_env)

    def env_value(self, name, frame, prefix_env):
        if name in prefix_env:
            v = prefix_env[name]
            return (v, None) if v is not UNKNOWN else (UNKNOWN, "значение %s задано нелитерально" % name)
        if name in frame.exported:
            v = frame.vars.get(name, UNKNOWN)
            return (v, None) if v is not UNKNOWN else (UNKNOWN, "значение %s задано нелитерально" % name)
        # inherited from the process that started the hook (the shell usually has the same)
        return os.environ.get(name), None

    def resolve_index(self, dirs, c_chain, git_dir, frame, prefix_env):
        idx_file, idx_reason = self.env_value("GIT_INDEX_FILE", frame, prefix_env)
        env_git_dir, gd_reason = self.env_value("GIT_DIR", frame, prefix_env)
        if git_dir == "unset":
            git_dir = (env_git_dir, gd_reason)
        for d in dirs:
            if d is UNKNOWN:
                self.verdicts.append(("UNKNOWN", "рабочий каталог не установлен (cd с неизвестным путём)"))
                continue
            for val, reason in c_chain:
                if val is UNKNOWN:
                    self.verdicts.append(("UNKNOWN", reason))
                    d = UNKNOWN
                    break
                d = os.path.normpath(os.path.join(d, val))
            if d is UNKNOWN:
                continue
            if idx_file is UNKNOWN:
                self.verdicts.append(("UNKNOWN", idx_reason))
                continue
            if idx_file:
                index = os.path.realpath(os.path.join(d, idx_file))
            else:
                gd, gd_why = git_dir if git_dir else (None, None)
                if gd is UNKNOWN:
                    self.verdicts.append(("UNKNOWN", gd_why))
                    continue
                status, index = git_index_path(d, gd or None)
                if status == "norepo":
                    continue  # git itself refuses: nothing is staged
                if status == "error":
                    self.verdicts.append(("UNKNOWN", "не удалось определить индекс (%s)" % index))
                    continue
            if index in self.frozen:
                self.verdicts.append(("FROZEN", self.frozen[index]))


_INDEX_CACHE = {}
# Each distinct (directory, git dir) costs a `git rev-parse`; a long command with many
# directories must not outlast the hook's timeout (cold review 10.11: 3 KB took 55 s).
INDEX_LOOKUP_LIMIT = 32


def git_index_path(cwd, git_dir):
    """Cached _git_index_path; beyond INDEX_LOOKUP_LIMIT distinct lookups it is "error"."""
    key = (cwd, git_dir)
    if key not in _INDEX_CACHE:
        if len(_INDEX_CACHE) >= INDEX_LOOKUP_LIMIT:
            return "error", "слишком много разных каталогов для проверки (> %d)" % INDEX_LOOKUP_LIMIT
        _INDEX_CACHE[key] = _git_index_path(cwd, git_dir)
    return _INDEX_CACHE[key]


def _git_index_path(cwd, git_dir):
    """("ok", real index path) | ("norepo", None) | ("error", reason).

    "norepo" is proof that git itself will refuse (missing directory, not a
    repository); anything else that fails is "error" and must not be read as
    "nothing is staged".
    """
    if not os.path.isdir(cwd):
        return "norepo", None
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    cmd = ["git", "-C", cwd] + (["--git-dir", git_dir] if git_dir else []) + ["rev-parse", "--git-path", "index"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        return "error", type(exc).__name__
    if out.returncode == 0 and out.stdout.strip():
        return "ok", os.path.realpath(os.path.join(cwd, out.stdout.strip()))
    if "not a git repository" in out.stderr.lower():
        return "norepo", None
    return "error", "git rev-parse завершился с кодом %d" % out.returncode


def main(argv):
    cwd, frozen = os.getcwd(), []
    i = 1
    while i < len(argv):
        if argv[i] == "--cwd" and i + 1 < len(argv):
            cwd = argv[i + 1]
            i += 2
        elif argv[i] == "--frozen" and i + 1 < len(argv):
            frozen.append(argv[i + 1])
            i += 2
        else:
            i += 1
    frozen_indexes = {}
    for f in frozen:
        status, value = git_index_path(f, None)
        if status == "ok":
            frozen_indexes[value] = f
        elif status == "error":
            print("UNKNOWN\tне удалось определить индекс замороженного канона %s (%s)" % (f, value))
            return
    analyzer = Analyzer(cwd, frozen_indexes)
    analyzer.run(lex(sys.stdin.read()), Frame({os.path.realpath(cwd)}))
    analyzer.verdicts.extend(("UNKNOWN", reason) for reason in LEX_ERRORS)
    frozen_hits = [v for kind, v in analyzer.verdicts if kind == "FROZEN"]
    unknown = [v for kind, v in analyzer.verdicts if kind == "UNKNOWN"]
    if frozen_hits:
        print("FROZEN\t%s" % frozen_hits[0])
    elif unknown:
        print("UNKNOWN\t%s" % unknown[0])
    else:
        print("ALLOW")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception as exc:  # fail closed: an unreadable verdict must not allow staging
        print("UNKNOWN\tвнутренняя ошибка разбора: %s" % type(exc).__name__)
    sys.exit(0)
