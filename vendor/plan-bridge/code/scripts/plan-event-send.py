#!/usr/bin/env python3
"""Send one plan-event request to the host receiver socket (WP-561 Ф55).

Reads the caller's fields as a JSON object on stdin, adds the fixed ones
(schema, producer, rules version, time, id) and writes one line to the unix
socket of the receiver. Standard library only: an agent can run it with any
Python. It never retries: a tip mismatch (CAS) means the plan moved and the
caller must look again, not repeat blindly.

Exit codes: 0 accepted, 1 refused by the receiver, 2 the receiver was not
reached or the input is unusable.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import socket
import sys
import uuid

DEFAULT_SOCKET = "/run/iwe-plan-bridge/receiver.sock"
DEFAULT_RULES_FILE = "/etc/iwe-plan-bridge/approved_rules_version"
DEFAULT_PRODUCER = "tsekh-agent-channel"
TIMEOUT_SECONDS = 10
CALLER_FIELDS = frozenset(
    {
        "event_id",
        "event_type",
        "element_id",
        "stream_id",
        "actor",
        "basis",
        "expected_parent",
        "tact_ref",
        "payload",
    }
)
REQUIRED_FROM_CALLER = ("event_type", "element_id", "stream_id", "payload")


class SendError(Exception):
    """Input or transport problem (exit code 2)."""


def read_rules_version(path):
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SendError(f"cannot read approved rules version: {exc}") from exc
    if len(lines) != 1 or not lines[0].strip():
        raise SendError("approved rules version is not set by the pilot yet")
    return lines[0].strip()


def build_request(fields, *, producer_id, rules_version, now=None):
    unknown = set(fields) - CALLER_FIELDS
    if unknown:
        raise SendError(f"unexpected fields: {sorted(unknown)}")
    missing = [name for name in REQUIRED_FROM_CALLER if name not in fields]
    if missing:
        raise SendError(f"missing fields: {missing}")
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "schema_version": 2,
        "data_version": 1,
        "event_id": str(uuid.uuid4()),
        "actor": {},
        "basis": {},
        "expected_parent": None,
        "tact_ref": None,
        **fields,
        "producer_id": producer_id,
        "rules_version": rules_version,
        "occurred_at": stamp,
    }


def exchange(socket_path, wal_tip, request):
    line = json.dumps({"expected_wal_tip": wal_tip, "request": request}) + "\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(TIMEOUT_SECONDS)
        try:
            connection.connect(socket_path)
            connection.sendall(line.encode())
            connection.shutdown(socket.SHUT_WR)
            raw = b""
            while chunk := connection.recv(65536):
                raw += chunk
        except OSError as exc:
            raise SendError(f"receiver not reached: {exc}") from exc
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise SendError("receiver answered with something that is not JSON") from exc


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("--rules-file", default=DEFAULT_RULES_FILE)
    parser.add_argument("--producer", default=DEFAULT_PRODUCER)
    parser.add_argument(
        "--wal-tip",
        default=None,
        help="event_id of the current queue tip; omit for an empty queue",
    )
    arguments = parser.parse_args(argv)
    try:
        fields = json.load(sys.stdin)
        if not isinstance(fields, dict):
            raise SendError("stdin must hold one JSON object")
        request = build_request(
            fields,
            producer_id=arguments.producer,
            rules_version=read_rules_version(arguments.rules_file),
        )
        reply = exchange(arguments.socket, arguments.wal_tip, request)
    except (SendError, ValueError) as exc:
        print(json.dumps({"ok": False, "code": "ClientError", "reason": str(exc)}))
        return 2
    print(json.dumps(reply, ensure_ascii=False))
    return 0 if reply.get("ok") is True else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
