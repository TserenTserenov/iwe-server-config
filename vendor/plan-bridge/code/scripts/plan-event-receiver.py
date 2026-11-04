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
import subprocess
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import plan_bridge_host as host  # noqa: E402
import plan_bridge_receiver as receiver  # noqa: E402


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
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        servers[0].serve_forever()
    finally:
        for server in servers:
            server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
