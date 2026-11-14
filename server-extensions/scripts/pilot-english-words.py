#!/usr/bin/env python3
"""Propose words for the "left untranslated" list from the pilot's own messages (WP-7 F309).

The list in the author style layer S1 (line "**Whitelist**") holds the English
words the pilot uses himself (pack basic rule 2: terms the person uses may stay
untranslated). It used to grow from the agent's memory; this script reads the
pilot's messages in Claude Code transcripts of the last --days days and lists
the Latin-script words he used at least --min times that are not on the list.
It proposes only; the pilot decides.

Not counted: code spans, paths, URLs, words inside tags (hook and system
inserts), tool results, and messages that are only pasted material.

Usage:
  pilot-english-words.py --s1 communication-style-author.md
                         [--transcripts ~/.claude/projects] [--days 7] [--min 2]
"""

import argparse
import json
import re
import sys
import time
from collections import Counter
from pathlib import Path

WHITELIST_LINE = re.compile(r"^\*\*Whitelist\*\*[^:]*:\s*(.+)$", re.M)
NOISE = [
    re.compile(r"<([a-zA-Z_-]+)[^>]*>.*?</\1>", re.S),  # tagged inserts
    re.compile(r"```.*?```", re.S),
    re.compile(r"`[^`]*`"),
    re.compile(r"https?://\S+"),
    re.compile(r"\S*[/\\]\S*"),  # paths
    re.compile(r"\S+\.\w{1,5}\b"),  # file names
]
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
LATIN = re.compile(r"[A-Za-z]")
# The pilot writes in Russian and briefly; long or mostly-Latin "user" turns are
# skill texts, subagent prompts, notifications or pasted material, not his words.
MAX_PILOT_MESSAGE = 2000
MIN_CYRILLIC_SHARE = 0.6
WORD = re.compile(r"(?<![\w-])[A-Za-z][A-Za-z-]{2,}(?![\w-])")


def whitelist(s1_path):
    match = WHITELIST_LINE.search(s1_path.read_text(encoding="utf-8"))
    if not match:
        raise ValueError(f"no **Whitelist** line in {s1_path}")
    head = match.group(1).split(".")[0]
    # "Pull Request" is one entry but two words in a message
    return {word.lower() for entry in head.split(",") for word in entry.split()}


def pilot_texts(transcripts, since):
    # Only this workspace's sessions: other projects and automation runs are not the pilot's IWE chat.
    for path in transcripts.glob("*IWE*/*.jsonl"):
        if path.stat().st_mtime < since:
            continue
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if row.get("type") != "user" or row.get("isMeta") or row.get("isSidechain"):
                    continue
                content = (row.get("message") or {}).get("content")
                if isinstance(content, str):
                    yield content
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "text":
                            yield part.get("text", "")


def is_pilot_message(text):
    if not text or len(text) > MAX_PILOT_MESSAGE:
        return False
    cyr, lat = len(CYRILLIC.findall(text)), len(LATIN.findall(text))
    return cyr + lat > 0 and cyr / (cyr + lat) >= MIN_CYRILLIC_SHARE


def words(text):
    """Words as written: the caller tells names (always capitalised) from terms."""
    if not is_pilot_message(text):
        return []
    for pattern in NOISE:
        text = pattern.sub(" ", text)
    return WORD.findall(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--s1", type=Path, required=True)
    parser.add_argument("--transcripts", type=Path, default=Path.home() / ".claude" / "projects")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--min", type=int, default=2)
    args = parser.parse_args()
    try:
        known = whitelist(args.s1)
    except (OSError, ValueError) as error:
        print(f"pilot-english-words: {error}", file=sys.stderr)
        return 2
    since = time.time() - args.days * 86400
    counts, lowercase = Counter(), set()
    for text in pilot_texts(args.transcripts, since):
        for word in words(text):
            counts[word.lower()] += 1
            if word[0].islower():
                lowercase.add(word.lower())
    # A word never written in lower case is a name (person, product, company):
    # names stay untranslated by the pack rule anyway and must not reach the report.
    fresh = [(w, n) for w, n in counts.most_common() if n >= args.min and w not in known and w in lowercase]
    print(f"# Английские слова из ваших сообщений за {args.days} дн. (не в списке, не реже {args.min} раз)\n")
    if not fresh:
        print("Новых слов нет.")
        return 0
    for word, count in fresh[:30]:
        print(f"- {word} — {count}")
    print("\nДобавить в список «без перевода» (авторский слой S1)? Ответ: слова через запятую или «нет».")
    return 0


if __name__ == "__main__":
    sys.exit(main())
