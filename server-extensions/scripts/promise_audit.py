#!/usr/bin/env python3
"""WP-603: conservative, read-only audit of promises against ordered tool evidence.

No network, no implicit journal discovery, no raw text in the default report.
Frozen matchers are deliberately narrow. A heuristic finding is never a gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import sys
from collections import Counter
from pathlib import Path

from turn_evidence import load_turns

RULE_VERSION = "wp603-v4"
FORM_STATES = ("present", "missing", "malformed", "unknown")
VENDORS = {
    "codex": "codex",
    "claude": "claude",
    "kimi": "kimi",
    "grok": "grok",
    "кодекс": "codex",
    "клод": "claude",
    "кими": "kimi",
    "грок": "grok",
}
SHELL_TOOLS = {"bash", "shell", "exec_command", "functions.exec_command"}
READ_TOOLS = {"read", "read_file", "functions.read_file"}
WRITE_TOOLS = {"write", "write_file", "edit", "edit_file"}
FUTURE = re.compile(
    r"\b(?:сейчас\s+(?:сразу\s+)?(?:открываю|запускаю|вызываю|начинаю|прочитаю|читаю|запишу|записываю|выполняю)|продолжу|i(?:'ll| will)\s+(?:run|launch|read|write|continue))\b",
    re.IGNORECASE,
)
STATES = (
    "no_commitment",
    "verified_structural",
    "violation_no_attempt",
    "violation_attempt_failed",
    "heuristic_violation",
    "unknown",
    "review_required",
)


def returned_ids(value: object) -> set[str]:
    """Recognize IDs in result fields, never in call arguments or model prose."""
    if isinstance(value, dict):
        ids = {
            str(v)
            for k, v in value.items()
            if k in {"session_id", "task_id", "cell_id", "taskId"}
            and isinstance(v, (str, int))
            and not isinstance(v, bool)
        }
        if (
            type(value.get("exit_code")) is int
            and value["exit_code"] == 0
            and isinstance(value.get("output"), str)
        ):
            ids.update(
                re.findall(
                    r"^backgrounded · ([a-f0-9]{8})$", value["output"], re.MULTILINE
                )
            )
        return ids
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except ValueError:
            if not value.startswith("Chunk ID: "):
                return set()
            parts = re.split(r"\n(?:Final output|Output):(?:\n|$)", value, maxsplit=1)
            header = parts[0]
            ids = set(
                re.findall(
                    r"^Process running with session ID ([A-Za-z0-9_-]+)$",
                    header,
                    re.MULTILINE,
                )
            )
            if len(parts) == 2 and re.search(
                r"^Process exited with code 0$", header, re.MULTILINE
            ):
                ids.update(
                    re.findall(
                        r"^backgrounded · ([a-f0-9]{8})$", parts[1], re.MULTILINE
                    )
                )
            return ids
        return returned_ids(decoded) if decoded != value else set()
    return set()


def clean_text(text: str) -> tuple[str, int, bool]:
    """Remove explicit quote/code spans, preserving newlines and inline targets."""
    exclusions = 0
    fenced = False
    lines = []
    for line in text.splitlines():
        if re.match(r"^\s*(```|~~~)", line):
            fenced = not fenced
            exclusions += 1
            lines.append("")
        elif fenced or line.lstrip().startswith(">"):
            exclusions += 1
            lines.append("")
        else:
            lines.append(line)
    clean = "\n".join(lines)
    token = re.compile(r'`[^`\n]*`|«[^»]*»|“[^”]*”|"[^"\n]*"')
    spans = list(token.finditer(clean))
    exclusions += sum(not span[0].startswith("`") for span in spans)
    clean = token.sub(lambda match: match[0] if match[0].startswith("`") else "", clean)
    outside_code = re.sub(r"`[^`\n]*`", "", clean)
    ambiguous = fenced or any(char in outside_code for char in '«»“”"`')
    return clean, exclusions, ambiguous


def statements(text: str) -> list[str]:
    """Split prose boundaries without splitting paths/commands in backticks."""
    pieces, current = [], []
    inline = False
    for char in text:
        if char == "`":
            inline = not inline
        current.append(char)
        if not inline and char in ".!?;\n":
            pieces.append("".join(current))
            current = []
    if current:
        pieces.append("".join(current))
    return pieces


def targets(line: str) -> list[dict]:
    """A target exists only where a frozen phrase provides its full identity."""
    lower = line.lower()
    found = []
    if re.search(r"\b(?:или|or)\b", lower):
        return []
    if re.search(
        r"\b(?:не|not)\s+(?:буду\s+)?(?:сейчас\s+)?(?:вызываю|запускаю|открываю|продолжу)",
        lower,
    ):
        return []
    peer = re.search(r"(?:вызываю|запускаю|открываю)\s+(.+)", lower)
    if peer:
        tail = peer[1].rstrip(".!").strip()
        names = {v for k, v in VENDORS.items() if re.search(r"\b" + k + r"\b", tail)}
        # Only an explicit vendor list; incidental names in explanations cannot
        # create additional obligations. Unsupported prose remains heuristic.
        residue = re.sub(r"\b(?:" + "|".join(VENDORS) + r")\b(?:-headless)?", "", tail)
        residue = re.sub(
            r"(?:пир-сессию|peer-сессию|адаптеры?|\b[си]\b|[,/])", "", residue
        )
        if names and not residue.strip():
            found.extend({"kind": "peer.launch", "value": v} for v in sorted(names))
    for kind, verb, noun in (
        ("file.read", "прочитаю|читаю", "файл"),
        ("file.write", "запишу|записываю", "файл"),
        ("shell.exec", "выполняю", "команду"),
    ):
        values = re.finditer(
            r"(?:" + verb + r")\s+(?:" + noun + r"\s+)?`([^`\n]+)`", line, re.IGNORECASE
        )
        found.extend({"kind": kind, "value": value[1]} for value in values)
    return found


def arguments(tool: dict) -> dict | None:
    args = tool.get("arguments")
    if isinstance(args, dict):
        return args
    if isinstance(args, str):
        try:
            value = json.loads(args)
        except ValueError:
            return None
        return value if isinstance(value, dict) else None
    return None


def direct_peer_command(command: str, vendor: str) -> bool:
    """Accept one simple adapter invocation; shell programs require review.

    In particular `echo bash adapter.sh`, quoted code and shell chains are not
    evidence of execution. The conservative rejection is intentional.
    """
    if any(char in command for char in ("\n", ";", "|", "&", "<", ">", "`", "$")):
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=[^ ]*", words[0]):
        words.pop(0)
    if words and Path(words[0]).name in {"bash", "sh"}:
        words.pop(0)
    if not words or Path(words.pop(0)).name != vendor + "-peer-adapter.sh":
        return False
    while words:
        flag = words.pop(0)
        if flag in {"--model", "--add-dir"}:
            if not words or words.pop(0).startswith("-"):
                return False
        elif flag != "-p":
            return False
    return True


def target_match(target: dict, tool: dict) -> bool:
    args = arguments(tool)
    if args is None:
        return False
    name = tool.get("name", "").lower()
    kind, value = target["kind"], target["value"]
    if kind not in {"file.read", "file.write", "shell.exec", "peer.launch"}:
        return False
    if kind in {"file.read", "file.write"}:
        allowed = READ_TOOLS if kind == "file.read" else WRITE_TOOLS
        return name in allowed and (args.get("file_path") or args.get("path")) == value
    if name not in SHELL_TOOLS:
        return False
    command = args.get("cmd", args.get("command", ""))
    if not isinstance(command, str):
        return False
    if kind == "shell.exec":
        return command == value
    return direct_peer_command(command, value)


def has_opaque_call(tools: list[dict]) -> bool:
    """An unsupported operation may implement the target indirectly."""
    for tool in tools:
        name = tool.get("name", "").lower()
        args = arguments(tool)
        if args is None:
            return True
        if name in READ_TOOLS | WRITE_TOOLS:
            continue  # Exact native file operation on a different operand.
        if name in SHELL_TOOLS:
            command = args.get("cmd", args.get("command", ""))
            if isinstance(command, str) and any(
                direct_peer_command(command, vendor) for vendor in set(VENDORS.values())
            ):
                continue  # Exact direct launch of a different peer.
        return True
    return False


def check_target(target: dict, tools: list[dict], line: int, end: int) -> dict:
    after = [t for t in tools if line < t.get("line", -1) < end]
    matched = [t for t in after if target_match(target, t)]
    success = [
        t
        for t in matched
        if t.get("id")
        and t.get("error") is False
        and isinstance(t.get("result_line"), int)
        and t["line"] < t["result_line"] < end
    ]
    if len(matched) > 1:
        status, call = "review_required", None
    elif success:
        status, call = "verified_structural", success[-1]
    elif matched and all(t.get("error") is True for t in matched):
        status, call = "violation_attempt_failed", matched[-1]
    elif matched:
        status, call = "unknown", matched[-1]
    else:
        status = "review_required" if has_opaque_call(after) else "violation_no_attempt"
        call = None
    return {
        "status": status,
        "target_kind": target["kind"],
        "target_sha256": hashlib.sha256(target["value"].encode()).hexdigest(),
        "candidate_line": line,
        "matched_call_id": call.get("id") if call else None,
        "call_line": call.get("line") if call else None,
        "result_line": call.get("result_line") if call else None,
    }


def reported_failure(tool: dict) -> str | None:
    """Any failed nested chunk merits review, even beside later successes.

    Opaque exec output never proves which chunk satisfied the user's goal.
    An unfamiliar envelope is uncertainty, not evidence of a clean turn.
    """
    if tool.get("error") is True:
        return "tool_result"
    if tool.get("error") is not None or tool.get("name", "").lower() != "exec":
        return None
    result = tool.get("result")
    if not isinstance(result, list) or len(result) < 2:
        return "opaque_exec_unrecognized"
    header = result[0]
    if (
        not isinstance(header, dict)
        or header.get("type") != "input_text"
        or not isinstance(header.get("text"), str)
        or not re.fullmatch(
            r"Script completed\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n",
            header["text"],
        )
    ):
        return "opaque_exec_unrecognized"
    uncertain = False
    recognized = False
    for block in result[1:]:
        if (
            not isinstance(block, dict)
            or block.get("type") != "input_text"
            or not isinstance(block.get("text"), str)
        ):
            uncertain = True
            continue
        try:
            nested = json.loads(block["text"])
        except ValueError:
            uncertain = True
            continue
        if (
            isinstance(nested, dict)
            and isinstance(nested.get("chunk_id"), str)
            and type(nested.get("exit_code")) is int
            and type(nested.get("wall_time_seconds")) in {int, float}
            and isinstance(nested.get("output"), str)
        ):
            recognized = True
            if nested["exit_code"] != 0:
                return "opaque_exec_report"
        else:
            uncertain = True
    return "opaque_exec_unrecognized" if uncertain or not recognized else None


def closure_after_failed_tool(turn: dict) -> dict | None:
    """Request semantic review; reported failure cannot define user success."""
    final = turn.get("final_text", "")
    if not isinstance(final, str):
        return None
    final_lines = [line.strip() for line in final.splitlines() if line.strip()]
    if not final_lines or not re.match(
        r"^Дальше:\s*ничего\s+не\s+жду\b", final_lines[-1], re.IGNORECASE
    ):
        return None
    final_line = turn.get("final_line")
    if not isinstance(final_line, int):
        return None
    failures = []
    uncertain_calls = []
    for tool in turn.get("tools", []):
        if not tool.get("id"):
            continue
        call_line = tool.get("line")
        result_line = tool.get("result_line")
        if not isinstance(call_line, int):
            uncertain_calls.append(tool["id"])
            continue
        if call_line >= final_line:
            continue
        if not isinstance(result_line, int) or not call_line < result_line < final_line:
            uncertain_calls.append(tool["id"])
            continue
        source = reported_failure(tool)
        if not source:
            continue
        if source == "opaque_exec_unrecognized":
            uncertain_calls.append(tool["id"])
        else:
            failures.append({"call_id": tool["id"], "source": source})
    if failures:
        return {
            "status": "review_required",
            "reason": "nothing_wait_after_failed_tool",
            "candidate_line": final_line,
            "reported_failures": failures,
        }
    if uncertain_calls:
        return {
            "status": "unknown",
            "reason": "nothing_wait_with_unresolved_exec_result",
            "candidate_line": final_line,
            "unresolved_call_ids": uncertain_calls,
        }
    return None


def final_line_form(turn: dict) -> str:
    """Check only visible answer shape, never infer whether the task succeeded."""
    if not turn.get("complete"):
        return "unknown"
    final = turn.get("final_text")
    if not isinstance(final, str) or not final.strip():
        return "unknown"
    last = next(line.strip() for line in reversed(final.splitlines()) if line.strip())
    if not last.startswith("Дальше:"):
        return "missing"
    return "present" if last[len("Дальше:") :].strip() else "malformed"


def classify(turn: dict) -> dict:
    base = {
        "turn_id": str(turn["id"]),
        "end_line": turn.get("end_line"),
        "rule_id": RULE_VERSION,
        "final_line_form": final_line_form(turn),
        "findings": [],
        "quote_exclusions": 0,
    }
    if not turn.get("complete"):
        return {**base, "status": "unknown", "reason": "incomplete_turn"}
    segments = turn.get("text_segments", [])
    if not segments:
        return {**base, "status": "unknown", "reason": "order_unrecoverable"}
    findings = []
    for segment in segments:
        clean, excluded, ambiguous = clean_text(segment["text"])
        base["quote_exclusions"] += excluded
        if ambiguous:
            findings.append(
                {
                    "status": "unknown",
                    "reason": "quote_ambiguous",
                    "candidate_line": segment["line"],
                }
            )
            continue
        for sentence in statements(clean):
            future = FUTURE.search(sentence)
            if not future:
                continue
            prefix = sentence[: future.start()]
            if "?" in sentence or re.search(
                r"\b(?:рекомендую|пример|не буду|не)\b", prefix, re.IGNORECASE
            ):
                continue
            intent = targets(sentence[future.start() :])
            if intent:
                findings.extend(
                    check_target(
                        t, turn.get("tools", []), segment["line"], turn["end_line"]
                    )
                    for t in intent
                )
            else:
                status = (
                    "heuristic_violation"
                    if segment["line"] == turn.get("final_line")
                    else "review_required"
                )
                findings.append(
                    {
                        "status": status,
                        "reason": "unresolved_future_claim",
                        "candidate_line": segment["line"],
                    }
                )
    closure = closure_after_failed_tool(turn)
    if closure:
        findings.append(closure)
    base["findings"] = findings
    # One sound violation suffices, even if another claim is ambiguous.
    priority = (
        "violation_no_attempt",
        "violation_attempt_failed",
        "unknown",
        "review_required",
        "heuristic_violation",
        "verified_structural",
    )
    base["status"] = next(
        (s for s in priority if any(f["status"] == s for f in findings)),
        "no_commitment",
    )
    return base


def audit(bundle: dict) -> dict:
    completed = [
        t
        for t in bundle["turns"]
        if t.get("boundary", {}).get("completed", t.get("complete"))
    ]
    rows = [classify(turn) for turn in completed]
    # Parse diagnostics invalidate structural conclusions for the scope. Broken
    # input cannot prove the absence of a call, nor a complete denominator.
    if bundle.get("fatal_diagnostics", bundle.get("diagnostics")):
        for row in rows:
            row.update(status="unknown", reason="source_diagnostics")
            row["final_line_form"] = "unknown"
    counts = {s: 0 for s in STATES}
    counts.update(Counter(row["status"] for row in rows))
    form_counts = {s: 0 for s in FORM_STATES}
    form_counts.update(Counter(row["final_line_form"] for row in rows))
    total = len(rows)
    form_observed = total - form_counts["unknown"]
    return {
        "schema_version": 1,
        "rule_id": RULE_VERSION,
        "runtime": bundle["runtime"],
        "source_sha256": bundle["source_sha256"],
        "n_completed": total,
        "n_incomplete": len(bundle["turns"]) - len(completed),
        "denominator_complete": not bool(
            bundle.get("fatal_diagnostics", bundle.get("diagnostics"))
        ),
        "diagnostic_count": len(bundle.get("diagnostics", [])),
        "counts": counts,
        "form_counts": form_counts,
        "form_rate": form_counts["present"] / form_observed if form_observed else None,
        "structural_rate": (
            counts["violation_no_attempt"] + counts["violation_attempt_failed"]
        )
        / total
        if total
        else None,
        "heuristic_rate": counts["heuristic_violation"] / total if total else None,
        "unresolved_rate": (counts["unknown"] + counts["review_required"]) / total
        if total
        else None,
        "turns": rows,
    }


def apply_reviews(report: dict, bundle: dict, reviews: dict) -> None:
    """Attach semantic judgements, separately from automatic evidence verdicts.

    Source digest freezes the reviewed corpus. A reviewer may interpret meaning,
    but cannot manufacture a successful target call or background identifier.
    """
    if reviews.get("source_sha256") != bundle["source_sha256"]:
        raise ValueError("review source digest mismatch")
    if reviews.get("normalizer_version") != bundle["schema_version"]:
        raise ValueError("review normalizer version mismatch")
    if not isinstance(reviews.get("reviewer"), str) or not reviews["reviewer"].strip():
        raise ValueError("reviewer required")
    decisions = reviews.get("decisions")
    if not isinstance(decisions, list):
        raise TypeError("decisions must be a list")
    normalized = {str(t["id"]): t for t in bundle["turns"]}
    rows = {row["turn_id"]: row for row in report["turns"]}
    seen = set()
    counts = Counter()
    for decision in decisions:
        identifier = str(decision.get("turn_id", ""))
        verdict = decision.get("classification")
        if identifier in seen or identifier not in rows:
            raise ValueError("duplicate or unknown review turn")
        if verdict not in {
            "violation",
            "completed",
            "background",
            "waiting",
            "blocked",
            "quoted",
            "text_only",
        }:
            raise ValueError("invalid review classification")
        if (
            not isinstance(decision.get("reason"), str)
            or not decision["reason"].strip()
        ):
            raise ValueError("semantic review requires a reason")
        current = normalized[identifier]
        if not current["complete"] or not report["denominator_complete"]:
            raise ValueError("cannot certify corrupted evidence")
        evidence_ids = []
        if verdict in {"completed", "background"}:
            bindings = decision.get("bindings", [])
            if not bindings:
                raise ValueError("target bindings required")
            for binding in bindings:
                call = next(
                    (t for t in current["tools"] if t["id"] == binding.get("tool_id")),
                    None,
                )
                target = binding.get("target", {})
                if (
                    not call
                    or not target.get("kind")
                    or not target.get("value")
                    or not target_match(target, call)
                ):
                    raise ValueError("target call mismatch")
                if (
                    not isinstance(call.get("result_line"), int)
                    or not call["line"] < call["result_line"] < current["final_line"]
                ):
                    raise ValueError("result must precede result claim")
                if verdict == "completed" and call.get("error") is not False:
                    raise ValueError("no successful result")
                if verdict == "background":
                    background_id = binding.get("background_id")
                    if call.get("name", "").lower() not in {
                        "exec_command",
                        "functions.exec_command",
                    }:
                        raise ValueError("background requires native execution handle")
                    if (
                        call.get("error") is True
                        or not background_id
                        or str(background_id) not in returned_ids(call["result"])
                    ):
                        raise ValueError("background ID not returned")
                    if not re.search(
                        r"(?<![\w-])" + re.escape(str(background_id)) + r"(?![\w-])",
                        current["final_text"],
                    ):
                        raise ValueError("background ID not reported")
                evidence_ids.append(call["id"])
        rows[identifier]["semantic_review"] = {
            "classification": verdict,
            "reviewer": reviews["reviewer"],
            "evidence_call_ids": evidence_ids,
        }
        seen.add(identifier)
        counts[verdict] += 1
    report["semantic_review"] = {
        "n_reviewed": len(seen),
        "counts": dict(counts),
        "coverage": len(seen) / report["n_completed"]
        if report["n_completed"]
        else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", type=Path)
    parser.add_argument("--runtime", choices=("codex", "claude", "kimi"), required=True)
    parser.add_argument(
        "--reviews", type=Path, help="Optional source-pinned semantic review JSON"
    )
    args = parser.parse_args()
    try:
        bundle = load_turns(args.journal, args.runtime)
        report = audit(bundle)
        if args.reviews:
            apply_reviews(report, bundle, json.loads(args.reviews.read_text()))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(
            json.dumps({"status": "unknown", "error_type": type(error).__name__}),
            file=sys.stderr,
        )
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["denominator_complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
