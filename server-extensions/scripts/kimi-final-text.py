#!/usr/bin/env python3
"""Authoritative final text of a Kimi session, read from its on-disk journal.

see DP.SC.202, DP.ROLE.099 (WP-524 F6)

The Kimi chat window inside the VS Code extension silently drops individual
stream chunks: on 2026-09-05 a 3220-byte report lost 8 whole tokens, including
"-watch" out of the filename "kimi-session-watchdog.sh". The journal written by
the same extension host held the text intact, so the loss happens strictly below
the journal write. This tool reads the journal instead of the window.

Journal shape, measured 2026-09-05 over the WHOLE local corpus of extension
0.7.5 -- 2502 journals, 3178 assistant text parts. These are observed
invariants, not a vendor contract, so every assumption below is checked at
runtime and refuses or complains rather than guessing:

  * assistant text arrives as  context.append_loop_event -> event.content.part
    with part.type == "text"; pilot prompts arrive as context.append_message,
    a different record type, so filtering by record type already filters by
    author (no role field on part events, 0 of 3178);
  * a part is published once, complete (0 repeated uuids of 3178);
  * exactly one text part per step (3178 of 3178);
  * the ONLY per-turn completion signal is turn.ended, which always carries an
    integer turnId (312 of 312) and a reason: completed 246, failed 34,
    cancelled 32 -- so 21% of turns end without a usable answer.
    prompt.completed carries no turnId at all (78 of 78) and therefore cannot
    certify any particular turn: a cancelled turn followed by a finished
    neighbour would otherwise pass as complete. The marker must also stand
    after the text it certifies.
"""

from __future__ import annotations

import argparse
import difflib
import glob
import json
import os
import re
import sys

MAIN_AGENT_GLOB = "~/.kimi-code/sessions/*/*/agents/main/wire.jsonl"
ANY_AGENT_GLOB = "~/.kimi-code/sessions/*/*/agents/*/wire.jsonl"
COMPLETED_REASON = "completed"

EXIT_OK = 0
EXIT_ERROR = 1
# 2 is argparse's own code for a bad command line -- leave it alone so a caller
# can tell "you mistyped a flag" from "the turn is not finished".
EXIT_DIFF_FOUND = 3
EXIT_TURN_UNFINISHED = 4

TOKEN_RE = re.compile(r"\S+|\s+")


def warn(message: str) -> None:
    print(f"ВНИМАНИЕ: {message}", file=sys.stderr)


def fail(message: str, code: int = EXIT_ERROR) -> None:
    print(f"ОШИБКА: {message}", file=sys.stderr)
    sys.exit(code)


def find_journal(session: str | None, explicit_file: str | None, any_agent: bool) -> str:
    if explicit_file:
        if not os.path.isfile(explicit_file):
            fail(f"журнал не найден: {explicit_file}")
        return explicit_file

    # Subagent journals (agents/agent-0, agent-1, ...) are newer than main while
    # a subagent runs, so "the freshest file" would hand back a subagent's text
    # as the session's answer. Only the main agent counts unless asked otherwise.
    pattern = ANY_AGENT_GLOB if any_agent else MAIN_AGENT_GLOB
    candidates = sorted(
        glob.glob(os.path.expanduser(pattern)),
        key=os.path.getmtime,
        reverse=True,
    )
    if not candidates:
        fail(f"ни одного журнала сессии Кими не найдено (искал в {pattern})")

    if session is None:
        return candidates[0]

    matching = [path for path in candidates if session in path]
    if not matching:
        fail(f"сессия «{session}» не найдена среди журналов в {pattern}")
    if len(matching) > 1:
        warn(
            f"под «{session}» подходит {len(matching)} журналов, "
            f"беру самый свежий: {matching[0]}"
        )
    return matching[0]


def load_records(path: str) -> list[dict]:
    records = []
    unparsed = 0
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except ValueError:
                unparsed += 1
    if unparsed:
        # Never swallow this: a corrupted journal line is exactly the kind of
        # silent loss this tool exists to expose.
        warn(f"{unparsed} строк журнала не разобрались как JSON — журнал повреждён")
    return records


def text_parts(records: list[dict]) -> list[tuple[int, int, int, str]]:
    """Return (file_position, turn, step, text) for every assistant text part."""
    found = []
    for position, record in enumerate(records):
        if record.get("type") != "context.append_loop_event":
            continue
        event = record.get("event") or {}
        if event.get("type") != "content.part":
            continue
        part = event.get("part") or {}
        part_type = part.get("type")
        text = part.get("text") or ""
        if part_type != "text":
            if text.strip():
                warn(
                    f"фрагмент неизвестного типа «{part_type}» содержит непустой текст "
                    f"({len(text)} символов) — формат журнала изменился, фрагмент не учтён"
                )
            continue
        turn, step = event.get("turnId"), event.get("step")
        if turn is None or step is None:
            # Guessing which turn an unlabelled fragment belongs to is how a
            # neighbouring turn's text ends up in the answer. Refuse instead.
            fail(
                "текстовый фрагмент без номера хода или шага — формат журнала "
                "изменился, определить финальный ответ нельзя"
            )
        try:
            found.append((position, int(turn), int(step), text))
        except (TypeError, ValueError):
            fail(f"номер хода/шага не число (ход {turn!r}, шаг {step!r}) — формат журнала изменился")
    return found


def completion_problem(records: list[dict], turn: int, last_text_position: int) -> str | None:
    """Return why `turn` is not a completed turn, or None if it is.

    Only turn.ended carries a turnId, so it is the only record that can certify
    this particular turn; its reason tells completed from cancelled/failed. The
    marker must also stand AFTER the text it certifies: text appended past the
    end of a turn is not covered by that turn's completion.
    """
    for position, record in enumerate(records):
        if record.get("type") == "turn.cancel" and record.get("turnId") == turn:
            return "ход отменён (turn.cancel)"
        if record.get("type") != "turn.ended" or record.get("turnId") != turn:
            continue
        reason = record.get("reason")
        if reason != COMPLETED_REASON:
            return f"ход завершился со статусом «{reason}», а не «{COMPLETED_REASON}»"
        if position < last_text_position:
            return (
                "текст дописан уже после пометки о завершении хода — "
                "пометка его не удостоверяет"
            )
        return None
    return "ход не завершён — агент ещё пишет либо ждёт разрешения"


def extract_final_text(path: str) -> str:
    records = load_records(path)
    parts = text_parts(records)
    if not parts:
        fail(f"в журнале {path} нет ни одного текстового ответа агента")

    last_turn = max(turn for _, turn, _, _ in parts)
    turn_positions = [position for position, turn, _, _ in parts if turn == last_turn]
    problem = completion_problem(records, last_turn, max(turn_positions))
    if problem is not None:
        fail(f"{problem}; частичный текст не выдаю", EXIT_TURN_UNFINISHED)

    last_step = max(step for _, turn, step, _ in parts if turn == last_turn)
    final = [
        (position, text)
        for position, turn, step, text in parts
        if turn == last_turn and step == last_step
    ]

    if final[-1][0] != parts[-1][0]:
        warn(
            "финальный шаг не является последней текстовой записью журнала — "
            "порядок событий не такой, как ожидалось"
        )
    if len(final) > 1:
        warn(
            f"в последнем шаге {len(final)} текстовых фрагментов вместо одного — "
            "инвариант формата нарушен, склеиваю в порядке появления"
        )
    return "\n".join(text for _, text in final)


def report_diff(authentic: str, shown: str) -> int:
    # Token-level, not character-level: SequenceMatcher is quadratic, and on a
    # 60 KB report the character version took 98 seconds of total silence. The
    # loss this tool looks for happens in whole tokens anyway.
    authentic_tokens = TOKEN_RE.findall(authentic)
    shown_tokens = TOKEN_RE.findall(shown)
    matcher = difflib.SequenceMatcher(None, authentic_tokens, shown_tokens, autojunk=False)

    findings = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        lost = "".join(authentic_tokens[i1:i2])
        extra = "".join(shown_tokens[j1:j2])
        around = "".join(authentic_tokens[max(0, i1 - 8) : i2 + 8]).replace("\n", " ")
        findings.append((tag, lost, extra, around))

    if not findings:
        print("Расхождений нет: показанный текст совпадает с журналом.")
        return EXIT_OK

    print(f"Расхождений с журналом: {len(findings)}\n")
    for tag, lost, extra, around in findings:
        if tag == "delete":
            print(f"  пропало {lost!r}")
        elif tag == "insert":
            print(f"  добавилось лишнее {extra!r}")
        else:
            print(f"  подменилось {lost!r} → {extra!r}")
        print(f"    в журнале: …{around}…\n")
    return EXIT_DIFF_FOUND


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Достоверный финальный текст сессии Кими из журнала на диске "
        "(окно чата теряет куски потока молча).",
    )
    parser.add_argument(
        "--session",
        help="подстрока идентификатора сессии; по умолчанию — самая свежая сессия",
    )
    parser.add_argument("--file", help="путь к wire.jsonl напрямую")
    parser.add_argument(
        "--any-agent",
        action="store_true",
        help="искать и среди журналов субагентов, не только основного агента",
    )
    parser.add_argument(
        "--diff",
        metavar="ФАЙЛ",
        help="сверить текст из ФАЙЛА (копия из окна чата) с журналом и показать пропажи",
    )
    args = parser.parse_args()

    journal = find_journal(args.session, args.file, args.any_agent)
    print(f"журнал: {journal}", file=sys.stderr)
    authentic = extract_final_text(journal)

    if args.diff is None:
        sys.stdout.write(authentic)
        if not authentic.endswith("\n"):
            sys.stdout.write("\n")
        return EXIT_OK

    if not os.path.isfile(args.diff):
        fail(f"файл для сверки не найден: {args.diff}")
    with open(args.diff, encoding="utf-8") as handle:
        shown = handle.read()
    return report_diff(authentic.strip(), shown.strip())


if __name__ == "__main__":
    sys.exit(main())
