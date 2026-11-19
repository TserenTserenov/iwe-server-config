"""Locale- and time-zone-independent process identity (WP-530 F160).

Python twin of scripts/lib/process-identity.sh; both must print identical
output, enforced by scripts/tests/session-guard-process-identity-smoke.sh.
See the shell file for the identity format and the verdict rules.

CLI (used by the contract test):
    process_identity.py identity <pid>          -> rc 0 ok, 1 proven absent, 2 unknown
    process_identity.py verdict <recorded> <pid> -> prints match|dead|unknown
"""

from __future__ import annotations

import calendar
import os
import platform
import re
import subprocess
import sys

MATCH, DEAD, UNKNOWN = "match", "dead", "unknown"

# [0-9] in a str pattern is ASCII only, unlike str.isdigit().
_PID_RE = re.compile(r"[1-9][0-9]*")
_NUM_RE = re.compile(r"0|[1-9][0-9]*")
_LINUX_RE = re.compile(r"linux:([0-9a-f-]+):([0-9]+):([1-9][0-9]*):(0|[1-9][0-9]*)")
_DARWIN_RE = re.compile(r"darwin:([0-9A-F-]+):([1-9][0-9]*):(0|[1-9][0-9]*)")
_MONTHS = {name: index for index, name in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), start=1)}
_LSTART_RE = re.compile(r"[A-Z][a-z]{2} ([A-Z][a-z]{2}) ([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4})")


_PID_MAX = 2**31 - 1


def _valid_pid_text(text: str) -> bool:
    """At most 10 ASCII digits and within int32, as in the shell twin."""
    return bool(_PID_RE.fullmatch(text)) and len(text) <= 10 and int(text) <= _PID_MAX


class ProcessAbsent(Exception):
    """The pid is proven not to exist."""


class IdentityUnknown(Exception):
    """The identity could not be established."""


def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="surrogateescape") as stream:
        return stream.read()


def _linux_proc_is_ours() -> bool:
    """/proc must belong to our pid namespace: /proc/self is then our own pid."""
    try:
        return int(os.readlink("/proc/self")) == os.getpid()
    except (OSError, ValueError):
        return False


def _linux_stat_fields(pid: int) -> list[str]:
    """Fields after the LAST ') ' of /proc/<pid>/stat: [0] state, [1] ppid, [19] start ticks."""
    if not _linux_proc_is_ours():
        raise IdentityUnknown("/proc belongs to another pid namespace")
    if not os.path.exists(f"/proc/{pid}"):
        raise ProcessAbsent(pid)
    try:
        stat = _read(f"/proc/{pid}/stat")
    except OSError as exc:
        if os.path.exists(f"/proc/{pid}"):
            raise IdentityUnknown(f"/proc/{pid}/stat: {exc}") from exc
        raise ProcessAbsent(pid) from exc
    marker = stat.rfind(") ")
    if marker < 0:
        raise IdentityUnknown(f"/proc/{pid}/stat has no ') '")
    fields = stat[marker + 2:].split()
    if len(fields) < 20 or not _NUM_RE.fullmatch(fields[19]):
        raise IdentityUnknown(f"/proc/{pid}/stat has no usable start field")
    return fields


def _linux_boot_id() -> str:
    try:
        return _read("/proc/sys/kernel/random/boot_id").strip()
    except OSError:
        return ""


def _linux_self_pidns() -> str:
    try:
        link = os.readlink("/proc/self/ns/pid")
    except OSError:
        return ""
    match = re.fullmatch(r"pid:\[([0-9]+)\]", link)
    return match.group(1) if match else ""


def _darwin_boot_id() -> str:
    try:
        result = subprocess.run(["sysctl", "-n", "kern.bootsessionuuid"],
                                capture_output=True, text=True, check=False)
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def _darwin_exists(pid: int) -> None:
    """kill(pid, 0): ESRCH proves absence, EPERM still proves existence."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError as exc:
        raise ProcessAbsent(pid) from exc
    except PermissionError:
        return
    except (OSError, OverflowError) as exc:
        raise IdentityUnknown(f"kill(0): {exc}") from exc


def _darwin_ps(pid: int, column: str) -> str:
    """A ps column of an existing pid; any failure is unknown, never absent."""
    env = {**os.environ, "LC_ALL": "C", "TZ": "UTC"}
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", f"{column}="],
                                capture_output=True, text=True, check=False, env=env)
    except OSError as exc:
        raise IdentityUnknown(f"ps: {exc}") from exc
    value = " ".join(result.stdout.split())
    if result.returncode != 0 or not value:
        raise IdentityUnknown(f"ps -o {column} failed for pid {pid}")
    return value


def _darwin_start_epoch(pid: int) -> int:
    """Parsed by hand: strptime follows the caller's setlocale()."""
    lstart = _darwin_ps(pid, "lstart")
    match = _LSTART_RE.fullmatch(lstart)
    if not match or match.group(1) not in _MONTHS:
        raise IdentityUnknown(f"unparsable lstart {lstart!r}")
    month, day, hour, minute, second, year = match.groups()
    return calendar.timegm((int(year), _MONTHS[month], int(day), int(hour), int(minute), int(second), 0, 0, 0))


def _system() -> str:
    return platform.system()


def process_identity(pid: int) -> str:
    """Identity of a live pid; raises ProcessAbsent or IdentityUnknown."""
    if not 0 < pid <= _PID_MAX:
        raise IdentityUnknown(f"invalid pid {pid}")
    system = _system()
    if system == "Linux":
        fields = _linux_stat_fields(pid)
        boot, pidns = _linux_boot_id(), _linux_self_pidns()
        if not re.fullmatch(r"[0-9a-f-]+", boot) or not pidns:
            raise IdentityUnknown("boot_id or pid namespace unreadable")
        return f"linux:{boot}:{pidns}:{pid}:{fields[19]}"
    if system == "Darwin":
        _darwin_exists(pid)
        epoch = _darwin_start_epoch(pid)
        boot = _darwin_boot_id()
        if not re.fullmatch(r"[0-9A-F-]+", boot):
            raise IdentityUnknown("kern.bootsessionuuid unreadable")
        return f"darwin:{boot}:{pid}:{epoch}"
    raise IdentityUnknown(f"unsupported platform {system}")


def _zombie_state(pid: int) -> str:
    """'dead' for a zombie without live threads, 'alive' if not a zombie, else unknown."""
    try:
        if _system() == "Linux":
            if _linux_stat_fields(pid)[0] != "Z":
                return "alive"
            threads = re.search(r"^Threads:\s*([0-9]+)$", _read(f"/proc/{pid}/status"), re.MULTILINE)
            return DEAD if threads and int(threads.group(1)) <= 1 else UNKNOWN
        if _system() == "Darwin":
            return DEAD if "Z" in _darwin_ps(pid, "stat") else "alive"
    except (ProcessAbsent, IdentityUnknown, OSError):
        return UNKNOWN
    return UNKNOWN


def _parse_recorded(recorded: str) -> tuple[str, str, str, int, str] | None:
    """(platform, boot, pidns or '', pid, start) or None when malformed."""
    linux = _LINUX_RE.fullmatch(recorded)
    if linux:
        boot, pidns, rpid, start = linux.groups()
        kind = "linux"
    else:
        darwin = _DARWIN_RE.fullmatch(recorded)
        if not darwin:
            return None
        boot, rpid, start = darwin.groups()
        pidns, kind = "", "darwin"
    if not _valid_pid_text(rpid):
        return None
    return kind, boot, pidns, int(rpid), start


def verdict(recorded: str, pid: int) -> str:
    """match, dead (proven) or unknown. Unknown must never authorise or release."""
    parsed = _parse_recorded(recorded)
    if parsed is None or not 0 < pid <= _PID_MAX:
        return UNKNOWN
    kind, boot, pidns, rpid, start = parsed
    if rpid != pid:
        return UNKNOWN
    system = _system()
    if (kind, system) not in (("linux", "Linux"), ("darwin", "Darwin")):
        return UNKNOWN
    here_boot = _linux_boot_id() if kind == "linux" else _darwin_boot_id()
    boot_re = r"[0-9a-f-]+" if kind == "linux" else r"[0-9A-F-]+"
    if not re.fullmatch(boot_re, here_boot):
        return UNKNOWN
    if boot != here_boot:
        return DEAD
    if kind == "linux":
        here_ns = _linux_self_pidns()
        if not here_ns or pidns != here_ns:
            return UNKNOWN
    try:
        current = process_identity(pid)
    except ProcessAbsent:
        return DEAD
    except IdentityUnknown:
        return UNKNOWN
    zombie = _zombie_state(pid)
    if zombie != "alive":
        return zombie
    return MATCH if current.rsplit(":", 1)[1] == start else DEAD


def _main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "identity":
        if not _valid_pid_text(argv[1]):
            return 2
        try:
            print(process_identity(int(argv[1])))
        except ProcessAbsent:
            return 1
        except IdentityUnknown as exc:
            print(f"process_identity: {exc}", file=sys.stderr)
            return 2
        return 0
    if len(argv) == 3 and argv[0] == "verdict":
        print(verdict(argv[1], int(argv[2]) if _valid_pid_text(argv[2]) else -1))
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
