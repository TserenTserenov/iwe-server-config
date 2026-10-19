#!/usr/bin/env python3
"""WP-603: render a final «Дальше» line from reviewed, source-pinned evidence.

The caller must buffer the candidate answer before showing it. This command
does not intercept an interactive UI. The state input is supplied by the
orchestrator, not extracted from the agent's own prose.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from promise_audit import apply_reviews, audit
from turn_evidence import load_turns


def _description(value: object) -> str:
    if not isinstance(value, str):
        raise TypeError("external dependency description required")
    cleaned = " ".join(value.split())
    if not cleaned or len(cleaned) > 160 or re.search(r"[\x00-\x1f\x7f]", cleaned):
        raise ValueError("invalid external dependency description")
    return cleaned


def claude_background_state(identifier: str) -> str:
    """Query Claude's session supervisor, not a Bash child task handle."""
    result = subprocess.run(
        ["claude", "agents", "--json", "--all"],
        capture_output=True,
        text=True,
        timeout=15,
        check=True,
    )
    sessions = json.loads(result.stdout)
    if not isinstance(sessions, list):
        raise TypeError("invalid Claude agent inventory")
    matches = [
        row
        for row in sessions
        if isinstance(row, dict)
        and row.get("id") == identifier
        and row.get("kind") == "background"
    ]
    if len(matches) != 1:
        return "unknown"
    row = matches[0]
    return (
        "working"
        if row.get("state") == "working" and row.get("status") == "busy"
        else "not_working"
    )


def generate_next_block(
    bundle: dict, reviews: dict, state: dict, background_state=claude_background_state
) -> str:
    """Return one truthful status line or refuse to manufacture one.

    ``state`` is an orchestrator-owned assessment of the whole user request.
    The source-pinned review binds semantic target selection to journal facts;
    it cannot establish the scope of the user's request on its own.
    """
    if not isinstance(state, dict):
        raise TypeError("orchestrator state required")
    actions = state.get("available_actions")
    if not isinstance(actions, list) or any(
        not isinstance(a, str) or not a for a in actions
    ):
        raise ValueError("available_actions must be an explicit list")
    if actions:
        raise ValueError("perform available actions before final response")
    if state.get("scope") not in {"complete", "open"}:
        raise ValueError("scope must be complete or open")
    open_conditions = state.get("open_conditions")
    if not isinstance(open_conditions, list) or any(
        not isinstance(condition, str) or not condition for condition in open_conditions
    ):
        raise ValueError("open_conditions must be an explicit list")
    identifier = state.get("turn_id")
    if not isinstance(identifier, str) or not identifier:
        raise ValueError("turn_id required")

    report = audit(bundle)
    apply_reviews(report, bundle, reviews)
    matching = [row for row in report["turns"] if row["turn_id"] == identifier]
    if len(matching) != 1 or "semantic_review" not in matching[0]:
        raise ValueError("turn lacks source-pinned semantic review")
    verdict = matching[0]["semantic_review"]["classification"]
    decisions = [d for d in reviews["decisions"] if str(d.get("turn_id")) == identifier]
    if len(decisions) != 1:
        raise ValueError("review decision missing")
    decision = decisions[0]

    if verdict in {"completed", "text_only"}:
        if state["scope"] != "complete" or open_conditions:
            raise ValueError("whole request is not proven complete")
        return "Дальше: ничего не жду — объём завершён, доступных действий не осталось."

    if state["scope"] != "open":
        raise ValueError("unfinished outcome conflicts with complete scope")
    if not open_conditions:
        raise ValueError("open request requires pending conditions")
    if verdict == "background":
        bindings = decision.get("bindings", [])
        if len(bindings) != 1:
            raise ValueError("one background binding required")
        background_id = str(bindings[0]["background_id"])
        if not re.fullmatch(r"[a-f0-9]{8}", background_id):
            raise ValueError("Claude background session ID required")
        turn = next(t for t in bundle["turns"] if str(t["id"]) == identifier)
        call = next(t for t in turn["tools"] if t["id"] == bindings[0]["tool_id"])
        arguments = call["arguments"]
        if not isinstance(arguments, dict):
            raise ValueError("background command arguments unavailable")
        command = arguments.get("cmd", arguments.get("command", ""))
        if not isinstance(command, str) or not re.match(
            r"^claude\s+--bg(?:\s|$)", command
        ):
            raise ValueError("only supervised Claude --bg sessions are supported")
        if background_state(background_id) != "working":
            raise ValueError("background session not confirmed working")
        return f"Дальше: фоновая задача запущена, ID `{background_id}`; результат ещё не получен."

    if verdict in {"waiting", "blocked"}:
        dependency = state.get("external_dependency")
        if not isinstance(dependency, dict) or dependency.get("kind") not in {
            "decision",
            "fact",
            "permission",
        }:
            raise ValueError("concrete external dependency required")
        detail = _description(dependency.get("description"))
        if verdict == "waiting":
            return f"Дальше: жду {detail}; поручение остаётся открытым."
        return f"Дальше: блокер — {detail}; поручение остаётся открытым."

    raise ValueError("review does not authorize a final next block")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", type=Path)
    parser.add_argument("--runtime", required=True, choices=("codex", "claude", "kimi"))
    parser.add_argument("--reviews", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    try:
        bundle = load_turns(args.journal, args.runtime)
        reviews = json.loads(args.reviews.read_text(encoding="utf-8"))
        state = json.loads(args.state.read_text(encoding="utf-8"))
        print(generate_next_block(bundle, reviews, state))
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
    ) as error:
        print(
            f"next block unavailable: {type(error).__name__}: {error}", file=sys.stderr
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
