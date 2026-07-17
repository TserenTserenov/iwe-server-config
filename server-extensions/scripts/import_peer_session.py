#!/usr/bin/env python3
"""
WP-295 F2 Import component: import peer-session Markdown files into agent_trace.

Reads sessions/<YYYY-MM>/<SESSION-ID>/ directories and inserts:
  - agent_trace.session  (one row per session)
  - agent_trace.decision (one row per turn file: NN-writer.md, NN-peer.md)
  - agent_trace.hypothesis (from report.md §3 "Отвергнутые альтернативы", if present)

Corpus tags (migration 266-wp295-f2-decision-source.sql):
  source       = 'peer-session-import'
  attributed_to = 'consensus'   (decisions from peer dialogue, not autonomous agent)

Pattern miner F4 filters WHERE source='realtime' by default — these imports
form the separate 'collaborative-patterns' corpus.

Usage:
  python3 import_peer_session.py <session-dir>            # import one session
  python3 import_peer_session.py --all <sessions-root>    # import all completed sessions
  python3 import_peer_session.py --dry-run <session-dir>  # preview without DB writes

Requires: AGENT_TRACE_WRITER_URL env var.
Load: source ~/.secrets/neon

see DP.SC.038 (replay), SC.038.1 (corpus for replay with historical decisions).
"""

import argparse
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

try:
    import psycopg
    import psycopg.rows
except ImportError:
    psycopg = None

try:
    import yaml
except ImportError:
    yaml = None


# ── DB ────────────────────────────────────────────────────────────────────────

def get_conn():
    import os
    url = os.environ.get("AGENT_TRACE_WRITER_URL") or os.environ.get("AGENT_TRACE_READER_URL")
    if not url:
        sys.exit("AGENT_TRACE_WRITER_URL not set. Run: source ~/.secrets/neon")
    if psycopg is None:
        sys.exit("psycopg not installed. Run: pip install psycopg[binary]")
    return psycopg.connect(url, row_factory=psycopg.rows.dict_row)


# ── frontmatter parser ────────────────────────────────────────────────────────

def parse_frontmatter(text: str) -> tuple[dict, str]:
    """
    Extract YAML frontmatter from Markdown.

    Returns (frontmatter_dict, body).  Lenient: returns ({}, text) on any parse
    failure so early sessions without well-formed frontmatter are not silently dropped.
    """
    if not text.startswith("---"):
        return {}, text

    end = text.find("\n---", 3)
    if end == -1:
        return {}, text

    fm_raw = text[3:end].strip()
    body = text[end + 4:].lstrip("\n")

    if yaml is not None:
        try:
            fm = yaml.safe_load(fm_raw) or {}
            return fm, body
        except yaml.YAMLError:
            pass

    # Fallback: line-by-line key: value (covers sessions before 2026-05 without full YAML)
    fm: dict = {}
    for line in fm_raw.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip().strip('"').strip("'")
    return fm, body


# ── session loader ────────────────────────────────────────────────────────────

def load_session(session_dir: Path) -> dict | None:
    """
    Parse a peer-session directory into a dict ready for DB insertion.

    Returns None if the session should be skipped (e.g. status != completed).
    """
    meta_path = session_dir / "meta.yaml"
    if not meta_path.exists():
        return None

    meta_text = meta_path.read_text(encoding="utf-8")
    meta, _ = parse_frontmatter("---\n" + meta_text)  # meta.yaml has no --- delimiters

    status = str(meta.get("status", "")).strip('"').strip("'")
    if status not in ("completed", "done"):
        return None

    session_id_str = str(meta.get("session_id", session_dir.name)).strip('"').strip("'")

    # Use a deterministic UUID derived from session_id string so re-imports are idempotent
    stable_uuid = uuid.uuid5(uuid.NAMESPACE_URL, f"peer-session:{session_id_str}")

    started_at = _parse_ts(meta.get("start_time") or meta.get("date"))
    ended_at = _parse_ts(meta.get("end_time"))

    writer_agent = str(meta.get("writer_agent", "kimi-headless")).strip('"').strip("'")
    wp_id = str(meta.get("task_id", "")).strip('"').strip("'") or None
    task_desc = str(meta.get("task_description", "")).strip('"').strip("'")

    turns = _load_turns(session_dir)
    hypotheses = _extract_hypotheses_from_report(session_dir)

    return {
        "session_id": stable_uuid,
        "agent_id": writer_agent,
        "started_at": started_at,
        "ended_at": ended_at,
        "context_summary": f"peer-session:{session_id_str} | {task_desc}"[:500],
        "wp_id": wp_id,
        "source_session_id": session_id_str,
        "turns": turns,
        "hypotheses_by_turn": hypotheses,
    }


def _parse_ts(value) -> datetime:
    if value is None:
        return datetime.now(timezone.utc)
    s = str(value).strip('"').strip("'")
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(s, fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return datetime.now(timezone.utc)


def _load_turns(session_dir: Path) -> list[dict]:
    """Load all NN-writer.md / NN-peer.md turn files as decision candidates."""
    turn_files = sorted(session_dir.glob("[0-9][0-9]-*.md"))
    turns = []
    for tf in turn_files:
        text = tf.read_text(encoding="utf-8")
        fm, body = parse_frontmatter(text)

        turn_num = int(tf.name[:2])
        role = str(fm.get("role", "unknown")).strip('"').strip("'")
        agent_id = str(fm.get("agent_id", "unknown")).strip('"').strip("'")
        ts = _parse_ts(fm.get("timestamp"))
        consensus_val = str(fm.get("consensus", "none")).strip('"').strip("'")

        # Decision text: first non-empty heading or first 200 chars of body
        decision_text = _extract_decision_text(body, tf.name)
        # Chosen hypothesis: body summary (first paragraph after any heading)
        chosen = _extract_chosen(body)

        turns.append({
            "turn": turn_num,
            "role": role,
            "agent_id": agent_id,
            "decided_at": ts,
            "decision_text": decision_text[:1000],
            "chosen_hypothesis": chosen[:500],
            "rationale": body[:300],
            "consensus": consensus_val,
            "filename": tf.name,
        })

    return turns


def _extract_decision_text(body: str, filename: str) -> str:
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("#"):
            return re.sub(r"^#+\s*", "", line)[:200]
    # No heading — use filename as fallback label
    first_para = body.strip().split("\n\n")[0].replace("\n", " ").strip()
    if first_para:
        return first_para[:200]
    return filename


def _extract_chosen(body: str) -> str:
    """First substantive paragraph after headings as the 'chosen' summary."""
    in_content = False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            in_content = True
            continue
        if in_content and stripped:
            return stripped[:300]
        if not stripped:
            continue
        return stripped[:300]
    return body.strip()[:300] or "(no content)"


def _extract_hypotheses_from_report(session_dir: Path) -> dict[int, list[str]]:
    """
    Parse report.md §3 'Отвергнутые альтернативы' for rejected hypotheses.

    Returns {turn_number: [rejected_text, ...]}.
    Lenient: returns {} if report.md missing or section absent.
    """
    report = session_dir / "report.md"
    if not report.exists():
        return {}

    text = report.read_text(encoding="utf-8")
    # Find the section — may be Russian or English heading
    section_pat = re.compile(
        r"(?:##\s*(?:3\.\s*)?(?:Отвергнутые|Rejected|Альтернативы|Alternatives)[^\n]*\n)"
        r"(.*?)(?=\n##|\Z)",
        re.DOTALL | re.IGNORECASE,
    )
    m = section_pat.search(text)
    if not m:
        return {}

    section_body = m.group(1)
    # Bullet items as rejected hypotheses; assign to turn 0 (session-level)
    items = re.findall(r"^[-*]\s+(.+)$", section_body, re.MULTILINE)
    if not items:
        return {}

    return {0: [item.strip()[:300] for item in items]}


# ── DB writer ─────────────────────────────────────────────────────────────────

def insert_session(conn, sess: dict, dry_run: bool) -> int:
    """
    Insert session + decisions + hypotheses.  Returns number of decisions inserted.
    Uses ON CONFLICT DO NOTHING for idempotency (re-import safe).
    """
    sid = sess["session_id"]
    turns = sess["turns"]

    if dry_run:
        print(f"  [DRY RUN] session {sid} ({sess['source_session_id']})")
        print(f"    agent={sess['agent_id']}  wp={sess['wp_id']}  turns={len(turns)}")
        for t in turns:
            print(f"    turn #{t['turn']} [{t['role']}]: {t['decision_text'][:80]}")
        return len(turns)

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO agent_trace.session
                (session_id, agent_id, started_at, ended_at, context_summary,
                 wp_id, closed_status)
            VALUES (%s, %s, %s, %s, %s, %s, 'completed')
            ON CONFLICT (session_id) DO NOTHING
            """,
            (
                str(sid),
                sess["agent_id"],
                sess["started_at"],
                sess["ended_at"],
                sess["context_summary"],
                sess["wp_id"],
            ),
        )

        inserted = 0
        hyp_map = sess["hypotheses_by_turn"]

        for t in turns:
            cur.execute(
                """
                INSERT INTO agent_trace.decision
                    (session_id, agent_id, sequence, decided_at,
                     decision_text, chosen_hypothesis, rationale,
                     refs, nondeterminism, pii_masked,
                     source, attributed_to)
                VALUES (%s, %s, %s, %s, %s, %s, %s,
                        '[]'::jsonb,
                        '{"model":"peer-session-import","temperature":null}'::jsonb,
                        false,
                        'peer-session-import', 'consensus')
                ON CONFLICT (session_id, sequence) DO NOTHING
                RETURNING id
                """,
                (
                    str(sid),
                    t["agent_id"],
                    t["turn"],
                    t["decided_at"],
                    t["decision_text"],
                    t["chosen_hypothesis"],
                    t["rationale"][:500],
                ),
            )
            row = cur.fetchone()
            if row is None:
                continue  # already existed

            decision_id = row["id"]
            inserted += 1

            # Insert rejected hypotheses for this turn if available
            rejected = hyp_map.get(t["turn"], hyp_map.get(0, []))
            for hyp_text in rejected:
                cur.execute(
                    """
                    INSERT INTO agent_trace.hypothesis
                        (decision_id, hypothesis_text, status, rejection_reason)
                    VALUES (%s, %s, 'rejected', 'rejected in peer dialogue')
                    ON CONFLICT DO NOTHING
                    """,
                    (decision_id, hyp_text),
                )

    conn.commit()
    return inserted


# ── CLI ───────────────────────────────────────────────────────────────────────

def import_one(session_dir: Path, dry_run: bool, conn) -> tuple[int, int]:
    """Import a single session. Returns (decisions_inserted, skipped)."""
    sess = load_session(session_dir)
    if sess is None:
        return 0, 1

    n = insert_session(conn, sess, dry_run)
    return n, 0


def main():
    parser = argparse.ArgumentParser(
        prog="import_peer_session",
        description="Import peer-session Markdown files into agent_trace (WP-295 F2)",
    )
    parser.add_argument("path", help="session directory or sessions root (with --all)")
    parser.add_argument("--all", action="store_true",
                        help="import all completed sessions under path")
    parser.add_argument("--dry-run", action="store_true",
                        help="preview without DB writes")

    args = parser.parse_args()
    root = Path(args.path).expanduser()

    if not root.exists():
        sys.exit(f"Path not found: {root}")

    conn = None if args.dry_run else get_conn()

    total_decisions = 0
    total_skipped = 0

    if args.all:
        # Recurse: sessions/<YYYY-MM>/<SESSION-ID>/
        session_dirs = sorted(
            d for d in root.rglob("meta.yaml")
            if (d.parent / "00-writer.md").exists()
        )
        session_dirs = [d.parent for d in session_dirs]
        print(f"Found {len(session_dirs)} session directories under {root}")
        for sd in session_dirs:
            n, s = import_one(sd, args.dry_run, conn)
            total_decisions += n
            total_skipped += s
            if n > 0:
                print(f"  imported {n} decisions from {sd.name}")
            elif s:
                print(f"  skipped {sd.name} (not completed)")
    else:
        n, s = import_one(root, args.dry_run, conn)
        total_decisions += n
        total_skipped += s

    if args.dry_run:
        print(f"\n[DRY RUN] would import {total_decisions} decisions, skip {total_skipped} sessions.")
    else:
        print(f"\nDone: {total_decisions} decisions imported, {total_skipped} sessions skipped.")
        if conn:
            conn.close()


if __name__ == "__main__":
    main()
