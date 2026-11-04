#!/usr/bin/env python3
"""Record the pilot's answer to one daily summary in the plan (WP-561 Ф55).

Contract v3 (DR-06, 04.11): a reservation is written off by the pilot's answer
to the daily summary, as confirmed_minutes plus confirmation_ref (the summary
id). An estimate the pilot confirmed is not a measurement, so it never lands in
actual_minutes. Silence is not an answer: rows the pilot did not answer stay
open.

Two steps, so each runs where it can:
  build  checks the summary id the pilot answered against the plan at the
         summary's commit, then reads the current plan (bridge modules,
         rfc8785, PyYAML): a row may have been closed since the summary was
         shown. It prints one outcome_confirmed per answered open row as JSON,
         only for reservations held by --holder: a reservation is closed
         through the channel that submitted it;
  send   (standard library only) submits those requests to the receiver of the
         host that holds the reservations, learning the queue tip as
         plan-session-reserve.py does.

    build --holder tsekh-agent-channel ... | ssh tsekh-1 python3 .../plan-summary-answer.py send
    build --holder mac-agent-channel ...   | ssh <Mac channel key> answer

Exit codes: 0 done, 1 refused (summary changed, row not answerable, receiver
refusal), 2 unusable input or receiver not reached, 3 no receiver on this host.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

SCRIPT = Path(__file__).resolve()
_ROW = re.compile(r"([0-9]+)=([0-9]+)")


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPT.parent / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reserve = _load("plan_session_reserve", "plan-session-reserve.py")
send = reserve.send


class AnswerError(Exception):
    """The answer cannot be recorded as given (exit code 1)."""


def answered_minutes(rows, *, confirm_all, corrections):
    """Row number -> minutes the pilot gave; unanswered rows are not included."""
    answers = {}
    if confirm_all:
        answers = {number: row.reserved_minutes for number, row in enumerate(rows, 1)}
    for number, minutes in corrections.items():
        if not 1 <= number <= len(rows):
            raise AnswerError(f"the summary has no row {number}")
        if not 0 <= minutes <= 1440:
            raise AnswerError(f"row {number}: minutes must be 0..1440")
        answers[number] = minutes
    if not answers:
        raise AnswerError("no row answered: pass --all or --row N=MINUTES")
    return answers


def _reservation(view, resource):
    for request in view.accepted.values():
        if (
            request["event_type"] == "allocation_confirmed"
            and request["payload"].get("resource_id") == resource
        ):
            return request
    raise AnswerError(f"no accepted reservation for {resource}")


def outcome_requests(summary, current, view, answers, holder=None):
    """outcome_confirmed fields per answered row; rows already recorded are skipped.

    summary: the one the pilot answered (row numbers); current and view: the
    plan now, where each row's state and element tip are taken from. With a
    holder, rows of reservations held by another channel are listed apart.
    """
    import plan_bridge_allocation as allocation

    now = {(row.stream_id, row.element_id): row for row in current.rows}
    requests, recorded, other_holder = [], [], []
    for number, minutes in sorted(answers.items()):
        row = now[
            (summary.rows[number - 1].stream_id, summary.rows[number - 1].element_id)
        ]
        if row.state == "completed":
            if (row.spent_minutes, row.confirmation_ref) != (
                minutes,
                summary.summary_id,
            ):
                raise AnswerError(f"row {number} is already closed with another answer")
            recorded.append(number)
            continue
        if row.state not in {"reserved", "awaiting"} or not row.started:
            raise AnswerError(f"row {number} is not a started open reservation")
        resource = allocation.personal_time_resource_id(
            summary.plan_date, row.stream_id, row.element_id
        )
        reserved = _reservation(view, resource)
        if holder is not None and reserved["producer_id"] != holder:
            other_holder.append(number)
            continue
        requests.append(
            {
                "event_type": "outcome_confirmed",
                "stream_id": row.stream_id,
                "element_id": row.element_id,
                "expected_parent": view.tips[(row.stream_id, row.element_id)],
                "basis": {
                    "reason_code": "pilot_answer",
                    "text": f"daily summary {summary.summary_id}",
                },
                "payload": {
                    "resource_id": resource,
                    "resource_type": "personal_time",
                    "generation_claimed": reserved["payload"]["generation_claimed"],
                    "plan_date": summary.plan_date,
                    "confirmed_minutes": minutes,
                    "confirmation_ref": summary.summary_id,
                },
            }
        )
    return requests, recorded, other_holder


def build(arguments):
    sys.path.insert(0, str(SCRIPT.parent / "lib"))
    import plan_daily_summary as daily
    import plan_event_bridge as bridge

    reader = bridge.GitPlanReader(Path(arguments.repository))

    def resolve(name):
        resolved = reader._git("rev-parse", "--verify", name + "^{commit}")
        if resolved.returncode:
            raise AnswerError(f"commit {name} is not in {arguments.repository}")
        return resolved.stdout.decode().strip()

    commit, latest = resolve(arguments.commit), resolve(arguments.current)
    trust = dict(trust_intra_commit_order=arguments.trust_intra_commit_order)
    summary = daily.summarize_repository(
        arguments.repository, commit, arguments.date, **trust
    )
    if summary.summary_id != arguments.summary_id:
        raise AnswerError(
            f"summary {arguments.summary_id} is not the one built at {commit[:10]}"
        )
    current = daily.summarize_repository(
        arguments.repository, latest, arguments.date, **trust
    )
    view, _ = daily.published_view(arguments.repository, latest, **trust)
    corrections = {}
    for item in arguments.row:
        match = _ROW.fullmatch(item)
        if match is None:
            raise AnswerError(f"--row {item!r}: expected N=MINUTES")
        corrections[int(match[1])] = int(match[2])
    answers = answered_minutes(
        summary.rows, confirm_all=arguments.all, corrections=corrections
    )
    requests, recorded, other = outcome_requests(
        summary, current, view, answers, holder=arguments.holder
    )
    print(
        json.dumps(
            {"requests": requests, "already_recorded": recorded, "other_holder": other}
        )
    )
    return 0


def send_all(arguments):
    if not os.path.exists(arguments.socket):
        print(json.dumps({"ok": False, "code": "NoReceiver", "submitted": False}))
        return 3
    try:
        batch = json.load(sys.stdin)
        if not isinstance(batch, dict) or not isinstance(batch.get("requests"), list):
            raise send.SendError("stdin must hold the output of the build step")
        fixed = dict(
            producer_id=arguments.producer,
            rules_version=send.read_rules_version(arguments.rules_file),
        )
        replies = [
            reserve.submit(arguments.socket, send.build_request(fields, **fixed))
            for fields in batch["requests"]
        ]
    except (send.SendError, ValueError) as exc:
        print(json.dumps({"ok": False, "code": "ClientError", "reason": str(exc)}))
        return 2
    ok = all(reply.get("ok") is True for reply in replies)
    print(
        json.dumps(
            {
                "ok": ok,
                "replies": replies,
                "already_recorded": batch.get("already_recorded", []),
            },
            ensure_ascii=False,
        )
    )
    return 0 if ok else 1


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    steps = parser.add_subparsers(dest="step", required=True)
    built = steps.add_parser("build")
    built.add_argument("--repository", required=True)
    built.add_argument("--date", required=True, help="plan date, YYYY-MM-DD")
    built.add_argument("--summary-id", required=True)
    built.add_argument("--commit", required=True, help="the summary's plan commit")
    built.add_argument("--current", default="origin/main", help="the plan now")
    built.add_argument(
        "--holder", required=True, help="channel the requests are sent through"
    )
    built.add_argument("--trust-intra-commit-order", action="store_true")
    built.add_argument("--all", action="store_true", help="confirm every estimate")
    built.add_argument("--row", action="append", default=[], help="N=MINUTES")
    sent = steps.add_parser("send")
    sent.add_argument("--socket", default=send.DEFAULT_SOCKET)
    sent.add_argument("--rules-file", default=send.DEFAULT_RULES_FILE)
    sent.add_argument("--producer", default=send.DEFAULT_PRODUCER)
    arguments = parser.parse_args(argv)
    if arguments.step == "send":
        return send_all(arguments)
    try:
        return build(arguments)
    except AnswerError as exc:
        print(json.dumps({"ok": False, "code": "AnswerRefused", "reason": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
