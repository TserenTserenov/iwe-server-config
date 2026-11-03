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
        required.extend(["repository", "workspace", "checkout"])
    if any(getattr(arguments, field) is None for field in required):
        raise ClosedConfiguration("MISSING_PATH_ARGUMENT")
    configuration = {field: _absolute(getattr(arguments, field)) for field in required}
    if (
        "repository" in configuration
        and configuration["repository"].parent != configuration["workspace"]
    ):
        raise ClosedConfiguration("REPOSITORY_OUTSIDE_WORKSPACE")
    return configuration


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
    for field in ("stream_dir", "repository", "workspace", "checkout"):
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
        "[Timer]\nOnCalendar=*-*-* *:*:00,25,50\nAccuracySec=1s\n"
        "RandomizedDelaySec=0\nPersistent=true\nUnit=plan-event-bridge.service\n\n"
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
        records = intake.read_intake(directory)
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


def deliver(configuration, adapter):
    bridge, _, _, _ = _runtime()
    repository, workspace = configuration["repository"], configuration["workspace"]
    reader = bridge.GitPlanReader(repository)
    publisher = bridge.LedgerPublisher(
        SCRIPT.parent / "ledger-publish.sh",
        workspace=workspace,
        governance_repo=repository.name,
        checkout=configuration["checkout"],
    )
    return bridge.deliver_once(
        configuration["stream_dir"],
        reader=reader,
        publisher=publisher,
        verifier=adapter.verifier,
        trusted_context=adapter.trusted_context,
        validator_factory=adapter.validator_factory,
    )


def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--deliver-once", action="store_true")
    action.add_argument("--status", action="store_true")
    action.add_argument("--check", action="store_true")
    action.add_argument("--render-schedulers", metavar="OUTPUTDIR")
    for name in ("stream-dir", "repository", "workspace", "checkout"):
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
            else "check" if arguments.check else "render_schedulers"
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
            if result["state"] in {"base_changed", "push_unknown", "lock_busy"}
            else 0
        )
    except ClosedConfiguration as exc:
        result = dict(state="closed", code=exc.code, publication_attempted=False)
        _emit(result)
        _log("stopped", action, state="closed", code=exc.code)
        return 78
    except Exception as exc:
        # Only classification is exposed; verifier/Git exception text may carry
        # private context. No failure path removes the queue or advances a cursor.
        supplied = getattr(exc, "code", None)
        code = (
            supplied
            if isinstance(supplied, str)
            and re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", supplied)
            else "RUNTIME_FAILURE"
        )
        retry = (
            getattr(exc, "stop", True) is False or type(exc).__name__ == "StreamBusy"
        )
        _emit(dict(state="retry" if retry else "stopped", code=code))
        _log("stopped", action, state="retry" if retry else "stopped", code=code)
        return 75 if retry else 1


if __name__ == "__main__":
    raise SystemExit(main())
