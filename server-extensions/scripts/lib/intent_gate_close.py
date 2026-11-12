#!/usr/bin/env python3
"""Intent gate at session close: resolve the batch, retry the rest, log what lapses.

WP-484 И-13 (peer session 2026-11-12-07-wp484-intent-batch-resolve). One
``intent-gate.sh resolve-batch`` call resolves the closing session's intents
together with leftovers of earlier closes on this host. Everything runs under
one host-wide ``flock`` on ``<dir>/resolve.lock``: the kernel drops it when the
holder dies, so a lock is never broken by hand.

Files in ``<dir>`` (``.iwe-runtime/intent-gate``):
  ``<sem>.intents``             claims of an open session (``<id> <agent> <target>``),
                                appended by session-guard.sh note-file;
  ``<sem>.intents.closing.<pid>.<uuid>`` a file taken by a close: renamed before it is
                                read, so a late append goes to a new file;
  ``<sem>.intents.retry``       leftovers: ``<id> <agent> - <attempts> <reason> <first_seen>``.

Every intent goes to the gate with wp ``-``: resolve-batch uses the declared wp
and still checks the agent. The semaphore's wp is not used, because one
conversation can run sessions on different WPs under the same file name.

A source is removed only after the leftovers are published to the retry file
of this close. Damage bound: an unresolved intent only matters to ``check`` of
other agents, which reads the ledger of today and yesterday, so a source older
than ``--max-age`` lapses with a log row per intent; age counts from when the
intent was first seen (the source's mtime, carried in the retry line). Retrying
needs a later close on this host; there is no other trigger. Known residual: a
bash ``>>`` append that opened the own file just before the close renamed it
writes into the taken file after it was read -- a microsecond window that also
needs the semaphore removed at that moment; such a line is lost without a row.

Prints log rows ``<kind>\\t<detail>`` (``retry_item``, ``lapsed``,
``retry_deferred``) and a last ``summary`` row; session-guard.sh writes them to
the gate log.
"""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

# A refusal that a retry cannot change lapses at once.
PERMANENT_REFUSALS = {"owner_mismatch", "wp_mismatch", "malformed"}
# A not_found may be a declaration not yet visible; it gets one more try.
NOT_FOUND_ATTEMPTS = 2
NO_VERDICT_REASON = {124: "timeout", 127: "gate_missing", 4: "origin_unreachable", 3: "ledger_unreadable"}


def take_lock(path, wait_sec):
    """Return an fd holding an exclusive flock on ``path``, or None after ``wait_sec``."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    deadline = time.monotonic() + wait_sec
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.2)


def take_sources(directory, own, sessions_dir):
    """Rename the files this close will read; return their paths.

    The own intents file and orphans (their semaphore is gone) are renamed to a
    unique ``.closing.<pid>.<uuid>`` name first: an append that raced the close
    lands in a new ``.intents`` file instead of one about to be removed.
    """
    def rename(path):
        # A random suffix, and a check: a dead close may have left a .closing
        # file under a name this process could reproduce (a reused pid). Only
        # the flock holder renames into .closing names, so check-then-rename
        # does not race.
        while True:
            target = Path(f"{path}.closing.{os.getpid()}.{uuid.uuid4().hex}")
            if not target.exists():
                break
        try:
            os.rename(path, target)
        except FileNotFoundError:
            return None
        return target

    to_take = [own] if own.is_file() else []
    to_take += [p for p in sorted(directory.glob("*.intents"))
                if p != own and p.is_file() and not (sessions_dir / p.name[: -len(".intents")]).exists()]
    sources = [t for t in map(rename, to_take) if t]
    taken = set(sources)
    # Files taken by an earlier close that died before removing them.
    sources += [p for p in sorted(directory.glob("*.intents.closing.*")) if p.is_file() and p not in taken]
    sources += [p for p in sorted(directory.glob("*.intents.retry")) if p.is_file()]
    return sources


def _int(text, default):
    return int(text) if text.isdigit() else default


def read_entries(sources, now, max_age):
    """Merge the sources by intent_id; return (entries, lapsed, unreadable).

    An unreadable source is reported and kept in place, never removed; one bad
    file must not stop the rest of the host's intents.
    """
    entries, lapsed, unreadable = {}, [], []
    for path in sources:
        try:
            mtime = int(path.stat().st_mtime)
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except FileNotFoundError:
            continue
        except OSError as exc:
            unreadable.append((path, exc))
            continue
        retry = path.name.endswith(".retry")
        for line in lines:
            fields = line.split()
            if len(fields) < 2:
                continue
            rec = {"agent": fields[1], "attempts": 0, "reason": "expired", "first_seen": mtime}
            if retry:
                rec["attempts"] = _int(fields[3], 0) if len(fields) > 3 else 0
                rec["reason"] = fields[4] if len(fields) > 4 else "unknown"
                rec["first_seen"] = _int(fields[5], mtime) if len(fields) > 5 else mtime
            known = entries.get(fields[0])
            if known is None:
                entries[fields[0]] = rec
            else:
                # One intent in two files: a crash between publishing a retry
                # file and removing its sources.
                known["attempts"] = max(known["attempts"], rec["attempts"])
                known["first_seen"] = min(known["first_seen"], rec["first_seen"])
    for intent_id in [i for i, r in entries.items() if now - r["first_seen"] > max_age]:
        rec = entries.pop(intent_id)
        lapsed.append((intent_id, rec, rec["reason"]))
    return entries, lapsed, unreadable


def run_batch(gate, entries, budget):
    """Run resolve-batch; return (exit code, {intent_id: (verb, detail)})."""
    if not entries:
        return 0, {}
    if not Path(gate).is_file():
        return 127, {}
    batch = "".join(f"{i} {r['agent']} -\n" for i, r in entries.items())
    proc = subprocess.Popen(
        ["bash", gate, "resolve-batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, start_new_session=True,
    )
    try:
        out, _ = proc.communicate(batch, timeout=budget)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        # The whole group (git fetch and the ledger writer run as children):
        # TERM first so a writer can finish its atomic replace, then KILL.
        for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, None)):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            try:
                proc.wait(timeout=grace)
                break
            except subprocess.TimeoutExpired:
                continue
        out, _ = proc.communicate()
        rc = 124
    verdicts = {}
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] != "-":
            verdicts[fields[1]] = (fields[0], fields[2] if len(fields) > 2 else "")
    return rc, verdicts


def settle(entries, lapsed, verdicts, rc):
    """Sort entries by verdict; return (retry lines, log rows, counts)."""
    no_verdict = NO_VERDICT_REASON.get(rc, f"no_verdict_rc{rc}")
    counts = {"resolved": 0, "already": 0, "retry": 0, "lapsed": 0}
    retry_lines, rows = [], []

    def lapse(intent_id, rec, reason):
        counts["lapsed"] += 1
        rows.append(f"lapsed\t{intent_id} {rec['agent']} attempts={rec['attempts']} reason={reason}")

    for intent_id, rec, reason in lapsed:
        lapse(intent_id, rec, reason)
    for intent_id, rec in entries.items():
        verb, detail = verdicts.get(intent_id, (None, ""))
        if verb in ("resolved", "already"):
            counts[verb] += 1
            continue
        rec["attempts"] += 1
        if verb == "refused" and (
            detail in PERMANENT_REFUSALS or (detail == "not_found" and rec["attempts"] >= NOT_FOUND_ATTEMPTS)
        ):
            lapse(intent_id, rec, detail)
            continue
        reason = detail if verb == "refused" else (verb or no_verdict)
        counts["retry"] += 1
        retry_lines.append(f"{intent_id} {rec['agent']} - {rec['attempts']} {reason} {rec['first_seen']}")
        rows.append(f"retry_item\t{intent_id} {rec['agent']} attempts={rec['attempts']} reason={reason}")
    return retry_lines, rows, counts


def publish_retry(retry_out, retry_lines):
    """Atomically replace this close's retry file; remove it when nothing is left."""
    if not retry_lines:
        retry_out.unlink(missing_ok=True)
        return
    tmp = retry_out.with_name(f"{retry_out.name}.tmp.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(retry_lines) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, retry_out)


def run(args):
    directory = Path(args.dir)
    own = Path(args.own)
    directory.mkdir(parents=True, exist_ok=True)
    lock_fd = take_lock(directory / "resolve.lock", args.lock_wait)
    if lock_fd is None:
        # Nothing taken: the own file stays and becomes an orphan for a later
        # close on this host. A record of the skip, not a retry.
        print(f"retry_deferred\tlock busy for {args.lock_wait}s")
        return 0
    try:
        started = time.monotonic()
        # Temp files of a retry publish that crashed before its rename.
        for stale in directory.glob("*.intents.retry.tmp.*"):
            stale.unlink(missing_ok=True)
        sources = take_sources(directory, own, Path(args.sessions_dir))
        if not sources:
            return 0
        entries, lapsed, unreadable = read_entries(sources, time.time(), args.max_age)
        rc, verdicts = run_batch(args.gate, entries, args.budget)
        retry_lines, rows, counts = settle(entries, lapsed, verdicts, rc)
        rows += [f"source_unreadable\t{path.name} {type(exc).__name__}" for path, exc in unreadable]
        retry_out = Path(f"{own}.retry")
        publish_retry(retry_out, retry_lines)
        # The leftovers are published; only now the sources go -- never the
        # retry file just written, never a source that could not be read.
        keep = {retry_out} | {path for path, _ in unreadable}
        for path in sources:
            if path not in keep:
                path.unlink(missing_ok=True)
        for row in rows:
            print(row)
        print(
            f"summary\trc={rc} dur_s={round(time.monotonic() - started)} sources={len(sources)} "
            + " ".join(f"{k}={v}" for k, v in counts.items())
        )
        return 0
    finally:
        os.close(lock_fd)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", required=True)
    parser.add_argument("--own", required=True, help="the closing session's .intents path")
    parser.add_argument("--sessions-dir", required=True)
    parser.add_argument("--gate", required=True)
    parser.add_argument("--budget", type=float, required=True)
    parser.add_argument("--lock-wait", type=float, required=True)
    parser.add_argument("--max-age", type=float, required=True)
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
