"""Trusted receiver for plan-event requests (WP-561 Ф55, К12, DR-06).

Agents never touch the WAL: they send one JSON line to a local socket owned by
the host-service uid. This module is the only place that builds the
`ChannelContext` the host adapter requires to mint a producer proof, and the
socket's file mode is what admits a caller (level 1: producers are told apart
by the channel, not by the agent; DR-06 "Граница доверия").

Wire format, one exchange per connection, newline-terminated JSON:
    in : {"expected_wal_tip": <event_id | null>, "request": {<14 v2 fields>}}
    out: {"ok": true, "receipt": {...}} | {"ok": false, "code": ..., "reason": ...}
Replies never carry proofs, keys or paths.
"""

from __future__ import annotations

from collections.abc import Callable
import json
import logging
import os
from pathlib import Path
import socket
import socketserver
import stat
import struct
import sys

import plan_bridge_host as host
import plan_event_bridge as bridge
import plan_event_intake as intake
import plan_event_wal as wal

MAX_LINE_BYTES = 128 * 1024
READ_TIMEOUT_SECONDS = 5
SOCKET_MODE = 0o660
_LOG = logging.getLogger(__name__)


class WireError(Exception):
    """The exchange is not a well-formed request message."""


def _reject_duplicate_keys(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise WireError("duplicate JSON key")
    return dict(pairs)


def _reject_constant(name):
    raise WireError(f"non-finite number {name}")


def parse_message(raw: bytes) -> tuple[dict, str | None]:
    """Strict decode: no duplicate keys, no NaN, exactly the two expected fields."""
    if len(raw) > MAX_LINE_BYTES:
        raise WireError("message too large")
    try:
        message = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise WireError("message is not valid JSON") from exc
    if not isinstance(message, dict) or set(message) != {"expected_wal_tip", "request"}:
        raise WireError("message must hold exactly expected_wal_tip and request")
    return message["request"], message["expected_wal_tip"]


def handle_message(
    raw: bytes,
    *,
    stream_dir: Path,
    verifier,
    context: host.ChannelContext,
    kick: Callable | None = None,
) -> dict:
    """One request in, one reply out. Every failure becomes a coded reply."""
    try:
        request, tip = parse_message(raw)
        receive = bridge.receive_and_kick if kick is not None else None
        arguments = dict(
            expected_wal_tip=tip, trusted_context=context, verifier=verifier
        )
        if receive is None:
            receipt = intake.receive_v2(Path(stream_dir), request, **arguments)
        else:
            receipt = receive(Path(stream_dir), request, kick=kick, **arguments)
        return {"ok": True, "receipt": receipt}
    except WireError as exc:
        return {"ok": False, "code": "WireError", "reason": str(exc)}
    except wal.WalError as exc:
        return {"ok": False, "code": type(exc).__name__, "reason": str(exc)[:200]}
    except Exception:  # noqa: BLE001 - the socket must always answer, never leak
        _LOG.exception("[plan-receiver] unexpected failure while receiving")
        return {"ok": False, "code": "InternalError", "reason": "see service log"}


def peer_uid(connection: socket.socket) -> int | None:
    """Audit only: who opened the socket. None where the platform does not say."""
    try:
        if sys.platform.startswith("linux"):
            data = connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
            )
            return struct.unpack("3i", data)[1]
        data = connection.getsockopt(0, 1, struct.calcsize("2I"))  # LOCAL_PEERCRED
        return struct.unpack("2I", data)[1]
    except (OSError, struct.error):
        return None


def _prepare_socket_path(path: Path):
    """Refuse anything that is not a dead socket of ours at the path."""
    if not os.path.lexists(path):
        return
    if not stat.S_ISSOCK(os.lstat(path).st_mode):
        raise OSError(f"{path} exists and is not a socket")
    probe = socket.socket(socket.AF_UNIX)
    try:
        probe.connect(str(path))
    except OSError:
        os.unlink(path)
        return
    finally:
        probe.close()
    raise OSError(f"{path} is held by a live receiver")


def make_server(
    socket_path: Path,
    *,
    stream_dir: Path,
    verifier,
    context: host.ChannelContext,
    kick: Callable | None = None,
    group_id: int | None = None,
) -> socketserver.UnixStreamServer:
    """Bind first with a closed mode, open it to the group only when it is ready."""
    socket_path = Path(socket_path)
    _prepare_socket_path(socket_path)

    class Handler(socketserver.StreamRequestHandler):
        timeout = READ_TIMEOUT_SECONDS

        def handle(self):
            raw = self.rfile.readline(MAX_LINE_BYTES + 1)
            if not raw:
                return  # connected and left without a word: a liveness probe
            reply = handle_message(
                raw.rstrip(b"\n"),
                stream_dir=stream_dir,
                verifier=verifier,
                context=context,
                kick=kick,
            )
            _LOG.info(
                "[plan-receiver] uid=%s ok=%s code=%s",
                peer_uid(self.request),
                reply["ok"],
                reply.get("code", "-"),
            )
            try:
                self.wfile.write(json.dumps(reply, sort_keys=True).encode() + b"\n")
            except OSError:
                _LOG.info("[plan-receiver] peer left before the reply")

    previous = os.umask(0o177)
    try:
        server = socketserver.UnixStreamServer(str(socket_path), Handler)
    finally:
        os.umask(previous)
    if group_id is not None:
        os.chown(socket_path, -1, group_id)
    os.chmod(socket_path, SOCKET_MODE if group_id is not None else 0o600)
    return server
