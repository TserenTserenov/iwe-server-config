"""
WP-295 F2 components A+B: restore_context() and context formatter.

Component A — restore_context(session_id, target_seq, conn):
  Queries agent_trace.snapshot + agent_trace.decision to build a ReplayContext.

Component B — format_injectable(ctx):
  Turns a ReplayContext into a markdown string suitable for injection
  into a new Claude Code session as system context.

Both components are used by:
  - iwe-trace.py  replay --dry-run  (preview)
  - iwe-trace.py  replay --fork     (C-full, not yet built)
  - Any future automation that needs to restore a decision context.

see DP.SC.038 (replay service clause), DP.METHOD.058 (Replay & Fork method).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


# ── data model ────────────────────────────────────────────────────────────────

@dataclass
class DecisionRecord:
    decision_id: int
    sequence: int
    decided_at: datetime
    decision_text: str
    chosen_hypothesis: str
    rationale: str
    source: str         # 'realtime' | 'peer-session-import'
    attributed_to: str  # 'agent' | 'consensus'


@dataclass
class SnapshotRecord:
    snapshot_id: int        # agent_trace.snapshot.id
    sequence_at: int        # agent_trace.snapshot.decision_sequence
    snapshot_data: dict     # agent_trace.snapshot.state_serialized
    captured_at: datetime   # agent_trace.snapshot.taken_at


@dataclass
class ReplayContext:
    """
    Everything needed to recreate the context at a specific decision point.

    snapshot      — nearest checkpoint before target_seq (None if no snapshots)
    decisions     — ordered list from snapshot to target (inclusive)
    target        — the decision at target_seq (fork point)
    session_meta  — agent_id, wp_id, context_summary of the source session
    """
    snapshot: Optional[SnapshotRecord]
    decisions: list[DecisionRecord]
    target: DecisionRecord
    session_meta: dict
    source_session_id: str


# ── component A: restore_context ──────────────────────────────────────────────

def restore_context(session_id: str, target_seq: int, conn) -> ReplayContext:
    """
    Build a ReplayContext for the given session and decision sequence number.

    Queries:
      - agent_trace.session  for session metadata
      - agent_trace.snapshot for nearest checkpoint at or before target_seq
      - agent_trace.decision for decisions from checkpoint to target

    Raises ValueError if session or target decision not found.
    """
    with conn.cursor() as cur:
        cur.execute(
            "SELECT agent_id, wp_id, context_summary FROM agent_trace.session"
            " WHERE session_id = %s",
            (session_id,),
        )
        sess = cur.fetchone()

    if sess is None:
        raise ValueError(f"Session not found: {session_id}")

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, decision_sequence, state_serialized, taken_at
            FROM agent_trace.snapshot
            WHERE session_id = %s AND decision_sequence <= %s
            ORDER BY decision_sequence DESC
            LIMIT 1
            """,
            (session_id, target_seq),
        )
        snap_row = cur.fetchone()

    snapshot: Optional[SnapshotRecord] = None
    start_seq = 0
    if snap_row is not None:
        raw = snap_row["state_serialized"]
        snapshot = SnapshotRecord(
            snapshot_id=snap_row["id"],
            sequence_at=snap_row["decision_sequence"],
            snapshot_data=raw if isinstance(raw, dict) else {},
            captured_at=snap_row["taken_at"],
        )
        start_seq = snapshot.sequence_at

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, sequence, decided_at, decision_text, chosen_hypothesis,
                   rationale, source, attributed_to
            FROM agent_trace.decision
            WHERE session_id = %s AND sequence > %s AND sequence <= %s
            ORDER BY sequence
            """,
            (session_id, start_seq, target_seq),
        )
        rows = cur.fetchall()

    if not rows:
        raise ValueError(
            f"No decisions found for session {session_id} seq {start_seq+1}..{target_seq}"
        )

    decisions = [
        DecisionRecord(
            decision_id=r["id"],
            sequence=r["sequence"],
            decided_at=r["decided_at"],
            decision_text=r["decision_text"],
            chosen_hypothesis=r["chosen_hypothesis"],
            rationale=r["rationale"],
            source=r["source"],
            attributed_to=r["attributed_to"],
        )
        for r in rows
    ]

    target = next((d for d in decisions if d.sequence == target_seq), decisions[-1])

    return ReplayContext(
        snapshot=snapshot,
        decisions=decisions,
        target=target,
        session_meta={
            "agent_id": sess["agent_id"],
            "wp_id": sess["wp_id"],
            "context_summary": sess["context_summary"],
        },
        source_session_id=session_id,
    )


# ── component B: formatter ────────────────────────────────────────────────────

def format_injectable(ctx: ReplayContext) -> str:
    """
    Format a ReplayContext into an injectable markdown context string.

    The output is designed to be prepended to a new Claude Code session prompt,
    giving the agent enough context to explore a different decision at the fork point.

    Contract (SC.038):
      - Does NOT replay external world state (filesystem, API responses).
      - Does NOT restore filesystem state.
      - Provides byte-equal context for the same event_id (deterministic).
    """
    parts: list[str] = []

    parts.append("## Replay Context (WP-295 SC.038)")
    parts.append("")

    meta = ctx.session_meta
    parts.append(f"**Source session:** {ctx.source_session_id}")
    if meta.get("agent_id"):
        parts.append(f"**Agent:** {meta['agent_id']}")
    if meta.get("wp_id"):
        parts.append(f"**WP:** {meta['wp_id']}")
    if meta.get("context_summary"):
        parts.append(f"**Original context:** {meta['context_summary']}")
    parts.append("")

    if ctx.snapshot:
        snap = ctx.snapshot
        parts.append(f"### Snapshot (seq #{snap.sequence_at})")
        summary = (
            snap.snapshot_data.get("context_summary")
            or snap.snapshot_data.get("summary")
            or ""
        )
        if summary:
            parts.append(summary)
        parts.append("")

    parts.append("### Decision trail")
    parts.append("")

    for d in ctx.decisions:
        is_target = d.sequence == ctx.target.sequence
        marker = "**[FORK POINT]**" if is_target else ""
        corpus_note = ""
        if d.source != "realtime":
            corpus_note = f" *(imported from {d.source})*"

        parts.append(f"**#{d.sequence}**{corpus_note} — {d.decision_text} {marker}")
        parts.append(f"- Chose: {d.chosen_hypothesis}")
        if d.rationale and len(d.rationale) > 10:
            rationale_short = d.rationale[:200].replace("\n", " ")
            tail = "…" if len(d.rationale) > 200 else ""
            parts.append(f"- Rationale: {rationale_short}{tail}")
        parts.append("")

    parts.append("### Fork instruction")
    parts.append("")
    parts.append(
        f"The fork point is decision #{ctx.target.sequence}: "
        f"**{ctx.target.decision_text}**"
    )
    parts.append(f"Originally chose: _{ctx.target.chosen_hypothesis}_")
    parts.append("")
    parts.append(
        "To explore a different path, describe an alternative hypothesis below "
        "and continue the analysis from there."
    )

    return "\n".join(parts)


# ── stats helper ──────────────────────────────────────────────────────────────

def context_stats(ctx: ReplayContext) -> dict:
    """Return size metrics for the injectable context (for token budget estimates)."""
    text = format_injectable(ctx)
    chars = len(text)
    return {
        "chars": chars,
        "tokens_est": chars // 4,
        "decisions": len(ctx.decisions),
        "has_snapshot": ctx.snapshot is not None,
        "source_session": ctx.source_session_id,
        "target_seq": ctx.target.sequence,
    }


# ── component C: create fork session ─────────────────────────────────────────

def create_fork_session(ctx: ReplayContext, branch_name: str, conn) -> int:
    """
    Insert one row into agent_trace.fork_session recording the fork intent.

    Returns fork_session_id (int). new_session_id stays NULL until the fork
    session starts — the writer hook sets it via FORK_SESSION_ID env var.
    Caller is responsible for conn.commit().
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO agent_trace.fork_session
                (parent_session_id, parent_event_id, fork_branch_name,
                 selector_decision, forked_at, forked_by)
            VALUES (%s, %s, %s, %s, NOW() AT TIME ZONE 'UTC', %s)
            RETURNING id
            """,
            (
                ctx.source_session_id,
                ctx.target.decision_id,
                branch_name,
                "human_override",
                "iwe-trace-replay",
            ),
        )
        row = cur.fetchone()
    return row["id"]
