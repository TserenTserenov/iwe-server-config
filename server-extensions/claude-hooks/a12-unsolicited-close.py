#!/usr/bin/env python3
"""A12 unsolicited-close detector (WP-561, peer-session 2026-09-29-19-wp561-close-proposal-bias).

Prints the offending final line and exits 0 when BOTH hold:
  A. the last non-empty line of the assistant's final text proposes or awaits
     closing the session;
  B. the last HUMAN pilot message has no positive intent to close.
Prints nothing otherwise. Never raises on malformed input (a Stop hook must not
break the turn): unreadable transcript means no signal.

Usage: a12-unsolicited-close.py <transcript.jsonl>
       a12-unsolicited-close.py --prompt-intends-close   (prompt on stdin, prints yes|no)
       a12-unsolicited-close.py --valid-prefix <regex>   (prompt on stdin, prints offset of the first command match)
       a12-unsolicited-close.py --mask-quotes            (prompt on stdin, prints it with quoted spans blanked)
       a12-unsolicited-close.py --shorthand              (prompt on stdin, prints "psz|sz whole|trailing" or "")
"""
import json
import re
import sys

# Lexicon of close proposals in the assistant's line. Words only, no logic:
# the pilot-intent check below is what keeps this from firing on real commands.
CLOSE_PROPOSAL_RE = re.compile(
    r"закрывай|закрываем\s+(?:эту\s+|данную\s+)?(?:сессию|разговор)"
    r"|закрыть\s+(?:эту\s+|данную\s+)?(?:сессию|разговор)"
    r"|закрыти[ея]\s+сессии|триггер\w*\s+закрыти|можно\s+закрывать"
    # Asking for the publish word or the pilot's shorthands (WP-605, 25.11.2026: 81 of 514
    # turns asked for «закрывай/заливай/ПСЗ/СЗ»; pack rule 6.5 forbids both). Quoted and
    # after an ask verb only: "поручение «ПСЗ» выполнено" or a rule naming «заливай» is a
    # report, not an ask (Fable review 25.11).
    r"|(?:сказать|скажите|скажи|написать|напишите|напиши|ответить|ответьте|ответь)"
    r"\s+«\s*(?:заливай|запуши|псз|сз)\s*[»,.!]",
    re.IGNORECASE,
)

# Pilot lexicon: a positive intent must be an imperative, not a mention.
# Includes push phrases (CLAUDE.md §2 rule 2 treats them as close triggers) and
# the slash commands whose command block is otherwise a synthetic record.
# "закрой шаг / фазу / пункт ..." names a non-session object, so it is not a
# close command (РП-605, 30.10.2026: a pasted "закрой шаг «...»" armed the
# close obligation and blocked a commit). The object list is explicit (P13):
# "закрой задачу / РП / сессию" stay close triggers, extend only from misses.
CLOSE_INTENT_RE = re.compile(
    r"(?:закрывай|закрываю|закрой(?:те)?|закрываем|закроем)\b"
    r"(?!\s+(?:этот\s+|данный\s+|тот\s+|ещё\s+)?(?:шаг|фаз|пункт|вопрос|issue|тикет|баг|файл|окн|ветк))"
    r"|можно\s+закрывать|пора\s+закрыва"
    r"|заливай|запуши|запушь"
    r"|/(?:day|week|month|quick)-close\b|/run-protocol\s+(?:day-|week-|month-)?close\b",
    re.IGNORECASE,
)
STANDALONE_ALL_RE = re.compile(r"^\s*вс[её]\W*$", re.IGNORECASE)

# A negation, question or condition shortly BEFORE the trigger cancels that
# occurrence ("не закрывай", "почему ты пишешь закрывай", "если я скажу закрывай").
NEGATION_BEFORE_RE = re.compile(
    r"(?:\bне\b|\bпока\b|почему|зачем|отчего|\bесли\b|\bкогда\b|скажу|предлагай)[^.!?,;:\n—]{0,25}$",
    re.IGNORECASE,
)

# Text blocks that a user-typed record can carry but a human did not write.
SYNTHETIC_PREFIXES = (
    "<task-notification", "[system notification", "another claude session sent",
    "<agent-message", "<system-reminder", "<local-command-stdout",
    "<local-command-caveat", "<user-prompt-submit-hook",
    "base directory for this skill:", "caveat:",
)
# A slash command typed by the pilot arrives as a command block: keep its
# name and args as the pilot's text ("/day-close"), drop the wrapper tags.
COMMAND_BLOCK_RE = re.compile(r"<command-(?:name|args)>(.*?)</command-(?:name|args)>", re.DOTALL)
# Wrappers that appear INSIDE a human message and must be dropped from it.
INLINE_WRAPPER_RE = re.compile(
    r"<(system-reminder|ide_selection|ide_opened_file)>.*?</\1>", re.DOTALL
)
QUOTED_SPAN_RE = re.compile(r"«[^»]*»|\"[^\"]*\"|`[^`]*`|```.*?```", re.DOTALL)
# A pasted inbox/open-sessions.log line: "YYYY-MM-DD HH:MM | <wp> | <agent> | <note>".
# WP-484 Ф206 (live incident 16.10): a close word inside such a line, copied
# verbatim across hosts during cross-session discussion and never wrapped in
# any quote mark, armed the obligation even though the pilot was quoting
# another session's log entry, not commanding this one to close. Anchored to
# the start of the line so a real command sharing a line with log-like text
# after it is never masked -- only a line that itself opens with the log's own
# timestamp format is pasted content, not something the pilot typed as prose.
LOG_LINE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s*\|.*$", re.MULTILINE)
PASTE_PREFIX_LIMIT = 600  # same threshold as close-gate-reminder.sh

# The pilot's shorthands (CLAUDE.md section 9): «ПСЗ» = check with a subagent, push,
# close without reflection; «СЗ» = push and close without reflection.
# WP-561 F81 (21.11, live case on Tsekh: "вноси и долелай и потом ПСЗ" was missed
# because only the whole message counted, pilot decision 17.11). Two forms:
#   whole    -- the message is the shorthand alone;
#   trailing -- the shorthand is the last word after an instruction and follows a
#               boundary: start, punctuation or a connective ("и потом ПСЗ",
#               "доделай. СЗ"). A verb right before it ("ты не понял ПСЗ") is a
#               mention, not a command.
SHORTHAND_WHOLE_RE = re.compile(r"^\W*(п?сз)\W*$", re.IGNORECASE)
SHORTHAND_TRAILING_RE = re.compile(
    r"(?:^|[.,;:!—–\n-]|(?<!\w)(?:и|а|потом|затем|далее|после\s+этого|в\s+конце))"
    r"\s*(п?сз)(?!\w)\W*(?:(?:пожалуйста|спасибо)\W*)?$",
    re.IGNORECASE,
)
# A negation or a question word in the clause right before the shorthand makes it
# a complaint or a refusal, also across a comma: "ты опять не понял, ПСЗ",
# "сделай без ПСЗ", "не — ПСЗ", "вместо ПСЗ". Checked on the text before the
# shorthand with the boundary punctuation stripped. A missed command only brings
# back the reflection question; a false hit would skip it without the pilot's word.
SHORTHAND_CLAUSE_NEGATION_RE = re.compile(
    r"(?<!\w)(?:не|нет|без|вместо|почему|зачем)(?!\w)[^.!?;:\n]{0,30}$", re.IGNORECASE
)
# Another shorthand earlier in the same sentence means both are being named, not
# ordered: "объясни разницу между СЗ и ПСЗ", "ПСЗ, СЗ" (cold review 21.11).
SHORTHAND_NAMED_IN_CLAUSE_RE = re.compile(r"(?<!\w)п?сз(?!\w)[^.!?;\n]*$", re.IGNORECASE)
# Known trade-off (cold review 21.11): a complaint without a negation word
# ("ты опять ошибся, ПСЗ", "я же просил: ПСЗ") counts as the command; the pilot
# writes the shorthand after a complaint to mean "fix it and ПСЗ" as well.


def _rows(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    yield row
    except OSError:
        return


def _role(row):
    return row.get("type") or row.get("role") or ""


def _content(row):
    return row.get("message", {}).get("content", row.get("content", []))


def _text_blocks(row):
    content = _content(row)
    if isinstance(content, str):
        return [content]
    if not isinstance(content, list):
        return []
    return [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]


def _human_text(row):
    """Human-authored text of a user record, or None if not human.

    tool_result records need no special case: their text is nested inside the
    tool_result block, and only top-level text blocks are read here.
    """
    if _role(row) != "user" or row.get("isMeta"):
        return None
    parts = []
    for text in _text_blocks(row):
        if text.lstrip().startswith("<command-name>"):
            parts.append(" ".join(COMMAND_BLOCK_RE.findall(text)))
            continue
        if text.lstrip().lower().startswith(SYNTHETIC_PREFIXES):
            continue
        parts.append(INLINE_WRAPPER_RE.sub("", text))
    joined = "\n".join(p for p in parts if p.strip()).strip()
    return joined or None


def final_assistant_line(rows):
    """Last non-empty line of the assistant text after the last user record."""
    last_user = max((i for i, r in enumerate(rows) if _role(r) == "user"), default=-1)
    texts = []
    for row in rows[last_user + 1:]:
        if _role(row) == "assistant":
            texts.extend(_text_blocks(row))
    lines = [ln.strip() for ln in "\n".join(texts).splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def last_human_message(rows):
    for row in reversed(rows):
        text = _human_text(row)
        if text:
            return text
    return ""


def mask_quoted_spans(text):
    """Replace quoted spans AND pasted session-log lines with spaces of the
    same length (offsets stay valid)."""
    masked = QUOTED_SPAN_RE.sub(lambda m: " " * len(m.group()), text)
    return LOG_LINE_RE.sub(lambda m: " " * len(m.group()), masked)


def valid_trigger_starts(text, pattern=CLOSE_INTENT_RE, paste_limit=PASTE_PREFIX_LIMIT):
    """Yield start offsets (in the ORIGINAL text) of occurrences that are commands.

    Quotes are masked with spaces of the SAME length, so an offset here equals
    the offset in the prompt the shell sees: the 600-char paste limit and the
    threshold in close-gate-reminder.sh measure the same prefix.
    """
    stripped = mask_quoted_spans(text)
    for match in pattern.finditer(stripped):
        if paste_limit is not None and match.start() > paste_limit:
            continue  # buried in pasted text, not a direct command
        if NEGATION_BEFORE_RE.search(stripped[max(0, match.start() - 40):match.start()]):
            continue
        yield match.start()


def pilot_intends_to_close(text, paste_limit=PASTE_PREFIX_LIMIT):
    if STANDALONE_ALL_RE.match(text):
        return True
    return next(valid_trigger_starts(text, paste_limit=paste_limit), None) is not None


def pilot_shorthand(text, paste_limit=PASTE_PREFIX_LIMIT):
    """Return (kind, form): kind "psz"|"sz", form "whole"|"trailing"; ("", "") if none.

    Quoted spans are masked first; any question mark makes the message a question.
    A trailing shorthand after more than `paste_limit` characters is treated like a
    close word buried in pasted text: not a command (same 600 as the close words).
    """
    # The whole-message form is checked before masking: «ПСЗ» typed in quotes as
    # the only content counted before F81 and still does.
    whole = None if "?" in text else SHORTHAND_WHOLE_RE.match(text)
    if whole:
        return ("psz" if whole.group(1).lower() == "псз" else "sz"), "whole"
    stripped = mask_quoted_spans(text)
    if "?" in stripped:
        return "", ""
    trailing = SHORTHAND_TRAILING_RE.search(stripped)
    if not trailing:
        return "", ""
    if paste_limit is not None and trailing.start(1) > paste_limit:
        return "", ""
    clause = stripped[:trailing.start(1)].rstrip(" \t\n.,;:!—–-")
    if SHORTHAND_CLAUSE_NEGATION_RE.search(clause) or SHORTHAND_NAMED_IN_CLAUSE_RE.search(clause):
        return "", ""
    return ("psz" if trailing.group(1).lower() == "псз" else "sz"), "trailing"


def detect(path):
    rows = list(_rows(path))
    line = final_assistant_line(rows)
    if not line or not CLOSE_PROPOSAL_RE.search(line):
        return ""
    human = last_human_message(rows)
    # The pilot's own «ПСЗ»/«СЗ» is a close word too (CLAUDE.md section 9): an agent line
    # that answers it is not unsolicited (WP-605, 25.11.2026). Only here, not in
    # --prompt-intends-close, whose caller arms the close obligation with its own rules.
    if pilot_intends_to_close(human) or pilot_shorthand(human)[0]:
        return ""
    return line


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--prompt-intends-close":
        # Mode for close-gate-reminder.sh: raw prompt on stdin -> "yes" | "no".
        # Any failure exits non-zero, which the caller treats as "unknown" and
        # keeps the old arming behaviour (fail-open).
        prompt = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        # No paste limit here: close-gate-reminder.sh owns its own 600-char
        # threshold, including the "rejected quote ends the pending reflection
        # window" handling. This mode only answers "mention or command?".
        print("yes" if pilot_intends_to_close(prompt, paste_limit=None) else "no")
        sys.exit(0)
    if len(sys.argv) == 2 and sys.argv[1] == "--mask-quotes":
        # Prompt on stdin -> the same prompt with quoted spans blanked out. The reminder hook
        # runs its cancel phrases on this text: a cancel phrase inside a quote is a mention.
        sys.stdout.write(mask_quoted_spans(sys.stdin.buffer.read().decode("utf-8", errors="replace")))
        sys.exit(0)
    if len(sys.argv) == 2 and sys.argv[1] == "--shorthand":
        # Prompt on stdin -> "<kind> <form>" ("psz trailing") or an empty line.
        # Any failure exits non-zero; the reminder hook then falls back to its own
        # whole-message check (the behaviour before WP-561 F81).
        kind, form = pilot_shorthand(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
        print(f"{kind} {form}" if kind else "")
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == "--valid-prefix":
        # Offset of the first VALID occurrence of the given regex (a command, not a
        # quoted or negated mention), measured in the original prompt; empty when
        # there is none. The shell threshold is measured up to THIS trigger.
        prompt = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        pattern = re.compile(sys.argv[2], re.IGNORECASE)
        start = next(valid_trigger_starts(prompt, pattern, paste_limit=None), None)
        print("" if start is None else start)
        sys.exit(0)
    if len(sys.argv) != 2:
        sys.exit("usage: a12-unsolicited-close.py <transcript.jsonl> | --prompt-intends-close | --valid-prefix <regex>")
    hit = detect(sys.argv[1])
    if hit:
        print(hit)
