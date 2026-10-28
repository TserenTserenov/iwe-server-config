#!/usr/bin/env python3
"""Read-only scan: for a given WP, which recent session folders/semaphores
exist and whether their journal (report.md) was ever finalized.

Primary join key is the `file:` lines inside a session-guard semaphore, not
its `slug:` -- a semaphore's slug can be a harness placeholder (`placeholder`,
`placeholder2`, ...) shared by several unrelated peer-session folders opened
in the same chat session (found live on WP-484, 2026-10-15, peer-session
2026-10-15-33-wp484-session-handoff-gap). Only the `file:` lines reliably
name the actual MC-sessions folder.

Stdlib only (no PyYAML) -- see scripts/lib/find-python3.sh --stdlib-only.
"""
import argparse
import datetime
import os
import re
import sys

FILE_LINE_RE = re.compile(r"^(\d{4}-\d{2}/\d{2}/[^/]+)/")
# Quick Close sessions leave no folder, only a flat ORZ file <YYYY-MM>/<name>.md (WP-484 F257 M4a).
FLAT_ORZ_RE = re.compile(r"^\d{4}-\d{2}/[^/]+\.md$")
FLAT_FINAL = "ОРЗ-файл есть (Quick Close)"
FLAT_SCAFFOLD = "ОРЗ-заготовка не заполнена"
FLAT_MISSING = "ОРЗ-файл не читается"


def classify_semaphore(name: str) -> str | None:
    if ".orphaned-" in name:
        return "orphaned"
    if ".closed" in name:
        return "closed"
    if name.endswith(".open"):
        return "open"
    return None  # noise: .lease, .ptr, backup-before-manual-close-*, etc.


def semaphore_mentions_wp(path: str, wp: str) -> bool:
    # Cheap pre-filter: avoid building the full `file:`-line list for every
    # semaphore on disk when only one WP is being scanned (found slow on a
    # real host with 1700+ semaphores -- see cold review of this script).
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return any(line.strip() == f"wp: {wp}" for line in f)
    except OSError:
        return False


def parse_semaphore(path: str) -> dict:
    fields: dict = {"file": []}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("file: "):
                    fields["file"].append(line[len("file: "):].strip())
                elif ":" in line:
                    key, _, value = line.partition(":")
                    key = key.strip()
                    if key and key not in fields:
                        fields[key] = value.strip()
    except OSError:
        pass
    return fields


def resolve_peer_folders(fields: dict, sessions_dir: str) -> list[str]:
    # A single semaphore can carry `file:` lines for MORE THAN ONE
    # peer-session folder -- found live on WP-484: one harness session
    # opened three consecutive peer-conversation folders under the same
    # semaphore with slug placeholders (`placeholder`, `placeholder2`,
    # `placeholder3`). Returning only the first match (the original version
    # of this function did) silently drops every folder after it.
    seen: dict[str, None] = {}  # insertion-ordered set
    for file_line in fields.get("file", []):
        m = FILE_LINE_RE.match(file_line)
        if m:
            candidate = m.group(1)
            if candidate not in seen and os.path.isdir(os.path.join(sessions_dir, candidate)):
                seen[candidate] = None
    if seen:
        return list(seen)
    slug = fields.get("slug")
    opened_at = fields.get("opened_at") or fields.get("created_at")
    if slug and opened_at and len(opened_at) >= 10:
        month, day = opened_at[0:7], opened_at[8:10]
        candidate = f"{month}/{day}/{slug}"
        if os.path.isdir(os.path.join(sessions_dir, candidate)):
            return [candidate]
    return []


def resolve_flat_orz(fields: dict, sessions_dir: str) -> list[str]:
    """Flat ORZ file named by the semaphore's `orz_file:` for a session without a folder.

    A missing file is still returned (reported as absent), so a session that opened
    but never wrote its ORZ file is not invisible.
    """
    orz = fields.get("orz_file", "")
    if not FLAT_ORZ_RE.match(orz) or ".." in orz.split("/"):
        return []
    return [orz]


def flat_orz_candidates(slug: str, ts: str) -> list[str]:
    """Flat ORZ paths a closed session with this slug may have left (month taken from the event)."""
    if not slug or len(ts) < 10 or "/" in slug or ".." in slug:
        return []
    month, day = ts[0:7], ts[0:10]
    return [f"{month}/{slug}.md", f"{month}/{day}-{slug}.md"]


def report_status(folder_path: str) -> str:
    if os.path.isfile(folder_path):
        # `open` writes a scaffold with `duration_h: ~`; a closed session replaces it.
        try:
            with open(folder_path, encoding="utf-8", errors="replace") as handle:
                head = handle.read(4000)
        except OSError:
            return FLAT_MISSING
        if re.search(r"^duration_h:\s*~\s*$", head, flags=re.MULTILINE):
            return FLAT_SCAFFOLD
        return FLAT_FINAL
    if os.path.isfile(os.path.join(folder_path, "report.md")):
        return "report.md есть"
    if os.path.isfile(os.path.join(folder_path, "report-draft.md")):
        return "черновик (report-draft.md), финал не записан"
    meta_path = os.path.join(folder_path, "meta.yaml")
    if os.path.isfile(meta_path):
        with open(meta_path, encoding="utf-8", errors="replace") as f:
            meta_text = f.read()
        if 'status: "completed"' in meta_text or "status: completed" in meta_text:
            return "отчёта нет, но meta.yaml помечен completed (несогласованность)"
    return "отчёта НЕТ"


def scan_semaphores(wp: str, sem_dir: str, sessions_dir: str, exclude_session_id: str | None, cutoff: str):
    found = {}  # folder_rel_path -> entry dict
    if not os.path.isdir(sem_dir):
        return found
    for name in os.listdir(sem_dir):
        full = os.path.join(sem_dir, name)
        if not os.path.isfile(full):
            continue
        status = classify_semaphore(name)
        if status is None:
            continue
        if not semaphore_mentions_wp(full, wp):
            continue
        fields = parse_semaphore(full)
        if fields.get("wp") != wp:
            continue  # substring matched but not as the wp: field itself (e.g. inside a file: path)
        session_id = fields.get("session_id")
        if exclude_session_id and session_id == exclude_session_id:
            continue
        opened_at = fields.get("opened_at") or fields.get("created_at") or ""
        if opened_at and opened_at < cutoff:
            continue  # outside the reporting window -- an old unresolved gap belongs to Day/Week Close triage, not here
        # A session with a folder is listed by the folder (its ORZ file is the same session);
        # only a folderless Quick Close session falls back to the flat ORZ file.
        folders = resolve_peer_folders(fields, sessions_dir) or resolve_flat_orz(fields, sessions_dir)
        for folder in folders:
            existing = found.get(folder)
            if existing is None or opened_at > existing.get("opened_at", ""):
                found[folder] = {"status": status, "opened_at": opened_at, "source": "semaphore"}
    return found


def scan_ledger(wp: str, ledger_dir: str, sessions_dir: str, days: int = 7):
    found = {}
    if not os.path.isdir(ledger_dir):
        return found
    # day/<YYYY>/<MM>/day-<YYYY-MM-DD>.yaml, newest `days` files by name.
    day_files = []
    for year_name in os.listdir(ledger_dir):
        year_dir = os.path.join(ledger_dir, year_name)
        if not os.path.isdir(year_dir):
            continue
        for month_name in os.listdir(year_dir):
            month_dir = os.path.join(year_dir, month_name)
            if not os.path.isdir(month_dir):
                continue
            for fname in os.listdir(month_dir):
                if fname.startswith("day-") and fname.endswith(".yaml"):
                    day_files.append(os.path.join(month_dir, fname))
    day_files.sort(reverse=True)
    # `kind` worth matching against the WP -- both the peer-conversation
    # path (session_closed_direct) and the plain runner close path
    # (session_closed) carry a `slug`, though session_closed's slug is often
    # empty for Quick-Close-style closes (no peer-session folder involved);
    # an empty slug is filtered out below, same as a missing one.
    CLOSE_KINDS = ("session_closed_direct", "session_closed")
    for path in day_files[:days]:
        kind = None
        data: dict = {}
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in lines + ["- ts: __eof__\n"]:
            stripped = line.strip()
            if stripped.startswith("- ts:"):
                # Flush the PREVIOUS event (its `ts` was captured when ITS
                # "- ts:" line was seen, one iteration ago -- the entry
                # marker and the timestamp value are on the same line, so
                # capturing `ts` only from a bare "ts:" line (as the first
                # version of this parser did) never captured anything: that
                # line never occurs in this ledger format).
                if kind in CLOSE_KINDS and data.get("wp") == wp and data.get("slug"):
                    slug = data["slug"]
                    ts = data.get("ts", "")
                    for flat in flat_orz_candidates(slug, ts):
                        if os.path.isfile(os.path.join(sessions_dir, flat)) and flat not in found:
                            found[flat] = {"status": "closed (ledger)", "opened_at": ts, "source": "ledger"}
                    for month_dirname in os.listdir(sessions_dir) if os.path.isdir(sessions_dir) else []:
                        candidate_root = os.path.join(sessions_dir, month_dirname)
                        if not os.path.isdir(candidate_root):
                            continue
                        for day_dirname in os.listdir(candidate_root):
                            candidate = f"{month_dirname}/{day_dirname}/{slug}"
                            if os.path.isdir(os.path.join(sessions_dir, candidate)):
                                existing = found.get(candidate)
                                if existing is None:
                                    found[candidate] = {"status": "closed (ledger)", "opened_at": ts, "source": "ledger"}
                # Start the NEW event: its ts is embedded in this very line.
                kind, data = None, {"ts": stripped[len("- ts:"):].strip().strip("'\"")}
                continue
            if stripped.startswith("kind:"):
                kind = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("wp:"):
                data["wp"] = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("slug:"):
                data["slug"] = stripped.split(":", 1)[1].strip().strip("'\"")
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wp", required=True)
    ap.add_argument("--sessions-dir", required=True)
    ap.add_argument("--sem-dir", required=True)
    ap.add_argument("--ledger-dir", required=True)
    ap.add_argument("--exclude-session-id", default=None)
    ap.add_argument("--window-days", type=int, default=7)
    args = ap.parse_args()

    cutoff = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=args.window_days)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")

    combined = scan_semaphores(args.wp, args.sem_dir, args.sessions_dir, args.exclude_session_id, cutoff)
    for folder, entry in scan_ledger(args.wp, args.ledger_dir, args.sessions_dir, days=args.window_days).items():
        combined.setdefault(folder, entry)

    if not combined:
        return 0

    all_rows = [
        (folder, entry, report_status(os.path.join(args.sessions_dir, folder)))
        for folder, entry in combined.items()
    ]
    all_rows.sort(key=lambda r: r[1].get("opened_at", ""))

    # Always show the latest session of this WP, whatever its report status --
    # a session whose report.md IS finalized is exactly the reassurance the
    # next session should see, not noise to filter out (a prior version of
    # this scan hid every finalized-report row outright, which silently
    # defeated the one case the whole diagnosis started from: a closed
    # session whose report the next session simply never opened). Alongside
    # it, surface every OTHER session in the window that still has a real
    # gap (missing/draft report, or still open) -- that keeps a busy WP's
    # output from scrolling through its entire closed, reported history.
    latest = all_rows[-1]
    rows = [r for r in all_rows[:-1] if r[2] not in ("report.md есть", FLAT_FINAL) or r[1]["status"].split(" ")[0] == "open"]
    rows.append(latest)

    print(f"WP-SESSIONS {args.wp}: {len(rows)} сессия(й) за {args.window_days} дней (последняя + оставшиеся без финализированного отчёта/ещё открытые)")
    for folder, entry, rep in rows:
        status_label = {"open": "[открыта]", "closed": "[закрыта]", "orphaned": "[осиротел]"}.get(
            entry["status"].split(" ")[0], f"[{entry['status']}]"
        )
        when = entry.get("opened_at") or "?"
        print(f"  {status_label} {folder} ({when}) — {rep}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
