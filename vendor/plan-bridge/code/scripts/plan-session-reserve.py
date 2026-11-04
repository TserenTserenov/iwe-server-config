#!/usr/bin/env python3
"""Reserve the pilot's time for one session by WP when it opens (WP-561 Ф55).

Contract v3 (DR-06, 04.11): opening a session by WP with the pilot submits a
reservation with the agent's estimate; without an estimate nothing is sent.
Two requests for the resource personal_time:[plan date, WP, session]:
allocation_confirmed (the reservation) and action_started (the session has
begun). The start is sent now because the ledger accepts it only on the
reservation's own day, and the pilot's answer to the daily summary, often
given the next day, can close only a started reservation. The bridge decides
both against the published plan and the day's budget; this client only
submits them.

Agents cannot read the receiver queue, so the queue tip is learned from the
receiver's ParentMismatch reply and the same request (same event_id) is sent
again. That is safe: the session is a new plan element, its meaning does not
depend on the queue order, and a repeated event_id is accepted only once.

Exit codes: 0 submitted, 1 refused by the receiver, 2 unusable input or the
receiver was not reached, 3 no receiver on this host (nothing submitted).
"""

from __future__ import annotations

import argparse
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

SCRIPT = Path(__file__).resolve()
_SPEC = importlib.util.spec_from_file_location(
    "plan_event_send", SCRIPT.parent / "plan-event-send.py"
)
send = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(send)

LIMITS_PATH = "machine/plan-bridge/limits.json"
WP_PATTERN = re.compile(r"WP-[0-9]+")
SESSION_PATTERN = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]{0,159}")
TIP_ATTEMPTS = 5
# The queue lock is held for milliseconds by a write or a delivery pass.
BUSY_PAUSE_SECONDS = 0.2


def resource_id(plan_date, stream_id, element_id):
    # Same construction as plan_bridge_allocation.personal_time_resource_id; the
    # bridge rejects any other spelling, so a drift here fails loudly, not silently.
    return "personal_time:" + json.dumps(
        [plan_date, stream_id, element_id], ensure_ascii=True, separators=(",", ":")
    )


def plan_date_today(repository, time_zone=None):
    """Today in the budget's time zone: given, or read from the published limits.

    The Mac's channel runs on Tsekh under a user without a plan clone; its
    gateway passes the limits' time zone instead.
    """
    if time_zone is not None:
        try:
            return datetime.now(ZoneInfo(time_zone)).date().isoformat()
        except (ValueError, KeyError) as exc:
            raise send.SendError(f"unknown time zone {time_zone!r}") from exc
    shown = subprocess.run(
        ["git", "-C", str(repository), "show", f"origin/main:{LIMITS_PATH}"],
        capture_output=True,
        check=False,
    )
    if shown.returncode:
        raise send.SendError(f"cannot read published limits in {repository}")
    try:
        zone = ZoneInfo(json.loads(shown.stdout)["timezone"])
    except (ValueError, KeyError, TypeError) as exc:
        raise send.SendError("published limits have no usable timezone") from exc
    return datetime.now(zone).date().isoformat()


def reservation(wp, session, minutes, plan_date):
    if not WP_PATTERN.fullmatch(wp):
        raise send.SendError("--wp must look like WP-561")
    if not SESSION_PATTERN.fullmatch(session):
        raise send.SendError("--session must be the session id (letters, digits, ._-)")
    if type(minutes) is not int or not 1 <= minutes <= 1440:
        raise send.SendError("--minutes must be a whole estimate from 1 to 1440")
    return {
        "event_type": "allocation_confirmed",
        "stream_id": wp,
        "element_id": session,
        "basis": {"reason_code": "session_open", "text": "agent estimate"},
        "payload": {
            "resource_id": resource_id(plan_date, wp, session),
            "resource_type": "personal_time",
            "generation_claimed": 1,
            "plan_date": plan_date,
            "reserved_minutes": minutes,
        },
    }


def start(reserved):
    """The session begins: same resource and generation, child of the reservation."""
    payload = reserved["payload"]
    return {
        "event_type": "action_started",
        "stream_id": reserved["stream_id"],
        "element_id": reserved["element_id"],
        "expected_parent": reserved["event_id"],
        "basis": {"reason_code": "session_open", "text": "session started"},
        "payload": {
            key: payload[key]
            for key in ("resource_id", "resource_type", "generation_claimed")
        }
        | {"plan_date": payload["plan_date"]},
    }


def submit(socket_path, request, tip=None):
    """Send once; on a moved tip resend at the reported tip, on a busy queue a bit later."""
    for _ in range(TIP_ATTEMPTS):
        reply = send.exchange(socket_path, tip, request)
        if reply.get("code") == "StreamBusy":
            time.sleep(BUSY_PAUSE_SECONDS)
        elif reply.get("code") == "ParentMismatch" and "wal_tip" in reply:
            tip = reply["wal_tip"]
        else:
            return reply
    return reply


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--wp", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--minutes", required=True, type=int)
    parser.add_argument(
        "--repository", default=str(Path.home() / "IWE" / "DS-my-strategy")
    )
    parser.add_argument("--socket", default=send.DEFAULT_SOCKET)
    parser.add_argument("--rules-file", default=send.DEFAULT_RULES_FILE)
    parser.add_argument("--producer", default=send.DEFAULT_PRODUCER)
    parser.add_argument("--timezone", help="budget time zone instead of --repository")
    arguments = parser.parse_args(argv)
    if not os.path.exists(arguments.socket):
        print(json.dumps({"ok": False, "code": "NoReceiver", "submitted": False}))
        return 3
    try:
        plan_date = plan_date_today(arguments.repository, arguments.timezone)
        fixed = dict(
            producer_id=arguments.producer,
            rules_version=send.read_rules_version(arguments.rules_file),
        )
        reserved = send.build_request(
            reservation(arguments.wp, arguments.session, arguments.minutes, plan_date),
            **fixed,
        )
        reply = submit(arguments.socket, reserved)
        started = None
        if reply.get("ok") is True:
            started = submit(
                arguments.socket,
                send.build_request(start(reserved), **fixed),
                tip=reserved["event_id"],
            )
    except send.SendError as exc:
        print(json.dumps({"ok": False, "code": "ClientError", "reason": str(exc)}))
        return 2
    ok = reply.get("ok") is True and (started or {}).get("ok") is True
    print(
        json.dumps(
            {
                "ok": ok,
                "reservation": reply,
                "start": started,
                "plan_date": plan_date,
                "minutes": arguments.minutes,
            },
            ensure_ascii=False,
        )
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
