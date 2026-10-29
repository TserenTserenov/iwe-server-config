#!/usr/bin/env python3
"""A12 cross-turn repeat detector (РП-605 Ф6, 29.10.2026, peer-session
2026-10-29-23-wp605-cross-turn-detector, Claude+Kimi+Codex).

Live case (29.10, Mac and tsekh-1): an almost identical decision block shows up
in two consecutive assistant replies with no pilot message between them -- the
second reply is written after a service record (typically a background-task
notification) re-opened the turn. Text fixes of rule 6 cannot reach a resumed
long conversation (the CLI reads instructions once), but this file is read from
disk on every Stop-hook call, so it works there too.

Definitions (see the session report for the reasoning):
  episode       a stretch of the transcript opened by a `user` record that
                carries text (human or service), or by a `queued_command`
                attachment (how background-task notifications are really
                stored). A `user` record holding only a tool_result does not
                open one.
  opener kind   human   -- `_human_text` finds pilot text (this includes a mixed
                           record with pilot text beside service wrappers);
                service -- every text block starts with a SYNTHETIC_PREFIXES
                           wrapper (task-notification, system-reminder, ...);
                unknown -- anything else (e.g. isMeta without pilot text).
  final reply   assistant text blocks after the episode's last tool_result;
                none if the episode ends on a tool_use (unfinished).

Signal A12_CROSS_TURN_REPEAT: the last episode is service-opened, both it and
the previous one have a final reply, and the Jaccard similarity of their word
3-gram sets is >= the body threshold (IWE_A12_REPEAT_THRESHOLD, default 0.6)
OR the similarity of their "Дальше:" parts is >= the next-line threshold
(IWE_A12_REPEAT_NEXT_THRESHOLD, default 0.8). The second arm exists because
calibration on 514 real transcripts (29.10) found the repeat there almost
always in the "Дальше:" line with a different body (11 of 279 pairs having that
line in both replies, score ~1.0), never as a whole repeated reply.
Any human opener, unknown opener, unfinished episode or fewer than 3 trigram
positions in either text -> no signal. Warn-only; a similar pair is a reason for
manual review, not proof of a defect.

Reuses the transcript-walk helpers of a12-unsolicited-close.py (loaded via
importlib: the hyphen in its name rules out a plain import).

Usage: a12-cross-turn-repeat.py <transcript.jsonl>            one line when the signal fires, else nothing
       a12-cross-turn-repeat.py --explain <transcript.jsonl>  JSON for the last pair, always (calibration)
       a12-cross-turn-repeat.py --scan <transcript.jsonl>...  JSON line per service-opened pair
"""
import hashlib
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "a12_unsolicited_close", Path(__file__).parent / "a12-unsolicited-close.py"
)
_a12 = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_a12)

DEFAULT_THRESHOLD = 0.6
DEFAULT_NEXT_THRESHOLD = 0.8
MIN_TRIGRAM_POSITIONS = 3
NEXT_LINE_RE = re.compile(r"^[ \t]*Дальше:", re.MULTILINE)
BLANK_LINE_RE = re.compile(r"\n[ \t]*\n")
# One wrapper element such as <task-notification>...</task-notification>.
WRAPPER_RE = re.compile(r"<([\w-]+)(?:\s[^>]*)?>.*?</\1>", re.DOTALL)
# Shared service wrappers plus the Stop-hook feedback the harness injects as an
# isMeta user record with a plain-string body (997 such records in the Mac
# transcripts, 29.10): the reply written after it is the very "rewrite after a
# block" case the pilot reported, so it must open a service episode.
SERVICE_PREFIXES = tuple(_a12.SYNTHETIC_PREFIXES) + ("stop hook feedback:",)
WORD_RE = re.compile(r"\w+", re.UNICODE)
# A token holding a digit, or a hex-looking run of 7+ chars (commit hash), is
# a state marker: masked in the diagnostic score only.
HASHLIKE_RE = re.compile(r"^[0-9a-f]{7,}$")


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def threshold():
    return _env_float("IWE_A12_REPEAT_THRESHOLD", DEFAULT_THRESHOLD)


def next_threshold():
    return _env_float("IWE_A12_REPEAT_NEXT_THRESHOLD", DEFAULT_NEXT_THRESHOLD)


def _has_tool_use(row):
    content = _a12._content(row)
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_use" for b in content
    )


def _has_tool_result(row):
    content = _a12._content(row)
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def _queued_prompt(row):
    """Text of a `queued_command` attachment record, else None.

    Calibration on 514 real transcripts (29.10) showed that a background-task
    notification is NOT stored as a `user` record: it arrives as
    {"type": "attachment", "attachment": {"type": "queued_command", "prompt": ...}}.
    The same record type carries a pilot message typed while the agent was busy.
    """
    att = row.get("attachment")
    if _a12._role(row) != "attachment" or not isinstance(att, dict):
        return None
    if att.get("type") != "queued_command" or not isinstance(att.get("prompt"), str):
        return None
    return att["prompt"]


def _is_service_text(text):
    """True when `text` is service wrappers only, with no pilot words next to them.

    A wrapper prefix alone is not enough: a record may hold a notification and a
    pilot question side by side (review by Codex, round 3). For XML-style
    wrappers the residue after removing every complete element must be empty;
    plain-text prefixes ("caveat:", "[system notification") cannot be stripped
    and keep the prefix-only rule of the shared helper.
    """
    head = text.lstrip("\ufeff \t\r\n").lower()
    if not head.startswith(SERVICE_PREFIXES):
        return False
    if not head.startswith("<"):
        return True
    return not WRAPPER_RE.sub("", text).strip("\ufeff \t\r\n")


def _is_harness_message(row):
    """Assistant-typed record the harness wrote, not the model (rate-limit notice)."""
    message = row.get("message")
    model = message.get("model") if isinstance(message, dict) else None
    return bool(row.get("isApiErrorMessage")) or model == "<synthetic>"


def opener_kind(row):
    """'human' | 'service' | 'unknown' for a record that carries text, else None."""
    queued = _queued_prompt(row)
    if queued is not None:
        if not queued.strip():
            return None
        return "service" if _is_service_text(queued) else "human"
    if _a12._role(row) != "user":
        return None
    texts = [t for t in _a12._text_blocks(row) if t.strip()]
    if not texts:
        return None
    if all(_is_service_text(t) for t in texts):
        return "service"
    if row.get("isMeta"):
        return "unknown"
    if _a12._human_text(row) is not None or any(
        t.lstrip().lower().startswith(SERVICE_PREFIXES) for t in texts
    ):
        return "human"
    return "unknown"


def episodes(rows):
    """List of {index, row, opener, items}; items are ('a', texts, tool_use) / ('t',)."""
    eps = []
    for i, row in enumerate(rows):
        try:
            _add_row(eps, i, row)
        except (AttributeError, TypeError):
            continue  # valid JSON of the wrong shape: drop that record, keep reading
    return eps


def _add_row(eps, i, row):
    kind = opener_kind(row)
    if kind is not None:
        eps.append({"index": len(eps), "row": i, "opener": kind, "items": []})
        return
    if not eps:
        return
    role = _a12._role(row)
    if role == "user" and _has_tool_result(row):
        eps[-1]["items"].append(("t",))
    elif role == "assistant" and not _is_harness_message(row):
        eps[-1]["items"].append(("a", _a12._text_blocks(row), _has_tool_use(row)))


def final_reply(ep):
    """Final reply text of an episode, or None when absent/unfinished."""
    items = ep["items"]
    start = max((n for n, it in enumerate(items) if it[0] == "t"), default=-1) + 1
    tail = items[start:]
    # A tool call after the last result has no result yet: the episode is unfinished.
    if not tail or any(it[2] for it in tail):
        return None
    texts = [t for it in tail for t in it[1] if isinstance(t, str) and t.strip()]
    return "\n".join(texts).strip() or None


def tokens(text, mask=False):
    out = []
    for w in WORD_RE.findall(text.lower()):
        if mask and (any(c.isdigit() for c in w) or HASHLIKE_RE.match(w)):
            w = "<n>"
        out.append(w)
    return out


def trigram_positions(toks):
    return max(len(toks) - 2, 0)


def jaccard(a_toks, b_toks):
    """Jaccard of word 3-gram sets; None when either side is too short."""
    if min(trigram_positions(a_toks), trigram_positions(b_toks)) < MIN_TRIGRAM_POSITIONS:
        return None
    a = {tuple(a_toks[i:i + 3]) for i in range(len(a_toks) - 2)}
    b = {tuple(b_toks[i:i + 3]) for i in range(len(b_toks) - 2)}
    return len(a & b) / len(a | b)


def split_next(text):
    """(text before the first "Дальше:" line, that line's paragraph); the second may be empty.

    The paragraph runs to the first blank line, so a long appendix after it
    cannot hide or fake a repeat of the line itself (review by Codex, round 3).
    """
    m = NEXT_LINE_RE.search(text)
    if not m:
        return text, ""
    end = BLANK_LINE_RE.search(text, m.end())
    return text[:m.start()], text[m.start():end.start() if end else len(text)]


def _round(x):
    return None if x is None else round(x, 3)


def _digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]


def compare(prev_ep, cur_ep):
    """Diagnostic record for a pair of adjacent episodes; `fires` is the signal."""
    rec = {"prev_episode": prev_ep["index"], "cur_episode": cur_ep["index"],
           "prev_row": prev_ep["row"], "cur_row": cur_ep["row"],
           "opener": cur_ep["opener"], "threshold": threshold(),
           "next_threshold": next_threshold(), "part": None,
           "score": None, "masked_score": None, "pre_score": None, "next_score": None,
           "words": None, "trigrams": None, "hashes": None, "skip": None, "fires": False}
    if cur_ep["opener"] != "service":
        rec["skip"] = "opener_" + cur_ep["opener"]
        return rec
    prev_text, cur_text = final_reply(prev_ep), final_reply(cur_ep)
    if prev_text is None or cur_text is None:
        rec["skip"] = "no_final_reply_" + ("prev" if prev_text is None else "cur")
        return rec
    pt, ct = tokens(prev_text), tokens(cur_text)
    rec["words"] = [len(pt), len(ct)]
    rec["trigrams"] = [trigram_positions(pt), trigram_positions(ct)]
    rec["hashes"] = [_digest(prev_text), _digest(cur_text)]
    score = jaccard(pt, ct)
    if score is None:
        rec["skip"] = "too_short"
        return rec
    (p_pre, p_next), (c_pre, c_next) = split_next(prev_text), split_next(cur_text)
    next_score = jaccard(tokens(p_next), tokens(c_next))
    # The decision uses the raw scores; rounding is for the journal only.
    rec["score"], rec["next_score"] = _round(score), _round(next_score)
    rec["masked_score"] = _round(jaccard(tokens(prev_text, True), tokens(cur_text, True)))
    rec["pre_score"] = _round(jaccard(tokens(p_pre), tokens(c_pre)))
    body_hit = score >= rec["threshold"]
    next_hit = next_score is not None and next_score >= rec["next_threshold"]
    rec["part"] = "body+next" if body_hit and next_hit else "body" if body_hit else "next" if next_hit else None
    rec["fires"] = rec["part"] is not None
    return rec


def pairs(rows):
    eps = episodes(rows)
    return [compare(eps[n - 1], eps[n]) for n in range(1, len(eps))]


def detect(path):
    """Record for the last pair, or None when peer context / fewer than two episodes."""
    # A peer's turn is addressed to the writer; rule 6 covers pilot replies only
    # (same switch as a12-next-block.py).
    if os.environ.get("STYLE_CONTEXT") == "peer":
        return None
    found = pairs(list(_a12._rows(path)))
    return found[-1] if found else None


def summary_line(rec):
    return ("score={score} masked={masked_score} pre={pre_score} next={next_score} "
            "part={part} thr={threshold}/{next_threshold} words={w} opener={opener} episodes={prev_episode}->{cur_episode} "
            "rows={prev_row}->{cur_row} hash={h}").format(
        w="/".join(map(str, rec["words"])), h="/".join(rec["hashes"]), **rec)


if __name__ == "__main__":
    args = sys.argv[1:]
    try:
        if args[:1] == ["--scan"] and len(args) > 1:
            for p in args[1:]:
                for rec in pairs(list(_a12._rows(p))):
                    if rec["opener"] == "service":
                        print(json.dumps({"file": os.path.basename(p), **rec}, ensure_ascii=False))
        elif args[:1] == ["--explain"] and len(args) == 2:
            print(json.dumps(detect(args[1]), ensure_ascii=False))
        elif len(args) == 1 and not args[0].startswith("--"):
            result = detect(args[0])
            if result and result["fires"]:
                print(summary_line(result))
        else:
            sys.exit(__doc__.strip().splitlines()[-4])
    except Exception as exc:  # a Stop hook must never break the turn
        if os.environ.get("IWE_A12_REPEAT_DEBUG"):
            raise
        print(f"a12-cross-turn-repeat: {exc}", file=sys.stderr)
