#!/usr/bin/env python3
"""
WP-295 Ф1+Ф2: CLI iwe trace — read, upload, and replay agent trace.

Commands:
  iwe-trace.py show   <session-id|last>
  iwe-trace.py search [--wp WP-N] [--date YYYY-MM-DD] [--agent X] [--limit N]
  iwe-trace.py upload <ndjson-file>
  iwe-trace.py tree   <session-id|last>
  iwe-trace.py replay <event-id> [--dry-run] [--fork] [--branch NAME]

Requires: AGENT_TRACE_READER_URL (show/search/tree/replay), AGENT_TRACE_GATEWAY (upload).
Load variables: source ~/.secrets/neon

see DP.SC.037 (agent-trace store), DP.SC.038 (replay), DP.ROLE.047 (Trace Recorder).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

try:
    import psycopg
    import psycopg.rows
except ImportError:
    psycopg = None

try:
    import iwe_replay
    _REPLAY_MODULE = True
except ImportError:
    _REPLAY_MODULE = False


# ── helpers ───────────────────────────────────────────────────────────────────

def get_conn():
    url = os.environ.get("AGENT_TRACE_READER_URL")
    if not url:
        sys.exit("AGENT_TRACE_READER_URL not set. Run: source ~/.secrets/neon")
    if psycopg is None:
        sys.exit("psycopg not installed. Run: pip install psycopg[binary]")
    return psycopg.connect(url, row_factory=psycopg.rows.dict_row)


def get_writer_conn():
    url = os.environ.get("AGENT_TRACE_WRITER_URL")
    if not url:
        sys.exit("AGENT_TRACE_WRITER_URL not set. Run: source ~/.secrets/neon")
    if psycopg is None:
        sys.exit("psycopg not installed. Run: pip install psycopg[binary]")
    return psycopg.connect(url, row_factory=psycopg.rows.dict_row)


def fmt_ts(ts):
    if ts is None:
        return "—"
    if hasattr(ts, "strftime"):
        return ts.strftime("%Y-%m-%d %H:%M:%S UTC")
    return str(ts)


def fmt_duration(start, end):
    if start is None or end is None:
        return "—"
    delta = end - start
    total = int(delta.total_seconds())
    if total < 60:
        return f"{total}s"
    return f"{total // 60}m{total % 60:02d}s"


# ── show ──────────────────────────────────────────────────────────────────────

def cmd_show(session_id_arg: str):
    with get_conn() as conn:
        with conn.cursor() as cur:
            if session_id_arg == "last":
                cur.execute(
                    "SELECT * FROM agent_trace.session ORDER BY started_at DESC LIMIT 1"
                )
            else:
                cur.execute(
                    "SELECT * FROM agent_trace.session WHERE session_id = %s",
                    (session_id_arg,),
                )
            row = cur.fetchone()

    if not row:
        sys.exit(f"Session not found: {session_id_arg}")

    sid = str(row["session_id"])
    print("\n" + "─" * 60)
    print(f"  Session: {sid}")
    print(f"  Agent:   {row['agent_id']}")
    print(f"  Started: {fmt_ts(row['started_at'])}")
    print(f"  Ended:   {fmt_ts(row['ended_at'])}")
    print(f"  Status:  {row['closed_status'] or '(open)'}")
    print(f"  Dur:     {fmt_duration(row['started_at'], row['ended_at'])}")
    if row["wp_id"]:
        print(f"  WP:      {row['wp_id']}")
    if row["context_summary"]:
        print(f"  Context: {row['context_summary']}")
    artifacts = row["produced_artifact_ids"] or []
    if artifacts:
        print(f"  Artifacts: {', '.join(artifacts)}")
    print("─" * 60)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT tool_name, called_at, response_size_bytes
                FROM agent_trace.tool_call
                WHERE session_id = %s
                ORDER BY called_at
                """,
                (sid,),
            )
            tool_calls = cur.fetchall()

            cur.execute(
                """
                SELECT d.sequence, d.decided_at, d.decision_text, d.chosen_hypothesis,
                       d.rationale,
                       array_agg(h.hypothesis_text ORDER BY h.id)
                           FILTER (WHERE h.id IS NOT NULL) AS hypotheses
                FROM agent_trace.decision d
                LEFT JOIN agent_trace.hypothesis h
                       ON h.decision_id = d.id AND h.status = 'rejected'
                WHERE d.session_id = %s
                GROUP BY d.id
                ORDER BY d.sequence
                """,
                (sid,),
            )
            decisions = cur.fetchall()

    if tool_calls:
        print(f"\n  Tool calls ({len(tool_calls)}):")
        for tc in tool_calls:
            ts = fmt_ts(tc["called_at"])
            print(f"    [{ts}] {tc['tool_name']}  ({tc['response_size_bytes']} bytes)")

    if decisions:
        print(f"\n  Decisions ({len(decisions)}):")
        for d in decisions:
            print(f"\n  #{d['sequence']} [{fmt_ts(d['decided_at'])}]")
            print(f"    {d['decision_text']}")
            print(f"    -> {d['chosen_hypothesis']}")
            if d["rationale"]:
                tail = "…" if len(d["rationale"]) > 120 else ""
                print(f"    rationale: {d['rationale'][:120]}{tail}")
            if d["hypotheses"]:
                print(f"    rejected:  {'; '.join(d['hypotheses'])}")

    print()


# ── search ────────────────────────────────────────────────────────────────────

def cmd_search(wp, date, agent, limit):
    clauses = []
    params = []

    if wp:
        clauses.append("s.wp_id = %s")
        params.append(wp)
    if date:
        clauses.append("s.started_at::date = %s")
        params.append(date)
    if agent:
        clauses.append("s.agent_id ILIKE %s")
        params.append(f"%{agent}%")

    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    params.append(limit)

    query = f"""
        SELECT s.session_id, s.agent_id, s.started_at, s.ended_at,
               s.closed_status, s.wp_id, s.context_summary,
               COUNT(DISTINCT tc.id) AS tool_calls,
               COUNT(DISTINCT d.id)  AS decisions
        FROM agent_trace.session s
        LEFT JOIN agent_trace.tool_call tc ON tc.session_id = s.session_id
        LEFT JOIN agent_trace.decision d  ON d.session_id  = s.session_id
        {where}
        GROUP BY s.session_id
        ORDER BY s.started_at DESC
        LIMIT %s
    """

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            rows = cur.fetchall()

    if not rows:
        print("No sessions found.")
        return

    col_w = 36
    header = (
        f"  {'session_id':<{col_w}}  {'started_at':<20}  {'status':<10}"
        f"  {'wp':<8}  {'tc':>3}  {'dec':>3}  context"
    )
    sep = (
        f"  {'─' * col_w}  {'─' * 20}  {'─' * 10}"
        f"  {'─' * 8}  {'─':>3}  {'─':>3}  {'─' * 30}"
    )
    print("\n" + header)
    print(sep)
    for r in rows:
        sid = str(r["session_id"])
        ts = fmt_ts(r["started_at"])[:19]
        status = r["closed_status"] or "(open)"
        wp_col = (r["wp_id"] or "")[:8]
        ctx = (r["context_summary"] or "")[:40]
        print(
            f"  {sid:<{col_w}}  {ts:<20}  {status:<10}"
            f"  {wp_col:<8}  {r['tool_calls']:>3}  {r['decisions']:>3}  {ctx}"
        )
    print(f"\n  {len(rows)} session(s) found.\n")


# ── upload ────────────────────────────────────────────────────────────────────

def cmd_upload(ndjson_path: str):
    path = Path(ndjson_path).expanduser()
    if not path.exists():
        sys.exit(f"File not found: {path}")

    endpoint = os.environ.get(
        "AGENT_TRACE_GATEWAY",
        "https://event-gateway.aisystant.workers.dev/events",
    )
    source_name = "agent-trace-recorder"
    session_uuid = path.stem  # filename without extension

    file_lines = [ln for ln in path.read_text().splitlines() if ln.strip()]
    sent = failed = 0

    for idx, line in enumerate(file_lines, 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as e:
            print(f"  line {idx}: JSON parse error — {e}", file=sys.stderr)
            failed += 1
            continue

        event_type = event.get("event_type", "")
        payload = event.get("payload", {})
        occurred_at = event.get("emitted_at", "")
        schema_version = event.get("schema_version", "v1")
        external_id = f"{session_uuid}-{idx}-{event_type}"

        body_str = json.dumps({
            "source": source_name,
            "external_id": external_id,
            "event_type": event_type,
            "schema_version": schema_version,
            "payload": payload,
            "occurred_at": occurred_at,
        })

        try:
            result = subprocess.run(
                ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST", endpoint,
                 "-H", "Content-Type: application/json", "-d", body_str],
                capture_output=True, text=True, timeout=15,
            )
            parts = result.stdout.rsplit("\n", 1)
            resp_text = parts[0].strip() if len(parts) > 1 else result.stdout.strip()
            http_code = int(parts[1].strip()) if len(parts) > 1 else 0
            if http_code in (200, 201):
                resp_body = json.loads(resp_text) if resp_text else {}
                sent += 1
                status = "new" if resp_body.get("inserted") else "dup"
                print(f"  line {idx} [{event_type}]: {status}")
            else:
                print(f"  line {idx}: HTTP {http_code} — {resp_text[:200]}", file=sys.stderr)
                failed += 1
        except Exception as e:
            print(f"  line {idx}: error — {e}", file=sys.stderr)
            failed += 1

    icon = "OK" if failed == 0 else "WARN"
    print(f"\n  [{icon}] {sent}/{len(file_lines)} sent, {failed} failed  (session {session_uuid})")
    if failed == 0 and sent > 0:
        dest = path.parent / "uploaded" / path.name
        dest.parent.mkdir(exist_ok=True)
        path.rename(dest)
        print(f"  moved -> {dest}")


# ── tree (WP-295 F2 C-skeleton) ───────────────────────────────────────────────

def cmd_tree(session_id_arg: str):
    """Compact decision tree with corpus tags (source/attributed_to from migration 266)."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            if session_id_arg == "last":
                cur.execute(
                    "SELECT session_id, agent_id, started_at, wp_id, context_summary"
                    " FROM agent_trace.session ORDER BY started_at DESC LIMIT 1"
                )
            else:
                cur.execute(
                    "SELECT session_id, agent_id, started_at, wp_id, context_summary"
                    " FROM agent_trace.session WHERE session_id = %s",
                    (session_id_arg,),
                )
            sess = cur.fetchone()

    if not sess:
        sys.exit(f"Session not found: {session_id_arg}")

    sid = str(sess["session_id"])
    print(f"\nSession {sid}  [{sess['agent_id']}]  {fmt_ts(sess['started_at'])}")
    if sess["wp_id"]:
        print(f"WP: {sess['wp_id']}")
    if sess["context_summary"]:
        print(f"Context: {sess['context_summary']}")
    print()

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT d.id, d.sequence, d.decided_at, d.decision_text,
                       d.chosen_hypothesis,
                       d.source, d.attributed_to,
                       array_agg(h.hypothesis_text ORDER BY h.id)
                           FILTER (WHERE h.id IS NOT NULL) AS rejected
                FROM agent_trace.decision d
                LEFT JOIN agent_trace.hypothesis h
                       ON h.decision_id = d.id AND h.status = 'rejected'
                WHERE d.session_id = %s
                GROUP BY d.id
                ORDER BY d.sequence
                """,
                (sid,),
            )
            decisions = cur.fetchall()

    if not decisions:
        print("  (no decisions recorded)")
        print()
        return

    last_i = len(decisions) - 1
    for i, d in enumerate(decisions):
        branch = "└─" if i == last_i else "├─"
        corpus_tag = ""
        if d["source"] != "realtime" or d["attributed_to"] != "agent":
            corpus_tag = f"  [{d['source']}/{d['attributed_to']}]"
        print(f"{branch} #{d['sequence']} [{fmt_ts(d['decided_at'])}] id={d['id']}{corpus_tag}")
        text = d["decision_text"]
        tail = "…" if len(text) > 100 else ""
        print(f"|    {text[:100]}{tail}")
        chosen = d["chosen_hypothesis"]
        tail2 = "…" if len(chosen) > 90 else ""
        print(f"|    -> {chosen[:90]}{tail2}")
        if d["rejected"]:
            rejected_str = "; ".join(r[:60] for r in d["rejected"])
            tail3 = "…" if len(rejected_str) > 120 else ""
            print(f"|    x  {rejected_str[:120]}{tail3}")
        print("|")

    print()


# ── replay (WP-295 F2 C-skeleton) ─────────────────────────────────────────────

def cmd_replay(event_id: int, dry_run: bool, fork: bool, branch: str | None = None):
    """
    Restore context from a decision point (SC.038).

    --dry-run         show injectable context without writing to DB.
    --fork            INSERT into fork_session and print FORK_SESSION_ID.
    --branch NAME     override default branch name (fork-<sid8>-seq<N>).
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT d.id, d.session_id, d.sequence, d.decided_at,
                       d.decision_text, d.chosen_hypothesis, d.rationale,
                       d.source, d.attributed_to,
                       s.agent_id, s.wp_id, s.context_summary
                FROM agent_trace.decision d
                JOIN agent_trace.session s USING (session_id)
                WHERE d.id = %s
                """,
                (event_id,),
            )
            target = cur.fetchone()

    if not target:
        sys.exit(f"Decision id={event_id} not found.")

    sid = str(target["session_id"])
    seq = target["sequence"]

    print(f"\nReplay target: decision id={event_id}")
    print(f"  Session:     {sid}  [{target['agent_id']}]")
    print(f"  Sequence:    #{seq}  at {fmt_ts(target['decided_at'])}")
    print(f"  Corpus:      source={target['source']} / attributed_to={target['attributed_to']}")
    if target["wp_id"]:
        print(f"  WP:          {target['wp_id']}")
    print()

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, decision_sequence, taken_at
                FROM agent_trace.snapshot
                WHERE session_id = %s AND decision_sequence <= %s
                ORDER BY decision_sequence DESC
                LIMIT 1
                """,
                (sid, seq),
            )
            snap = cur.fetchone()

            start_seq = snap["decision_sequence"] if snap else 0
            cur.execute(
                """
                SELECT sequence, decided_at, decision_text, chosen_hypothesis,
                       source, attributed_to
                FROM agent_trace.decision
                WHERE session_id = %s AND sequence > %s AND sequence <= %s
                ORDER BY sequence
                """,
                (sid, start_seq, seq),
            )
            replay_decisions = cur.fetchall()

    if snap:
        snap_id = snap["id"]
        snap_seq = snap["decision_sequence"]
        snap_ts = fmt_ts(snap["taken_at"])
        print(f"  Snapshot:    id={snap_id} at seq #{snap_seq}  ({snap_ts})")
        print(f"  Replay from: seq #{start_seq + 1} to #{seq}  ({len(replay_decisions)} decisions)")
    else:
        print(f"  Snapshot:    none — from session start to #{seq}  ({len(replay_decisions)} decisions)")
    print()

    if fork and not dry_run:
        if not _REPLAY_MODULE:
            sys.exit("--fork requires iwe_replay.py on sys.path.")
        branch_name = branch or f"fork-{sid[:8]}-seq{seq}"
        with get_conn() as rconn:
            ctx = iwe_replay.restore_context(sid, seq, rconn)
        with get_writer_conn() as wconn:
            fork_id = iwe_replay.create_fork_session(ctx, branch_name, wconn)
            wconn.commit()
        print(f"Fork session created: id={fork_id}")
        print(f"  Branch: {branch_name}")
        print(f"  To link: set FORK_SESSION_ID={fork_id} before starting new Claude session.")
        print()
        return

    # Use iwe_replay module (components A+B) when available; fall back to inline summary.
    if _REPLAY_MODULE:
        with get_conn() as conn:
            ctx = iwe_replay.restore_context(sid, seq, conn)
        stats = iwe_replay.context_stats(ctx)
        context_str = iwe_replay.format_injectable(ctx)
        chars = stats["chars"]
        tokens_est = stats["tokens_est"]
    else:
        # Minimal fallback — iwe_replay.py not on sys.path.
        ctx_lines = [f"Session context: {target['context_summary'] or '(none)'}",
                     "", "Decision trail:"]
        for d in replay_decisions:
            corpus = f" [{d['source']}]" if d["source"] != "realtime" else ""
            ctx_lines.append(f"  #{d['sequence']}{corpus}: {d['decision_text']}")
            ctx_lines.append(f"    chose: {d['chosen_hypothesis']}")
        ctx_lines += ["", f"Fork point: decision id={event_id}  {target['decision_text']!r}",
                      f"Chosen was: {target['chosen_hypothesis']}", ""]
        context_str = "\n".join(ctx_lines)
        chars = len(context_str)
        tokens_est = chars // 4

    if dry_run:
        sep = "─" * 60
        print(f"  [DRY RUN] Injectable context ({chars} chars, ~{tokens_est} tokens est.)")
        print("  " + sep)
        for line in context_str.splitlines():
            print(f"  {line}")
        print("  " + sep)
        print()
        print("  Pass --fork to inject into a new session (component C-full).")
    else:
        print(context_str)

    print()


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        prog="iwe trace",
        description="Agent trace CLI (WP-295 F1+F2)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_show = sub.add_parser("show", help="show session trace")
    p_show.add_argument("session_id", help="UUID or 'last'")

    p_search = sub.add_parser("search", help="search sessions")
    p_search.add_argument("--wp",    help="filter by WP (e.g. WP-295)")
    p_search.add_argument("--date",  help="filter by date YYYY-MM-DD")
    p_search.add_argument("--agent", help="filter by agent_id (substring)")
    p_search.add_argument("--limit", type=int, default=20, help="max rows (default 20)")

    p_upload = sub.add_parser("upload", help="upload NDJSON to event-gateway")
    p_upload.add_argument("ndjson_file", help="path to .ndjson file")

    p_tree = sub.add_parser("tree", help="decision tree for a session (WP-295 F2)")
    p_tree.add_argument("session_id", help="UUID or 'last'")

    p_replay = sub.add_parser("replay", help="restore context from a decision point (WP-295 F2)")
    p_replay.add_argument("event_id", type=int, help="id in agent_trace.decision")
    p_replay.add_argument("--dry-run", action="store_true",
                          help="show injectable context without creating a fork")
    p_replay.add_argument("--fork", action="store_true",
                          help="create a fork session in DB (C-full)")
    p_replay.add_argument("--branch", default=None,
                          help="branch name for the fork (default: fork-<sid8>-seq<N>)")

    args = parser.parse_args()

    if args.cmd == "show":
        cmd_show(args.session_id)
    elif args.cmd == "search":
        cmd_search(args.wp, args.date, args.agent, args.limit)
    elif args.cmd == "upload":
        cmd_upload(args.ndjson_file)
    elif args.cmd == "tree":
        cmd_tree(args.session_id)
    elif args.cmd == "replay":
        cmd_replay(args.event_id, dry_run=args.dry_run, fork=args.fork,
                   branch=args.branch)


if __name__ == "__main__":
    main()
