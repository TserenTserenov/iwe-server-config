"""ledger_path.py — Python twin of lib/ledger-path.sh (WP-484, 31.07: same
year/month hierarchy migration for machine/ledger/, kept in lock-step by hand
since there are only two languages here, not a build step worth adding for two files).
"""

import argparse
import os
from pathlib import Path
import runpy
import stat
import sys
from typing import Optional

_SCALE_TEMPLATES = {
    "day": "day/{year}/{month}/day-{period}.yaml",
    "week": "week/{year}/week-{period}.yaml",
    "month": "month/{year}/month-{period}.yaml",
    "plan": "plan/{year}/{month}/plan-{period}.yaml",
}

EVENTS_SCHEMA = "ledger/v1"
PLAN_SCHEMA = "plan-events/1"
_LEDGER_ROOT_PREFIX = ("machine", "ledger")


def expected_schema(rel: str) -> str:
    """Schema a ledger file must declare, decided by its path alone (WP-561 F33).

    `rel` is relative to the ledger root (plan/2026/10/plan-2026-10-10.yaml) or
    repo-relative (machine/ledger/plan/...). The plan/ namespace holds only
    plan-events/1 files; every other path holds only ledger/v1.
    """
    parts = [p for p in rel.split("/") if p]
    if tuple(parts[:2]) == _LEDGER_ROOT_PREFIX:
        parts = parts[2:]
    return PLAN_SCHEMA if parts and parts[0] == "plan" else EVENTS_SCHEMA


def ledger_path_rel(scale: str, period: str) -> str:
    """Suffix only (no root, no mkdir) -- for existence checks against multiple
    roots (ledger_dir vs archive_dir) or a git-relative string, where creating
    a directory would be wasteful or wrong.

    day   period=YYYY-MM-DD -> day/YYYY/MM/day-YYYY-MM-DD.yaml
    week  period=YYYY-Wnn   -> week/YYYY/week-YYYY-Wnn.yaml
    month period=YYYY-MM    -> month/YYYY/month-YYYY-MM.yaml
    plan  period=YYYY-MM-DD -> plan/YYYY/MM/plan-YYYY-MM-DD.yaml
    """
    template = _SCALE_TEMPLATES.get(scale)
    if template is None:
        raise ValueError(
            f"ledger_path_rel: недопустимый scale {scale!r} (day|week|month|plan)"
        )
    return template.format(year=period[:4], month=period[5:7], period=period)


def ledger_path(scale: str, period: str, root: str) -> str:
    """Full hierarchical path for a ledger file; creates parent dirs."""
    path = os.path.join(root, ledger_path_rel(scale, period))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def resolve_ledger_path(
    scale: str,
    period: str,
    active_root: str,
    archive_root: Optional[str] = None,
) -> str:
    """Return the period's one canonical readable path without creating anything.

    An archived file is used only when the active copy is absent. Two existing copies
    are split-brain drift, not an arbitrary precedence decision.
    """
    relative = ledger_path_rel(scale, period)
    active_path = os.path.join(active_root, relative)
    archive_path = os.path.join(archive_root, relative) if archive_root else None
    if archive_path and os.path.exists(active_path) and os.path.exists(archive_path):
        raise RuntimeError(
            f"ledger drift for {scale} {period}: both active and archived files exist "
            f"({active_path}; {archive_path})"
        )
    if os.path.exists(active_path):
        return active_path
    if archive_path and os.path.exists(archive_path):
        return archive_path
    return active_path


def read_ledger_document(
    scale: str,
    period: str,
    active_root: str,
    archive_root: Optional[str] = None,
    buffer_root: Optional[str] = None,
    max_file_bytes: Optional[int] = None,
) -> dict:
    """Read published and local buffered events with publisher identity semantics.

    The published order is authoritative. Events still in the buffer are added
    only when their full records (including multiplicity) are absent there.
    No directory is created by a read. A malformed source is an error, not an
    empty ledger: otherwise Day Open could report a false absence of evidence.
    """
    relative = ledger_path_rel(scale, period)
    published_path = resolve_ledger_path(scale, period, active_root, archive_root)
    return _read_ledger_paths(
        scale,
        period,
        published_path,
        _buffer_paths(relative, buffer_root),
        max_file_bytes,
    )


def read_ledger_document_from_scale_root(
    scale: str,
    period: str,
    active_scale_root: str,
    archive_root: Optional[str] = None,
    buffer_root: Optional[str] = None,
    max_file_bytes: Optional[int] = None,
) -> dict:
    """Read when an existing caller receives the day/ or week/ folder itself."""
    relative = ledger_path_rel(scale, period)
    active_path = os.path.join(active_scale_root, relative.split("/", 1)[1])
    archive_path = os.path.join(archive_root, relative) if archive_root else None
    if archive_path and os.path.exists(active_path) and os.path.exists(archive_path):
        raise RuntimeError(
            f"ledger drift for {scale} {period}: both active and archived files exist "
            f"({active_path}; {archive_path})"
        )
    published_path = (
        archive_path if archive_path and os.path.exists(archive_path) else active_path
    )
    return _read_ledger_paths(
        scale,
        period,
        published_path,
        _buffer_paths(relative, buffer_root),
        max_file_bytes,
    )


def buffer_home() -> str:
    """Fixed per-host directory of the persistent ledger buffer."""
    return os.environ.get("IWE_LEDGER_BUFFER_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state", "iwe", "ledger-buffer"
    )


def configured_buffer_root() -> Optional[str]:
    """Buffer root every reader uses.

    IWE_LEDGER_BUFFER_DIR wins, and an empty value means "no buffer" (tests,
    probes). Otherwise the host directory counts as soon as it holds a pending or
    acknowledged zone, so that a rollback which removes the writer marker never
    hides events that have not reached the published ledger yet.
    """
    if "IWE_LEDGER_BUFFER_DIR" in os.environ:
        return os.environ["IWE_LEDGER_BUFFER_DIR"] or None
    home = buffer_home()
    for zone in ("pending", "acknowledged"):
        if os.path.isdir(os.path.join(home, zone)):
            return home
    return None


def buffer_zone_roots(buffer_root: Optional[str]) -> list[str]:
    """Existing zone directories of a buffer, in reading order (pending first)."""
    if not buffer_root:
        return []
    return [
        os.path.join(buffer_root, zone) if zone else buffer_root
        for zone in ("pending", "acknowledged", "")
        if os.path.isdir(os.path.join(buffer_root, zone))
    ]


def _buffer_paths(relative: str, buffer_root: Optional[str]) -> list[str]:
    root = buffer_root or configured_buffer_root()
    if root and (
        not os.path.isabs(root) or os.path.islink(root) or not os.path.isdir(root)
    ):
        raise ValueError("ledger buffer root must be an existing absolute directory")
    if not root:
        return []
    paths = []
    # Read pending before acknowledged: the receipt mover writes the latter
    # first and only then removes the confirmed records from pending. A read
    # that overlaps the move may see both, but cannot miss the records.
    for zone in ("pending", "acknowledged", ""):
        path = Path(root, zone)
        for component in Path(relative).parts:
            path /= component
            if path.is_symlink():
                raise ValueError(f"ledger buffer path contains a symlink: {path}")
        if Path(root, zone).is_symlink():
            raise ValueError(f"ledger buffer zone is a symlink: {zone}")
        paths.append(str(path))
    return paths


def _read_ledger_paths(
    scale: str,
    period: str,
    published_path: str,
    buffer_paths: list[str],
    max_file_bytes: Optional[int],
) -> dict:
    import yaml

    relative = ledger_path_rel(scale, period)
    expected = {
        "schema": expected_schema(relative),
        "scale": "day" if scale == "plan" else scale,
        "period": period,
        "events": [],
    }

    event_diff = None

    def load(path: str, strict: bool) -> Optional[dict]:
        nonlocal event_diff
        if not os.path.exists(path):
            return None
        if strict and not os.path.isfile(path):
            raise ValueError(f"{path}: ledger source is not a regular file")
        if strict and event_diff is None:
            event_diff = runpy.run_path(
                str(Path(__file__).with_name("ledger-event-diff.py"))
            )
        flags = (
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        )
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, encoding="utf-8") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError(f"{path}: ledger source is not a regular file")
            content = (
                stream.read(max_file_bytes + 1)
                if max_file_bytes is not None
                else stream.read()
            )
            if (
                max_file_bytes is not None
                and len(content.encode("utf-8")) > max_file_bytes
            ):
                raise ValueError(f"{path}: ledger source exceeds byte limit")
            try:
                doc = yaml.load(
                    content,
                    Loader=event_diff["DuplicateKeyLoader"]
                    if strict
                    else yaml.SafeLoader,
                )
            except yaml.YAMLError as exc:
                raise ValueError(f"{path}: invalid ledger YAML: {exc}") from exc
        if not isinstance(doc, dict):
            raise ValueError(f"{path}: ledger document is not a mapping")
        if strict:
            event_diff["_check_header"](doc, expected, (path, "expected"))
        events = doc.get("events")
        if not isinstance(events, list) or any(not isinstance(e, dict) for e in events):
            raise ValueError(f"{path}: events must be a list of mappings")
        return doc

    published = load(published_path, strict=bool(buffer_paths))
    result = dict(published) if published is not None else dict(expected)
    result["events"] = list(result["events"])
    for path in buffer_paths:
        buffered = load(path, strict=True)
        if buffered is not None:
            result["events"].extend(
                event_diff["missing_events"](buffered["events"], result["events"])
            )
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Read published and buffered ledger events"
    )
    parser.add_argument("scale", choices=("day", "week", "month", "plan"))
    parser.add_argument("period")
    parser.add_argument("active_root")
    parser.add_argument("archive_root", nargs="?", default="")
    parser.add_argument("buffer_root", nargs="?", default="")
    args = parser.parse_args()
    import yaml

    yaml.safe_dump(
        read_ledger_document(
            args.scale,
            args.period,
            args.active_root,
            args.archive_root or None,
            args.buffer_root or None,
        ),
        stream=sys.stdout,
        allow_unicode=True,
        sort_keys=False,
    )
