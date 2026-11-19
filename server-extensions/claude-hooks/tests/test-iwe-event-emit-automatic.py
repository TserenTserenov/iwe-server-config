#!/usr/bin/env python3
"""Emitter marks automation events only on a positive signal (WP-427 F10.8).

Runs iwe_event_emit.sh against a local receiver and checks the request body.
Run: python3 .claude/hooks/tests/test-iwe-event-emit-automatic.py
"""
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

EMITTER = Path(__file__).resolve().parents[2] / "lib" / "iwe_event_emit.sh"
RECEIVED: list = []


class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        RECEIVED.append(json.loads(self.rfile.read(length)))
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_args):
        pass


def emit(event_type: str, payload: str, automation):
    """Send one event; return the payload the receiver saw."""
    RECEIVED.clear()
    env = {k: v for k, v in os.environ.items() if k != "IWE_AUTOMATION"}
    env["IWE_EMIT_SYNC"] = "1"
    env["IWE_EVENT_GATEWAY_URL"] = f"http://127.0.0.1:{server.server_port}"
    if automation is not None:
        env["IWE_AUTOMATION"] = automation
    result = subprocess.run(
        ["bash", str(EMITTER), event_type, "test-suffix", payload],
        env=env, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert len(RECEIVED) == 1, f"expected one request, got {len(RECEIVED)}"
    return RECEIVED[0]["payload"]


server = HTTPServer(("127.0.0.1", 0), Receiver)
threading.Thread(target=server.serve_forever, daemon=True).start()

# Signal set: marked, original payload kept.
body = emit("git_commit", '{"repo": "x"}', "1")
assert body["automatic"] is True and body["repo"] == "x", body
assert emit("iwe_session", '{"a": 1}', "1")["automatic"] is True

# No signal, other values: no field at all (unknown, not false).
assert "automatic" not in emit("git_commit", '{"repo": "x"}', None)
assert "automatic" not in emit("git_commit", '{"repo": "x"}', "0")
assert "automatic" not in emit("git_commit", '{"repo": "x"}', "")

# Signal set, but the event type is outside the marked list: untouched.
assert "automatic" not in emit("wp_closed", '{"a": 1}', "1")
assert "automatic" not in emit("day_open", '{"a": 1}', "1")
# pack_updated is outside the agreed scope (separate pilot decision).
assert "automatic" not in emit("pack_updated", '{"a": 1}', "1")

server.shutdown()
print("OK: iwe_event_emit.sh marks automation only on IWE_AUTOMATION=1")
