#!/usr/bin/env python3
"""One-pass plan delivery and reviewable host scheduler files (no installation).

The only host integration is scripts/lib/plan_bridge_host.py beside this CLI.
It exports create_host_adapter() returning verifier, trusted_context and
validator_factory attributes. No CLI/environment field supplies identity.
"""

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import sys
import tempfile

SCRIPT = Path(__file__).resolve()
LIBRARY = SCRIPT.parent / "lib"
HOST_ADAPTER = LIBRARY / "plan_bridge_host.py"
SCHEMA = "plan-bridge-cli/1"
PLIST_NAME = "com.iwe.plan-event-bridge.plist"
SERVICE_NAME = "plan-event-bridge.service"
TIMER_NAME = "plan-event-bridge.timer"
RETRY_INTERVAL_SECONDS = 25
# Health file for the plan board (WP-530 F85, contract in
# inbox/WP-530/F85-bridge-contracts-handoff.md). It lives next to the queue,
# outside Git, and is written only under the delivery lock.
HEALTH_FILE = "bridge-health.json"
HEALTH_SCHEMA = "plan-bridge-health/1"
HEALTH_MAX_BYTES = 65536
LATENCY_WINDOW = 200
RECOVERY_OWNER_DEFAULT = "РП-530 (пилот)"
RESET_STATES = frozenset({"published", "confirmed", "waiting"})
CONTENTION_STATES = frozenset({"base_changed", "lock_busy"})
# Bytecode is read from and written to a service-owned directory only: a cache an
# agent can write to beside the sources would load instead of the checked code.
PYCACHE_PREFIX = "/var/cache/iwe-plan-bridge"
sys.path.insert(0, str(LIBRARY))


class ClosedConfiguration(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _emit(record, *, stream=sys.stdout):
    print(
        json.dumps({"schema": SCHEMA, **record}, sort_keys=True),
        file=stream,
        flush=True,
    )


def _log(phase, action, **fields):
    _emit({"phase": phase, "action": action, **fields}, stream=sys.stderr)


def _absolute(value):
    if not value.strip() or any(
        ord(character) < 32 or ord(character) == 127 for character in value
    ):
        raise ClosedConfiguration("INVALID_PATH")
    return Path(value).expanduser().resolve()


def _configuration(arguments):
    required = ["stream_dir"]
    if not arguments.status:
        required.append("repository")
    if any(getattr(arguments, field) is None for field in required):
        raise ClosedConfiguration("MISSING_PATH_ARGUMENT")
    return {field: _absolute(getattr(arguments, field)) for field in required}


def _check_host_adapter_file():
    if not HOST_ADAPTER.is_file():
        raise ClosedConfiguration("HOST_ADAPTER_MISSING")
    if HOST_ADAPTER.is_symlink():
        raise ClosedConfiguration("HOST_ADAPTER_UNSAFE")
    try:
        compile(HOST_ADAPTER.read_bytes(), str(HOST_ADAPTER), "exec")
    except (OSError, SyntaxError, ValueError) as exc:
        raise ClosedConfiguration("HOST_ADAPTER_INVALID") from exc


def _host_adapter():
    _check_host_adapter_file()
    try:
        spec = importlib.util.spec_from_file_location("plan_bridge_host", HOST_ADAPTER)
        if spec is None or spec.loader is None:
            raise ClosedConfiguration("HOST_ADAPTER_INVALID")
        module = importlib.util.module_from_spec(spec)
        sys.modules["plan_bridge_host"] = module
        spec.loader.exec_module(module)
        factory = getattr(module, "create_host_adapter", None)
        if not callable(factory):
            raise ClosedConfiguration("HOST_ADAPTER_INVALID")
        adapter = factory()
        if not callable(getattr(getattr(adapter, "verifier", None), "verify", None)):
            raise ClosedConfiguration("PRODUCER_VERIFIER_MISSING")
        if getattr(adapter, "trusted_context", None) is None:
            raise ClosedConfiguration("TRUSTED_CONTEXT_MISSING")
        if not callable(getattr(adapter, "validator_factory", None)):
            raise ClosedConfiguration("PLAN_VALIDATOR_MISSING")
        return adapter
    except ClosedConfiguration:
        raise
    except Exception as exc:
        raise ClosedConfiguration("HOST_ADAPTER_FAILED") from exc


def _runtime():
    try:
        import plan_event_bridge
        import plan_event_intake
        import plan_event_wal
        from plan_bridge_decisions import BridgeError
    except ImportError as exc:
        raise ClosedConfiguration("RUNTIME_UNAVAILABLE") from exc
    return plan_event_bridge, plan_event_intake, plan_event_wal, BridgeError


def delivery_command(configuration):
    """The same isolated, shell-free one-pass command for timer and immediate kick."""
    # Preserve the venv executable path: resolving its symlink loses that environment.
    command = [
        str(Path(sys.executable).absolute()),
        "-I",
        "-X",
        f"pycache_prefix={PYCACHE_PREFIX}",
        str(SCRIPT),
        "--deliver-once",
    ]
    for field in ("stream_dir", "repository"):
        command.extend(["--" + field.replace("_", "-"), str(configuration[field])])
    return command


def _systemd_argument(argument):
    """Escape an ExecStart word, including systemd's own $ and % expansions."""
    # systemd.service(5) COMMAND LINES and systemd.syntax(7) Quoting.
    if any(ord(character) < 32 or ord(character) == 127 for character in argument):
        raise ClosedConfiguration("INVALID_PATH")
    escaped = argument.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped.replace("$", "$$").replace("%", "%%") + '"'


def scheduler_documents(configuration):
    command = delivery_command(configuration)
    log_path = str(configuration["stream_dir"] / "bridge.log")
    plist = plistlib.dumps(
        {
            "Label": "com.iwe.plan-event-bridge",
            "ProgramArguments": command,
            "StartInterval": RETRY_INTERVAL_SECONDS,
            "RunAtLoad": True,
            "ProcessType": "Background",
            "StandardOutPath": log_path,
            "StandardErrorPath": log_path,
        },
        sort_keys=True,
    )
    service = (
        "# Generated only; live admission and host installation are separate.\n"
        "[Unit]\nDescription=One pass of durable plan delivery\n\n"
        "[Service]\nType=oneshot\n"
        "CacheDirectory=iwe-plan-bridge\nUMask=0022\n"
        "ExecStart="
        + " ".join(_systemd_argument(argument) for argument in command)
        + "\n"
        "StandardOutput=journal\nStandardError=journal\n"
    )
    timer = (
        "# Nominal retry while the host runs; no bound during sleep or outage.\n"
        "[Unit]\nDescription=Retry durable plan delivery\n\n"
        # K14: count from the end of the previous pass; a calendar tick merges
        # into a still-running oneshot and widens the gap past 30 s.
        "[Timer]\nOnActiveSec=5s\nOnBootSec=30s\nOnUnitInactiveSec=5s\nAccuracySec=1s\n"
        "RandomizedDelaySec=0\nUnit=plan-event-bridge.service\n\n"
        "[Install]\nWantedBy=timers.target\n"
    )
    return {
        PLIST_NAME: plist,
        SERVICE_NAME: service.encode(),
        TIMER_NAME: timer.encode(),
    }


def render_schedulers(output, configuration):
    documents = scheduler_documents(configuration)
    # Preflight every destination before writing any file; an installed file is
    # never silently replaced by a differently configured generated artifact.
    for name, content in documents.items():
        target = output / name
        if target.is_symlink() or (
            target.exists() and (not target.is_file() or target.read_bytes() != content)
        ):
            raise ClosedConfiguration("SCHEDULER_DESTINATION_CONFLICT")
    output.mkdir(parents=True, exist_ok=True)
    for name, content in documents.items():
        if (output / name).exists():
            continue
        with tempfile.NamedTemporaryFile(
            dir=output, prefix=".bridge-", delete=False
        ) as temporary:
            path = Path(temporary.name)
            try:
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
                # A concurrent generator cannot overwrite a newly created file.
                os.link(path, output / name)
            finally:
                path.unlink(missing_ok=True)
    return dict(
        state="rendered",
        installed=False,
        publication_attempted=False,
        files=[str(output / name) for name in documents],
        immediate_kick_command=delivery_command(configuration),
        nominal_retry_interval_seconds=RETRY_INTERVAL_SECONDS,
        host_sleep_or_unavailability_bound=False,
    )


def local_status(configuration):
    directory = configuration["stream_dir"]
    if not directory.exists():
        return dict(
            state="not_initialized",
            publication_attempted=False,
            identity_checked=False,
            origin_checked=False,
        )
    bridge, intake, _, _ = _runtime()
    with bridge.delivery_lock(directory):
        metadata = intake.read_metadata(directory)
        records = intake.read_intake(
            directory, wait_seconds=bridge.READ_LOCK_WAIT_SECONDS
        )
        cursor = bridge.read_cursor(directory, metadata)
        if cursor["confirmed_seq"] > len(records):
            raise ClosedConfiguration("CONFIRMED_RECORD_LOST")
        pending = records[cursor["confirmed_seq"] :]
        age = 0
        if pending:
            registered = datetime.fromisoformat(
                pending[0]["registered_at"].replace("Z", "+00:00")
            )
            age = max(0, (datetime.now(timezone.utc) - registered).total_seconds())
        return dict(
            state="local_status",
            records=len(records),
            confirmed_seq=cursor["confirmed_seq"],
            pending=len(pending),
            oldest_age_seconds=age,
            overdue=age > bridge.OVERDUE_SECONDS,
            publication_attempted=False,
            identity_checked=False,
            origin_checked=False,
        )


def classify_failure(exc):
    """The state/code pair shown for a failed pass, in stdout and the health file.

    Only the classification is exposed; verifier/Git exception text may carry
    private context.
    """
    if isinstance(exc, ClosedConfiguration):
        return dict(state="closed", code=exc.code)
    # Another writer holds the queue lock: the same retryable state as the
    # result path's lock_busy, not a runtime failure (WP-561 Ф58). The WAL
    # module is loaded lazily by _runtime(); if it was never loaded, this
    # exception cannot be its StreamBusy.
    wal = sys.modules.get("plan_event_wal")
    if wal is not None and isinstance(exc, wal.StreamBusy):
        return dict(state="lock_busy", code="STREAM_BUSY")
    supplied = getattr(exc, "code", None)
    code = (
        supplied
        if isinstance(supplied, str) and re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", supplied)
        else "RUNTIME_FAILURE"
    )
    retry = getattr(exc, "stop", True) is False
    return dict(state="retry" if retry else "stopped", code=code)


def _is_failure(outcome):
    if outcome["state"] in RESET_STATES or outcome["state"] in CONTENTION_STATES:
        return False
    return not (outcome["state"] == "retry" and outcome.get("code") == "LOCK_BUSY")


def read_health(directory):
    """Previous health document: (document, True), (None, True) if absent,
    (None, False) if present but unreadable -- the history is then unknown."""
    path = Path(directory) / HEALTH_FILE
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None, True
    except OSError:
        return None, False
    try:
        with os.fdopen(fd, "rb") as source:
            raw = source.read(HEALTH_MAX_BYTES + 1)
        if len(raw) > HEALTH_MAX_BYTES:
            return None, False
        document = json.loads(raw)
    except (OSError, ValueError, RecursionError):
        return None, False
    if (
        not isinstance(document, dict)
        or document.get("schema") != HEALTH_SCHEMA
        or not isinstance(document.get("generation"), str)
        or type(document.get("pass_seq")) is not int
        or not isinstance(document.get("latency_window"), list)
        or document.get("history") not in ("known", "unknown")
        or not (
            document.get("consecutive_failures") is None
            or type(document.get("consecutive_failures")) is int
        )
        or type(document.get("contention_streak")) is not int
    ):
        return None, False
    return document, True


def _snapshot_usable(observation):
    """A snapshot was read and its cursor fits it; a cursor beyond the WAL tail
    (CONFIRMED_RECORD_LOST) is a damaged queue, reported without queue fields."""
    return "records" in observation and observation["confirmed_seq"] <= len(
        observation["records"]
    )


def _age_seconds(registered_at, moment):
    stamp = datetime.fromisoformat(registered_at.replace("Z", "+00:00"))
    return max(0.0, (moment - stamp).total_seconds())


def build_health(previous, readable, outcome, observation, *, completed_at, limits):
    """Pure: the next health document from the previous one and this pass."""
    if previous is not None:
        generation, pass_seq = previous["generation"], previous["pass_seq"] + 1
        history = previous.get("history", "known")
        failures = previous.get("consecutive_failures")
        contention = previous.get("contention_streak", 0)
        window = list(previous["latency_window"])
    else:
        generation, pass_seq = secrets.token_hex(8), 1
        history = "known" if readable else "unknown"
        failures = 0 if readable else None
        contention, window = 0, []
    state = outcome["state"]
    if state in RESET_STATES:
        history, failures = "known", 0
    elif _is_failure(outcome) and failures is not None:
        failures += 1
    contention = contention + 1 if state in CONTENTION_STATES else 0
    document = dict(
        schema=HEALTH_SCHEMA,
        generation=generation,
        pass_seq=pass_seq,
        history=history,
        completed_at=completed_at.isoformat(),
        state=state,
        code=outcome.get("code"),
        consecutive_failures=failures,
        contention_streak=contention,
        snapshot_available=_snapshot_usable(observation),
        stale_after_seconds=limits["stale_after_seconds"],
        nominal_retry_interval_seconds=RETRY_INTERVAL_SECONDS,
        max_stream_records=limits["max_stream_records"],
        max_stream_bytes=limits["max_stream_bytes"],
        recovery_owner=os.environ.get("IWE_PLAN_BRIDGE_RECOVERY_OWNER")
        or RECOVERY_OWNER_DEFAULT,
        latency_window=window[-LATENCY_WINDOW:],
    )
    if not _snapshot_usable(observation):
        return document
    records = observation["records"]
    before, after = observation["confirmed_seq_before"], observation["confirmed_seq"]
    for record in records[before:after]:
        window.append(
            dict(
                confirmed_at=completed_at.isoformat(),
                seconds=_age_seconds(record["registered_at"], completed_at),
            )
        )
    oldest = (
        _age_seconds(records[after]["registered_at"], completed_at)
        if after < len(records)
        else 0.0
    )
    document.update(
        delivery_id=observation["delivery_id"],
        wal_epoch=observation["wal_epoch"],
        snapshot_at=observation["snapshot_at"],
        snapshot_tail_seq=len(records),
        wal_records=len(records),
        wal_bytes=observation.get("wal_bytes"),
        confirmed_seq=after,
        pending_after=len(records) - after,
        oldest_pending_age_seconds_after=oldest,
        overdue=oldest > limits["stale_after_seconds"],
        confirmed_origin_commit=observation["confirmed_origin_commit"],
        latency_window=window[-LATENCY_WINDOW:],
    )
    return document


def write_health(directory, document):
    directory = Path(directory)
    with tempfile.NamedTemporaryFile(
        dir=directory, prefix=".bridge-health-", delete=False
    ) as output:
        temporary = Path(output.name)
        try:
            output.write(
                json.dumps(document, sort_keys=True, ensure_ascii=False).encode()
            )
            output.flush()
            # The board reads this file from another process; the temporary
            # file is created 0600 regardless of the service umask.
            os.fchmod(output.fileno(), 0o644)
            os.fsync(output.fileno())
            os.replace(temporary, directory / HEALTH_FILE)
        finally:
            temporary.unlink(missing_ok=True)


def _record_health(directory, previous, readable, outcome, observation, limits):
    """Telemetry never changes delivery: a failure here is logged, not raised."""
    try:
        if "records" in observation:
            # A stream may have metadata but no wal.log yet (first append
            # failed or never happened): that is an empty WAL, not an error.
            log = Path(directory) / "wal.log"
            observation["wal_bytes"] = log.stat().st_size if log.is_file() else 0
        document = build_health(
            previous,
            readable,
            outcome,
            observation,
            completed_at=datetime.now(timezone.utc),
            limits=limits,
        )
        write_health(directory, document)
    except Exception as exc:
        _log("telemetry_failed", "deliver_once", error=type(exc).__name__)


def deliver(configuration, adapter):
    bridge, _, wal, _ = _runtime()
    # One service-owned clone: the plan is read from and published to its origin.
    repository = configuration["repository"]
    directory = Path(configuration["stream_dir"]).resolve()
    limits = dict(
        stale_after_seconds=bridge.OVERDUE_SECONDS,
        max_stream_records=wal.DEFAULT_MAX_STREAM_RECORDS,
        max_stream_bytes=wal.DEFAULT_MAX_STREAM_BYTES,
    )
    # LOCK_BUSY is raised entering the lock: the loser never touches the
    # winner's health file. Everything after it runs under one lock, so the
    # pass result and its health record cannot interleave with another pass.
    with bridge.delivery_lock(directory):
        previous, readable = read_health(directory)
        observation = {}
        try:
            result = bridge.deliver_locked(
                directory,
                reader=bridge.GitPlanReader(repository),
                publisher=bridge.GitCasPublisher(repository),
                verifier=adapter.verifier,
                trusted_context=adapter.trusted_context,
                validator_factory=adapter.validator_factory,
                observation=observation,
            )
        except Exception as exc:
            _record_health(
                directory,
                previous,
                readable,
                classify_failure(exc),
                observation,
                limits,
            )
            raise
        _record_health(directory, previous, readable, result, observation, limits)
        return result


def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--deliver-once", action="store_true")
    action.add_argument("--status", action="store_true")
    action.add_argument("--check", action="store_true")
    action.add_argument("--render-schedulers", metavar="OUTPUTDIR")
    for name in ("stream-dir", "repository"):
        parser.add_argument("--" + name)
    return parser


def main(argv=None):
    arguments = _parser().parse_args(argv)
    action = (
        "deliver_once"
        if arguments.deliver_once
        else (
            "status"
            if arguments.status
            else "check"
            if arguments.check
            else "render_schedulers"
        )
    )
    _log("start", action)
    try:
        configuration = _configuration(arguments)
        if arguments.render_schedulers is not None:
            result = render_schedulers(
                _absolute(arguments.render_schedulers), configuration
            )
        elif arguments.status:
            result = local_status(configuration)
        else:
            # Fail before opening the intake, Git, cursor or publisher.
            if arguments.check:
                # Compile only: even a trusted integration factory may perform
                # I/O while constructing its context. --check never invokes it.
                _check_host_adapter_file()
                _runtime()
                result = dict(
                    state="configuration_checked",
                    host_adapter_executed=False,
                    live_admission="not_evaluated",
                    publication_attempted=False,
                )
            else:
                result = deliver(configuration, _host_adapter())
        _emit(result)
        _log(
            "complete",
            action,
            state=result["state"],
            overdue=result.get("overdue", False),
        )
        return (
            75
            if result["state"]
            in {"base_changed", "push_unknown", "push_refused", "lock_busy"}
            else 0
        )
    except Exception as exc:
        # No failure path removes the queue or advances a cursor.
        outcome = classify_failure(exc)
        if outcome["state"] == "closed":
            _emit(dict(outcome, publication_attempted=False))
            _log("stopped", action, **outcome)
            return 78
        _emit(outcome)
        if outcome["state"] == "lock_busy":
            _log("complete", action, **outcome)
            return 75
        _log("stopped", action, **outcome)
        return 75 if outcome["state"] == "retry" else 1


if __name__ == "__main__":
    raise SystemExit(main())
