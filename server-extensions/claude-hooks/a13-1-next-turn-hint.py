#!/usr/bin/env python3
"""Next-turn hint for rule A13.1 (РП-388 Ф36 step 5).

Called by inject-communication-style.sh on UserPromptSubmit. Looks at the
previous answer of the same conversation; if it held code names without a
Russian gloss, prints one line for the agent (the pilot never sees it).
The shown answer is never rewritten and no second message is produced, which
is why this replaced the A13.1 block (РП-605 review, 30.10).

A second hint (РП-605 Ф6, 02.11, pilot's word): when the "Дальше:" line of the
previous answer names this very chat as the place of a step (signal
A12_NEXT_PLACE_THIS_CHAT, rule 6), the agent gets one line about it. Unlike the
A13.1 hint it is not skipped for short prompts: «да» / «заливай» are exactly the
turns that follow a "Дальше:" line. The signal itself is logged by
response-clarity-hook.sh, so no extra log here.

A third hint (РП-388 Ф39, 03.11, pilot's word): inner IWE words of pack rule 9
(«корень», «канон», «боевой»…) in the previous answer that the pilot has not
used himself. It is a separate signal from A13.1 with its own log
(~/.claude/logs/style-jargon-hints.log), so the A13.1 measurement keeps its
meaning. It is not skipped for short prompts or questions: «делай а» and
«что там было сделано?» are followed by the longest reports.

Usage: a13-1-next-turn-hint.py <transcript.jsonl>   (prompt text in $PROMPT)
Prints nothing when there is no hint. Each hint is logged to
~/.claude/logs/style-next-turn-hints.log for the 08.11 measurement.
"""
import datetime as dt
import importlib.util
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from a13_1_symbols import find_symbols, is_human_turn, is_visible_reply, log_example, strip_fences  # noqa: E402
from iwe_jargon import find_jargon  # noqa: E402

try:
    _SPEC = importlib.util.spec_from_file_location("a12_next_block", Path(__file__).resolve().parent / "a12-next-block.py")
    _a12_next = importlib.util.module_from_spec(_SPEC)
    _SPEC.loader.exec_module(_a12_next)
except Exception as exc:  # the place hint is optional: a missing or broken a12 detector must not take the A13.1 hint down
    print(f"a13-1-next-turn-hint: place hint disabled, cannot load a12-next-block.py: {exc!r}", file=sys.stderr)
    _a12_next = None

# Prompts that get no hint (cold review by Fable, 01.11, point 7): a short
# reply or a question is not a turn that needs prose. Acknowledgements
# («да», «заливай», «псз») are all shorter than the threshold.
SHORT_PROMPT_CHARS = 40

HINT = ("Подсказка по стилю (правило A13.1, пилот её не видит): в прошлом ответе были "
        "имена из кода без русского пояснения: {names}. В этом ответе имена из кода "
        "(функции, переменные, параметры, типы ошибок) — только в скобках после "
        "русского объяснения или не писать; номер коммита и ссылка на документ допустимы "
        "рядом с русской подписью, ветка и служебный путь — только если пилоту нужно с ними "
        "что-то сделать. Прошлый ответ не исправлять и не упоминать.")


PLACE_HINT = ("Подсказка по стилю (правило 6, пилот её не видит): в строке «Дальше:» прошлого "
              "ответа место шага названо для этого же чата («в этом чате», «здесь»). «Где» "
              "пишется только когда шаг вне этого чата (новая беседа на РП-N, панель, файл, "
              "сервис); для этого чата достаточно «вы: что». Прошлый ответ не исправлять и не упоминать.")


JARGON_HINT = ("Подсказка по стилю (правило A0 и правило 9 пака, пилот её не видит): в прошлом "
               "ответе были слова внутренней кухни IWE: {words}. В этом ответе переводи их простыми понятными "
               "словами (словарь — пак, правило 9), если пилот сам не употребляет их в этом "
               "разговоре. Прошлый ответ не исправлять и не упоминать.")


def wants_hint(prompt):
    text = prompt.strip()
    return len(text) > SHORT_PROMPT_CHARS and not text.endswith("?")


def human_text(rec):
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return content.strip()
    return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text").strip()


def read_turns(path, prompt):
    """(human text, [assistant text blocks]) per human turn, the current prompt dropped.

    Claude Code may or may not have written the current prompt to the
    transcript yet; a trailing human turn equal to it is skipped.
    """
    turns = []  # (human text, [assistant text blocks]) per human turn
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("isSidechain"):
                continue
            if is_human_turn(rec):
                turns.append((human_text(rec), []))
                continue
            if not turns or rec.get("type") != "assistant" or not is_visible_reply(rec):
                continue
            for block in (rec.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text" and block.get("text", "").strip():
                    turns[-1][1].append(block["text"])
    if turns and not turns[-1][1] and turns[-1][0] == prompt.strip():
        turns.pop()
    return turns


def last_answer(turns):
    """Text of the answer to the last human turn, or ''.

    A previous turn without text (tool calls only, API error) gives '' rather
    than an older answer.
    """
    return "\n\n".join(turns[-1][1]) if turns else ""


def log_hint(session_id, names, name="style-next-turn-hints.log"):
    log = Path.home() / ".claude" / "logs" / name
    log.parent.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with log.open("a", encoding="utf-8") as fh:
        fh.write(f"{stamp} | {session_id} | {len(names)} | {log_example(names)}\n")


def place_line(answer):
    """The "Дальше:" text of the answer if it names this chat as the place of a step."""
    if _a12_next is None:
        return None
    tail = [ln.strip() for ln in answer.splitlines() if ln.strip()][-3:]
    next_line = next((m.group(1) for ln in tail if (m := _a12_next.NEXT_LINE_RE.match(ln))), None)
    return _a12_next.this_chat_place_line(next_line) if next_line else None


def main(argv):
    if len(argv) != 2 or not os.path.isfile(argv[1]):
        return 0
    prompt = os.environ.get("PROMPT", "")
    turns = read_turns(argv[1], prompt)
    answer = last_answer(turns)
    hints = []
    names = find_symbols(strip_fences(answer)) if wants_hint(prompt) else []
    if names:
        try:
            log_hint(os.environ.get("SESSION_ID", "unknown"), names)
        except OSError as exc:
            # The hint still goes out; a lost log line only weakens the measurement.
            print(f"style-next-turn-hint: log write failed: {exc}", file=sys.stderr)
        hints.append(HINT.format(names=log_example(names, limit=200)))
    words = find_jargon(strip_fences(answer), [human for human, _ in turns] + [prompt])
    if words:
        try:
            log_hint(os.environ.get("SESSION_ID", "unknown"), words, name="style-jargon-hints.log")
        except OSError as exc:
            print(f"style-next-turn-hint: jargon log write failed: {exc}", file=sys.stderr)
        hints.append(JARGON_HINT.format(words=", ".join(words)))
    if place_line(answer):
        hints.append(PLACE_HINT)
    if hints:
        print("\n".join(hints))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
