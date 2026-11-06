#!/usr/bin/env python3
"""Local socket receiver for plan-event requests (WP-561 Ф55, К12).

Started by the host service under the service uid, never by an agent. Admitted
producers are fixed in the unit's arguments; the socket's group decides who may
connect. --channel adds another socket with its own group and its own single
admitted producer (the Mac's channel reaches this host through a dedicated SSH
key); all channels write the one queue through one lock in this process. The host config (key, rules, code ownership) is checked by the same
adapter the bridge uses, so a host that is not ready does not start receiving.
"""

from __future__ import annotations

import argparse
import grp
import json
import logging
from pathlib import Path
import queue
import subprocess
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import plan_bridge_host as host  # noqa: E402
import plan_bridge_receiver as receiver  # noqa: E402

_LOG = logging.getLogger("plan-receiver")


def _kick_unit(unit: str):
    def kick():
        subprocess.run(
            ["systemctl", "start", "--no-block", unit], check=True, timeout=10
        )

    return kick


def _parser():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--stream-dir", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument(
        "--admit", action="append", required=True, metavar="PRODUCER_ID"
    )
    parser.add_argument("--group", help="group that may connect to the socket")
    parser.add_argument("--kick-unit", help="systemd unit that delivers one pass")
    parser.add_argument(
        "--channel",
        action="append",
        default=[],
        nargs=3,
        metavar=("SOCKET", "GROUP", "PRODUCER_ID"),
        help="another socket whose group may submit as exactly this producer",
    )
    return parser


def main(argv):
    arguments = _parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    try:
        adapter = host.create_host_adapter()
    except host.HostAdapterError as exc:
        print(json.dumps({"state": "closed", "reason": str(exc)}), file=sys.stderr)
        return 2
    channels = [(arguments.socket, arguments.group, arguments.admit)] + [
        (socket_path, group, [producer])
        for socket_path, group, producer in arguments.channel
    ]
    write_lock = threading.Lock()
    kick = _kick_unit(arguments.kick_unit) if arguments.kick_unit else None
    servers = [
        receiver.make_server(
            Path(socket_path),
            stream_dir=Path(arguments.stream_dir),
            verifier=adapter.verifier,
            context=host.ChannelContext(adapter.verifier.host_id, frozenset(admit)),
            kick=kick,
            group_id=grp.getgrnam(group).gr_gid if group else None,
            write_lock=write_lock,
        )
        for socket_path, group, admit in channels
    ]
    return _serve_until_first_exit(
        servers, [path for path, _, _ in channels], write_lock
    )


def _serve_until_first_exit(servers, names, write_lock):
    """Serve every channel; the first one to stop ends the process with 1.

    Exit code 2 stays reserved for "host configuration closed" at startup
    (RestartPreventExitStatus=2); 1 makes systemd restart the receiver
    (Restart=on-failure). shutdown() is never called: it waits for a handler
    without a timeout and could keep a half-dead process running. Server
    threads are daemons, so returning abandons them with the process.
    Before exiting it waits, bounded, for a sibling channel to finish an
    in-flight write, so a durably queued request still gets its reply.
    Known limit: serve_forever survives an OSError from accept, so such a
    half-dead channel is not detected here (WP-561 Ф58).
    """
    stopped = queue.Queue()

    def serve(server, name):
        try:
            server.serve_forever()
        except BaseException:
            _LOG.exception("[plan-receiver] channel %s failed", name)
        finally:
            stopped.put(name)

    for server, name in zip(servers, names):
        threading.Thread(target=serve, args=(server, name), daemon=True).start()
    name = stopped.get()
    _LOG.error("[plan-receiver] channel %s stopped; exiting for restart", name)
    if not write_lock.acquire(timeout=receiver.READ_TIMEOUT_SECONDS):
        _LOG.error("[plan-receiver] in-flight write did not finish; exiting anyway")
    for server in servers:
        server.server_close()
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
