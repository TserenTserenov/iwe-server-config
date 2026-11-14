#!/usr/bin/env python3
"""Digest of AGENTS.md for agents with a small rules window (WP-7 F309).

Grok reads every rules file only up to 10 000 characters, and AGENTS.md is
about 24 000: the blocking style rules A12/A14, the implementation identity
rule, the agent session rules, commit attribution and the pilot shorthand lie
past that window. Grok also reads a global ~/.grok/AGENTS.md with its own
10 000-character window, so this script builds that file from AGENTS.md
mechanically, not by hand:
  1. a first line telling the agent to read the full AGENTS.md with its file
     tool before any work (the digest is a pointer, not a replacement);
  2. every blocking rule (sections marked CRITICAL, style rules A12 and A14)
     with its lead sentence;
  3. the lead sentence of every other section that starts past the window.
Nothing here is a new rule; the digest is a generated view of AGENTS.md.

  --write PATH   write the digest
  --check PATH   compare PATH with a fresh digest (exit 1 on mismatch)
  --print        print the digest
Fails (exit 1) if the digest exceeds LIMIT characters, so the window holds it.
"""

import argparse
import re
import sys
from pathlib import Path

LIMIT = 10000
SECTION_RE = re.compile(r"^## (.+)$", re.M)
BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
# Blocking style rules live inside one long paragraph; each keeps its first
# two clauses (A14's second clause is the working part: "part of" only between
# systems, with its test).
STYLE_RULES = ("A12", "A14")
STYLE_CLAUSES = 2
MAX_SENTENCE = 320


def sections(text):
    marks = list(SECTION_RE.finditer(text))
    for i, mark in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        yield mark.start(), mark.group(1).strip(), text[mark.end():end]


def first_sentence(text, clauses=1):
    """Text up to the n-th full stop or semicolon outside brackets, capped at a word."""
    depth, seen = 0, 0
    for i, char in enumerate(text):
        if char in "(«":
            depth += 1
        elif char in ")»":
            depth = max(depth - 1, 0)
        elif char in ".;" and depth == 0 and (i + 1 == len(text) or text[i + 1] == " "):
            seen += 1
            if seen == clauses:
                text = text[:i]
                break
    if len(text) > MAX_SENTENCE:
        text = text[:MAX_SENTENCE].rsplit(" ", 1)[0] + " …"
    return text.rstrip() + "."


def drop_brackets(text):
    """Remove top-level (...) asides: the digest keeps the rule, not its clarifications."""
    out, depth = [], 0
    for char in text:
        if char == "(":
            depth += 1
        elif char == ")" and depth:
            depth -= 1
        elif depth == 0:
            out.append(char)
    return " ".join("".join(out).split()).replace(" ,", ",").replace(" ;", ";")


def lead_sentence(body):
    """The bold lead of the first paragraph, or its first sentence if it has none."""
    paragraphs = [" ".join(p.split()) for p in body.strip().split("\n\n") if p.strip()]
    for paragraph in paragraphs:
        match = BOLD_RE.match(paragraph)
        if match:
            return first_sentence(match.group(1))
    return first_sentence(paragraphs[0]) if paragraphs else ""


NOT_PROSE = ("#", ">", "```", "|", "<!--")
BEYOND_PARAGRAPHS = 3


def paragraph_leads(body, count):
    """First sentence of each of the first `count` prose paragraphs (bold kept as text)."""
    paragraphs = [" ".join(p.split()) for p in body.strip().split("\n\n") if p.strip()]
    prose = [p.replace("**", "") for p in paragraphs if not p.startswith(NOT_PROSE)]
    return " ".join(first_sentence(p) for p in prose[:count])


def style_rule(body, rule):
    match = re.search(r"\*\*" + rule + r" \(([^)]*)\)\*\*(.*)", " ".join(body.split()))
    if not match:
        return ""
    return f"**{rule} ({match.group(1)})** " + first_sentence(drop_brackets(match.group(2)), STYLE_CLAUSES)


def build(agents_text, source_label):
    blocking, beyond = [], []
    for start, heading, body in sections(agents_text):
        pointer = f"Полный текст — раздел «{heading}»."
        if heading.startswith("Response Style"):
            blocking += [f"- {line} {pointer}" for line in (style_rule(body, r) for r in STYLE_RULES) if line]
        elif "CRITICAL" in heading:
            blocking.append(f"- **{heading}.** {lead_sentence(body)} {pointer}")
        elif start >= LIMIT:
            beyond.append(f"- **{heading}.** {paragraph_leads(body, BEYOND_PARAGRAPHS)}")
    lines = [
        "# IWE: правила длиннее твоего окна — сначала прочитай их целиком",
        "",
        f"**До первой работы прочитай `{source_label}` целиком инструментом чтения файлов.** Ты получаешь только "
        f"первые {LIMIT} символов этого файла, а правила дальше обязательны так же. Ниже — выжимка, "
        "сгенерированная `scripts/blocking-rules-digest.py` (WP-7 Ф309); при расхождении действует полный текст.",
        "",
        "## Блокирующие правила",
        "",
        *blocking,
        "",
        f"## Разделы за пределами первых {LIMIT} символов",
        "",
        *beyond,
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--agents", type=Path, default=Path("AGENTS.md"))
    parser.add_argument("--source-label", default="~/IWE/AGENTS.md")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", type=Path)
    mode.add_argument("--check", type=Path)
    mode.add_argument("--print", action="store_true")
    args = parser.parse_args()

    digest = build(args.agents.read_text(encoding="utf-8"), args.source_label)
    if len(digest) > LIMIT:
        print(f"blocking-rules-digest: {len(digest)} characters, over the {LIMIT} window", file=sys.stderr)
        return 1
    if args.print:
        sys.stdout.write(digest)
    elif args.write:
        args.write.parent.mkdir(parents=True, exist_ok=True)
        args.write.write_text(digest, encoding="utf-8")
        print(f"blocking-rules-digest: wrote {args.write} ({len(digest)} characters)")
    else:
        if not args.check.is_file() or args.check.read_text(encoding="utf-8") != digest:
            print(f"blocking-rules-digest: {args.check} is missing or stale; regenerate with --write")
            return 1
        print(f"blocking-rules-digest: {args.check} is current ({len(digest)} characters)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
