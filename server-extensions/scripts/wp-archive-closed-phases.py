#!/usr/bin/env python3
"""wp-archive-closed-phases.py -- deterministic archival of CLOSED phase sections
of a WP card into inbox/WP-N/WP-N-archive.md (protocol-close.md §5c).

WP-561 Ф24, peer-session 2026-09-27-09 (Claude + Kimi + Codex), standing pilot
directive of 27.09.2026 «закрытие с архивацией выполненного по РП»: §5c used to
ask the pilot "переношу?" for every card over the threshold and to rely on the
closing agent hand-editing two files -- so it never happened (all three cards
of the session were over threshold, WP-530 had never been archived at all).

What counts as a CLOSED phase (positive evidence is REQUIRED -- Codex: the
absence of checkboxes does not prove closure, a research phase can be open in
prose; ~~strike~~ may mean "cancelled", the word «закрыт» inside a heading may
describe a blocker, not the phase):
  * frontmatter  phases:\n  ФN: done|closed|archived|completed        or
  * a formal terminal marker in a fixed position of the H2 heading:
      ## ФN ✅ ...   /  ## ФN — ✅ ...  /  ## ФN [done]  / ## ФN [закрыто] /
      ## ФN [status: done|closed]   / heading ends with ✅
Everything else is a NEGATIVE veto (any one keeps the section in the card):
  * an unchecked `- [ ]` inside the section
  * an `<!-- h id=` anchor (hypotheses_due.py contract, RP-541 Ф3)
  * the phase id is referenced in the «Следующий шаг» field of «Осталось»
  * the section is one of the last --keep-last K phases (convenience policy,
    not a safety proof -- Codex)
  * the H2 heading text is not unique in the card (ambiguous target -- Codex)
  * archive-section-guard.sh (governance repo) returned 1 (block) or 3 (error/
    timeout) for it, or 2 (escalate) with anything but PURE rule R3 evidence
    -- the guard is a SHADOW analyzer by its own contract ("callers decide
    whether to enforce it"); round 2 of the peer-session (Kimi + Codex): exit 2
    whose evidence is only R3 (verb heuristics «ждёт/остаётся/требует», found
    to fire on 29 of 31 genuinely closed WP-530 phases) is overridden by the
    explicit ✅ decision of the closing agent, recorded in the card journal and
    in the recovery journal with the guard's full payload; exit 2 with R0/R1/R2,
    non-empty incoming_links, unknown rules, missing fields or unparsable
    output stays a veto (fail closed, Codex).
Safety of --apply (Codex): per-WP lock with bounded wait, precondition hashes,
a recovery journal written BEFORE the first write, temp-file + atomic rename
for both files, post-check by DELTA of exact block occurrences (Kimi), SIGINT/
SIGTERM leave the journal for the idempotent re-run.

Usage:
  wp-archive-closed-phases.py <WP_NUM> [--governance-repo DIR] [--apply]
        [--keep-last K] [--ostalos-check] [--json] [--guard-timeout SEC]
Exit: 0 = ok (dry-run report, or applied, or nothing to do)
      1 = usage / card not found
      3 = safety refusal (lock busy, recovery pending, guard unavailable for
          --apply, post-check failed and rolled back)
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

TERMINAL_STATUSES = {"done", "closed", "archived", "completed"}
# ФN, sub-phases ФN.M(.K), optional letter suffix (Ф5а) -- the FIRST token after "## ".
# Cold review 27.09: `Ф\d+` alone truncated Ф16.2 to Ф16, so frontmatter `Ф16: done`
# licensed the still-open sub-phase 16.2 for archival.
PHASE_ID = r"Ф\d+(?:\.\d+)*[а-яa-z]?"
PHASE_HEADING_RE = re.compile(rf"^## ({PHASE_ID})\b(.*)$")
FIELD_LINE_RE = re.compile(r"^\*\*[^*]+\*\*")
# formal terminal markers in a fixed position (see module docstring)
HEAD_MARK_AFTER_ID_RE = re.compile(r"^\s*(?:[—\-:]\s*)?✅")
HEAD_BRACKET_RE = re.compile(r"\[(?:status:\s*)?(?:done|closed|completed|закрыт[оа]?)\]", re.I)
UNCHECKED_RE = re.compile(r"^\s*[-*] \[ \]")
ANCHOR_RE = re.compile(r"<!--\s*h\s+id=")
OSTALOS_FIELDS = (
    "Что пробовали", "Что узнали", "Что дальше", "Следующий шаг",
    "Контекст для следующей сессии", "Заблокировано", "Зависит от", "Актуально до",
)
POLICY_TAG = "protocol-close-5c-2026-09-27"


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def today() -> str:
    return _dt.date.today().isoformat()


# ---------------------------------------------------------------------------
# card model
# ---------------------------------------------------------------------------
class Card:
    def __init__(self, path: str):
        self.path = path
        with open(path, encoding="utf-8") as fh:
            self.text = fh.read()
        self.lines = self.text.split("\n")
        self.fm_end = self._frontmatter_end()
        self.sections = self._split_sections()

    def _frontmatter_end(self) -> int:
        """Index of the closing '---' line of the frontmatter, or -1."""
        if not self.lines or self.lines[0].strip() != "---":
            return -1
        for i in range(1, len(self.lines)):
            if self.lines[i].strip() == "---":
                return i
        return -1

    def frontmatter_lines(self) -> list[str]:
        return self.lines[1:self.fm_end] if self.fm_end > 0 else []

    def fm_scalar(self, key: str) -> str | None:
        for ln in self.frontmatter_lines():
            m = re.match(rf"^{re.escape(key)}:\s*(.*)$", ln)
            if m:
                return m.group(1).strip().strip('"').strip("'")
        return None

    def fm_phases(self) -> dict[str, str]:
        """`phases:` in frontmatter, map form (`  ФN: status`) or list form
        (`- id: ФN` + `status: s`, the structured shape wp-sync-bundle treats as
        SoT). Anything else -> {}."""
        out: dict[str, str] = {}
        fm = self.frontmatter_lines()
        for i, ln in enumerate(fm):
            if not re.match(r"^phases:\s*$", ln):
                continue
            current_id: str | None = None
            for sub in fm[i + 1:]:
                if sub.strip() == "":
                    continue
                if not sub.startswith(" ") and not sub.startswith("-"):
                    break
                m_map = re.match(rf"^\s{{2,}}({PHASE_ID})\s*:\s*(\S+)\s*$", sub)
                m_id = re.match(rf"^\s*-\s*(?:id|phase)\s*:\s*\"?({PHASE_ID})\"?\s*$", sub)
                m_status = re.match(r"^\s+status\s*:\s*\"?([A-Za-z_]+)\"?\s*$", sub)
                if m_map:
                    out[m_map.group(1)] = m_map.group(2).strip().strip('"').lower()
                    current_id = None
                elif m_id:
                    current_id = m_id.group(1)
                elif m_status and current_id:
                    out[current_id] = m_status.group(1).lower()
            break
        return out

    def _split_sections(self) -> list[dict]:
        """H2 sections of the body (after frontmatter), fenced code ignored."""
        secs: list[dict] = []
        fence: tuple[str, int] | None = None   # (char, length) of the OPEN fence, CommonMark: close only with same char, >= length
        start = self.fm_end + 1 if self.fm_end >= 0 else 0
        current: dict | None = None
        for i in range(start, len(self.lines)):
            ln = self.lines[i]
            m_fence = re.match(r"^ {0,3}(`{3,}|~{3,})", ln)
            if m_fence:
                run = m_fence.group(1)
                if fence is None:
                    fence = (run[0], len(run))
                    continue
                if run[0] == fence[0] and len(run) >= fence[1] and ln.strip() == run:
                    fence = None
                    continue
            if fence is not None:
                continue
            if ln.startswith("## "):
                if current is not None:
                    current["end"] = i
                    secs.append(current)
                current = {"start": i, "heading": ln.rstrip(), "end": len(self.lines)}
        if current is not None:
            secs.append(current)
        return secs

    def section_text(self, sec: dict) -> str:
        return "\n".join(self.lines[sec["start"]:sec["end"]])

    def find_section(self, heading: str) -> dict | None:
        hits = [s for s in self.sections if s["heading"].strip() == heading]
        return hits[0] if len(hits) == 1 else None


# ---------------------------------------------------------------------------
# analysis
# ---------------------------------------------------------------------------
def phase_id_of(heading: str) -> str | None:
    m = PHASE_HEADING_RE.match(heading)
    return m.group(1) if m else None


def heading_has_terminal_marker(heading: str) -> bool:
    m = PHASE_HEADING_RE.match(heading)
    if not m:
        return False
    rest = m.group(2)
    if HEAD_MARK_AFTER_ID_RE.match(rest):
        return True
    if heading.rstrip().endswith("✅"):
        return True
    return bool(HEAD_BRACKET_RE.search(rest))


def ostalos_sections(card: Card) -> list[dict]:
    """Every H2 whose heading starts with «## Осталось» (the exact one plus the
    forbidden variants like «## Осталось (Ф68)», RP-541 Ф5) -- vetoes must see all."""
    return [s for s in card.sections if s["heading"].strip().startswith("## Осталось")]


def next_step_text(card: Card) -> str:
    """Value of every «**Следующий шаг…:**» field (also «…шаг агента:», «…шаг (…):»)
    including continuation lines up to the next **Поле:** line, across all
    Осталось* sections."""
    out: list[str] = []
    for sec in ostalos_sections(card):
        capturing = False
        for ln in card.section_text(sec).split("\n"):
            if re.match(r"^\*\*Следующий шаг[^*]*\*\*", ln):
                capturing = True
                out.append(ln)
                continue
            if capturing:
                if FIELD_LINE_RE.match(ln) or ln.startswith("## ") or ln.startswith("### "):
                    capturing = False
                else:
                    out.append(ln)
    return "\n".join(out)


def analyze(card: Card, keep_last: int) -> dict:
    fm_phases = card.fm_phases()
    heading_counts: dict[str, int] = {}
    for s in card.sections:
        heading_counts[s["heading"].strip()] = heading_counts.get(s["heading"].strip(), 0) + 1
    phase_secs = [s for s in card.sections if phase_id_of(s["heading"])]
    keep_ids = {phase_id_of(s["heading"]) for s in phase_secs[-keep_last:]} if keep_last > 0 else set()
    next_step = next_step_text(card)

    candidates, vetoed, no_marker, attention = [], [], [], []
    for s in phase_secs:
        pid = phase_id_of(s["heading"])
        body = card.section_text(s)
        fm_status = fm_phases.get(pid, "")
        positive = fm_status in TERMINAL_STATUSES or heading_has_terminal_marker(s["heading"])
        referenced = bool(re.search(rf"(?<![\wФ]){re.escape(pid)}(?![\wа-я.]|\.\d)", next_step))
        unchecked = sum(1 for ln in body.split("\n") if UNCHECKED_RE.match(ln))
        if referenced and unchecked:
            attention.append({"phase": pid, "reason": "упомянута в «Следующий шаг», но содержит незакрытые пункты"})
        if not positive:
            no_marker.append({"phase": pid, "heading": s["heading"]})
            continue
        vetoes = []
        if unchecked:
            vetoes.append(f"незакрытые пункты: {unchecked}")
        if ANCHOR_RE.search(body):
            vetoes.append("якорь <!-- h id= --> (контракт hypotheses_due.py)")
        if referenced:
            vetoes.append("упомянута в «Следующий шаг» секции «Осталось»")
        if pid in keep_ids:
            vetoes.append(f"одна из последних {keep_last} фаз (--keep-last)")
        if heading_counts.get(s["heading"].strip(), 0) != 1:
            vetoes.append("заголовок H2 не уникален в карточке")
        if fm_status and fm_status not in TERMINAL_STATUSES:
            vetoes.append(f"frontmatter phases.{pid}={fm_status}")
        entry = {"phase": pid, "heading": s["heading"], "start": s["start"] + 1, "end": s["end"],
                 "lines": s["end"] - s["start"], "sha256": sha256_text(body)}
        if vetoes:
            entry["vetoes"] = vetoes
            vetoed.append(entry)
        else:
            candidates.append(entry)
    return {"candidates": candidates, "vetoed": vetoed, "no_terminal_marker": no_marker,
            "attention": attention, "phase_sections": len(phase_secs)}


def ostalos_check(card: Card) -> dict:
    heads = ostalos_sections(card)
    exact = [s for s in heads if s["heading"].strip() == "## Осталось"]
    res: dict = {"ostalos_headings": len(heads), "exact_headings": len(exact)}
    if len(exact) != 1:
        res["ok"] = False
        res["problems"] = ["секция «## Осталось» должна быть ровно одна (точное написание)"]
        return res
    body = card.section_text(exact[0])
    missing = [f for f in OSTALOS_FIELDS if not re.search(rf"^\*\*{re.escape(f)}:?\*\*", body, re.M)]
    subsections = [ln for ln in body.split("\n") if ln.startswith("### ") or re.match(r"^\*\*Ф\d+", ln)]
    res.update({"lines": body.count("\n") + 1, "bytes": len(body.encode("utf-8")),
                "missing_fields": missing, "subsections_inside": len(subsections)})
    problems = []
    if len(heads) != len(exact):
        problems.append(f"теневые секции «## Осталось (…)»: {len(heads) - len(exact)} (РП-541 Ф5 запрещает варианты заголовка)")
    if missing:
        problems.append(f"нет полей: {', '.join(missing)}")
    if subsections:
        problems.append(f"внутри «Осталось» {len(subsections)} подсекций/фазовых блоков — история должна жить в секциях фаз или в архиве")
    res["problems"] = problems
    res["ok"] = not problems
    return res


# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
class Refusal(Exception):
    pass


GUARD_RULE_ALLOWLIST = {"R0", "R1", "R2", "R3"}
GUARD_SHADOW_RULES = {"R3"}   # the only rule whose escalate may be overridden by an explicit ✅ (round 2 consensus)


def run_guard(gov: str, card_path: str, heading: str, inbox: str, timeout: int) -> tuple[int, str, dict | None]:
    """Returns (exit, short_message, parsed_payload_or_None)."""
    guard = os.path.join(gov, "scripts", "archive-section-guard.sh")
    if not os.path.isfile(guard):
        return -1, "archive-section-guard.sh not found", None
    try:
        p = subprocess.run(["bash", guard, card_path, "--section", heading, "--registry-root", inbox],
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return -2, f"guard timeout after {timeout}s", None
    payload = None
    try:
        payload = json.loads(p.stdout.strip() or "null")
        if not isinstance(payload, dict):
            payload = None
    except ValueError:
        payload = None
    return p.returncode, (p.stdout or p.stderr).strip()[:400], payload


def guard_escalate_is_pure_r3(payload: dict | None) -> tuple[bool, str]:
    """Strict, fail-closed classification of an exit-2 payload (Codex, round 2):
    every field must be present and well-formed, every rule must be in the
    allowlist, and only R3 may appear; incoming_links must be an EMPTY list."""
    if payload is None:
        return False, "guard output not parsable as JSON object"
    if not isinstance(payload.get("guard_version"), str) or not payload["guard_version"]:
        return False, "guard_version missing"
    verdict = payload.get("verdict")
    if verdict is not None and verdict != "escalate":
        return False, f"verdict={verdict!r} is not escalate"
    links = payload.get("incoming_links")
    if not isinstance(links, list):
        return False, "incoming_links missing or not a list"
    if links:
        return False, f"incoming_links present ({len(links)})"
    evidence = payload.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        return False, "evidence missing or empty (escalate without evidence is not pure R3)"
    rules = set()
    for ev in evidence:
        if not isinstance(ev, dict) or not isinstance(ev.get("rule"), str):
            return False, "evidence entry without a rule"
        rules.add(ev["rule"])
    declared = payload.get("rules_triggered")
    if declared is not None:
        if not isinstance(declared, list) or not all(isinstance(r, str) for r in declared):
            return False, "rules_triggered malformed"
        rules |= set(declared)
    if not rules <= GUARD_RULE_ALLOWLIST:
        return False, f"unknown guard rule(s): {sorted(rules - GUARD_RULE_ALLOWLIST)}"
    if not rules <= GUARD_SHADOW_RULES:
        return False, f"structural rule(s) present: {sorted(rules - GUARD_SHADOW_RULES)}"
    return True, "pure R3"


def atomic_write(path: str, text: str) -> None:
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".wp-archive-", dir=d)
    try:
        # mkstemp gives 0600; keep the file readable as before (cold review: cards
        # and archives became owner-only after a move).
        if os.path.exists(path):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        else:
            umask = os.umask(0)
            os.umask(umask)
            os.chmod(tmp, 0o666 & ~umask)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True   # someone else's live process (cold review: must not be "dead")
    return True


def acquire_lock(lock_dir: str, wait_sec: int) -> None:
    deadline = time.time() + wait_sec
    while True:
        try:
            os.mkdir(lock_dir)
        except FileExistsError:
            owner = os.path.join(lock_dir, "owner")
            try:
                pid = int(re.search(r"pid=(\d+)", open(owner).read()).group(1))
            except (OSError, ValueError, AttributeError):
                pid = None   # owner file not there yet (holder between mkdir and rename) or damaged: wait, never reclaim
            if pid is not None and not _pid_alive(pid):
                try:
                    os.unlink(owner)
                except OSError:
                    pass
                try:
                    os.rmdir(lock_dir)
                except OSError:
                    pass
                continue
            if time.time() > deadline:
                raise Refusal(f"lock busy: {lock_dir} (bounded wait {wait_sec}s exceeded)")
            time.sleep(0.2)
            continue
        # owner record appears atomically (temp + rename) so a racing reader never sees a half-written or missing file
        fd, tmp = tempfile.mkstemp(prefix=".owner-", dir=lock_dir)
        with os.fdopen(fd, "w") as fh:
            fh.write(f"pid={os.getpid()}\nat={_dt.datetime.now(_dt.timezone.utc).isoformat()}\n")
        os.replace(tmp, os.path.join(lock_dir, "owner"))
        return


def release_lock(lock_dir: str) -> None:
    try:
        os.unlink(os.path.join(lock_dir, "owner"))
    except OSError:
        pass
    try:
        os.rmdir(lock_dir)
    except OSError:
        pass


def update_frontmatter(lines: list[str], fm_end: int, updates: dict[str, str]) -> list[str]:
    out = list(lines)
    for key, val in updates.items():
        idx = None
        for i in range(1, fm_end):
            if re.match(rf"^{re.escape(key)}:", out[i]):
                idx = i
                break
        line = f"{key}: {val}"
        if idx is None:
            out.insert(fm_end, line)
            fm_end += 1
        else:
            out[idx] = line
    return out


def append_journal_lines(lines: list[str], entries: list[str]) -> list[str]:
    out = list(lines)
    idx = None
    for i, ln in enumerate(out):
        if ln.strip() == "## Журнал":
            idx = i
    if idx is None:
        if out and out[-1].strip() != "":
            out.append("")
        out.append("## Журнал")
        out.append("")
        out.extend(entries)
        return out
    # insert right after the heading (and its blank line), newest first is fine for a log
    insert_at = idx + 1
    if insert_at < len(out) and out[insert_at].strip() == "":
        insert_at += 1
    for e in reversed(entries):
        out.insert(insert_at, e)
    return out


def apply(card: Card, wp: str, cands: list[dict], gov: str, inbox: str, runtime: str,
          guard_timeout: int, lock_wait: int) -> dict:
    archive_path = os.path.join(os.path.dirname(card.path), f"WP-{wp}-archive.md")
    lock_dir = os.path.join(runtime, "wp-archive-locks", f"WP-{wp}.lock")
    journal_dir = os.path.join(runtime, "wp-archive-journal")
    os.makedirs(os.path.dirname(lock_dir), exist_ok=True)
    os.makedirs(journal_dir, exist_ok=True)
    acquire_lock(lock_dir, lock_wait)
    interrupted = {"flag": False}

    def _sig(_signum, _frame):
        interrupted["flag"] = True

    old_handlers = {s: signal.signal(s, _sig) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        pending = [f for f in os.listdir(journal_dir) if f.startswith(f"WP-{wp}-") and f.endswith(".json")]
        for f in pending:
            with open(os.path.join(journal_dir, f)) as fh:
                j = json.load(fh)
            # `done` and `rolled_back` are terminal (a rollback restored both files byte-for-byte);
            # `prepared` / `archive_written` mean a crash mid-move -> fail closed.
            if j.get("state") not in ("done", "rolled_back", "aborted_card_changed", "aborted_interrupted"):
                raise Refusal(f"recovery pending: unfinished journal {f} (state={j.get('state')}) -- complete or inspect it before a new run")

        # guard per section (fail closed: guard missing or timeout -> refuse the whole apply)
        moved, skipped = [], []
        for c in cands:
            rc, msg, payload = run_guard(gov, card.path, c["heading"], inbox, guard_timeout)
            if rc == -1:
                raise Refusal("archive-section-guard.sh недоступен -- --apply запрещён (dry-run работает)")
            if rc == -2:
                raise Refusal(msg)
            if rc == 3 or (payload or {}).get("verdict") == "error":
                raise Refusal(f"archive-section-guard.sh error (rc={rc}) for {c['phase']}: {msg[:200]} -- a broken guard call is not a verdict")
            guard_rec = {"exit": rc, "version": (payload or {}).get("guard_version"), "payload": payload}
            if rc == 0:
                moved.append({**c, "guard": {**guard_rec, "verdict": "allow"}})
            elif rc == 2:
                ok, why = guard_escalate_is_pure_r3(payload)
                if ok:
                    moved.append({**c, "guard": {**guard_rec, "verdict": "escalate-overridden-pure-R3"}})
                else:
                    skipped.append({**c, "guard_exit": rc, "guard_msg": msg, "guard_skip_reason": f"escalate not overridable: {why}"})
            else:
                skipped.append({**c, "guard_exit": rc, "guard_msg": msg, "guard_skip_reason": "block or error"})
        if not moved:
            return {"applied": False, "moved": [], "skipped_by_guard": skipped, "reason": "no candidate passed the guard"}

        # Re-read the card from disk right before deciding what to write: an
        # external writer that ignores the per-WP lock may have changed it since
        # analysis (Codex, round 2) -- identity is the file digest + the exact
        # range digest of every section, never the heading alone.
        card_disk = open(card.path, encoding="utf-8").read()
        if card_disk != card.text:
            raise Refusal("precondition: card changed on disk between analysis and apply (digest mismatch) -- rerun")
        exact_ostalos = [s for s in ostalos_sections(card) if s["heading"].strip() == "## Осталось"]
        if len(ostalos_sections(card)) != len(exact_ostalos) or len(exact_ostalos) != 1:
            raise Refusal("hygiene precondition (RP-541 Ф5): the card must have exactly one «## Осталось» and no «## Осталось (…)» variants -- fix the card first (see --ostalos-check)")
        card_before = card.text
        archive_before = open(archive_path, encoding="utf-8").read() if os.path.exists(archive_path) else ""
        # One normalised form of each block (trailing blank lines stripped) is used for the
        # precondition count, the archive text and BOTH post-check deltas (cold review: the raw
        # block with its trailing newlines never matched the rstripped copy written to the archive).
        blocks = [card.section_text(next(s for s in card.sections if s["heading"] == c["heading"])).rstrip("\n") for c in moved]
        for b, c in zip(blocks, moved):
            raw = card.section_text(next(s for s in card.sections if s["heading"] == c["heading"]))
            if sha256_text(raw) != c["sha256"]:
                raise Refusal(f"precondition: block {c['phase']} changed between analysis and apply")
            if card_before.count(b) != 1:
                raise Refusal(f"precondition: block {c['phase']} is not unique byte-for-byte in the card")

        stamp = today()
        new_archive = archive_before
        if not new_archive:
            new_archive = f"---\nwp: {wp}\ntype: archive\nparent: WP-{wp}.md\ncreated: {stamp}\n---\n# Архив WP-{wp}\n\n> Закрытые фазы, перенесённые из `WP-{wp}.md` (protocol-close.md §5c). Читать только по явному запросу пилота (S-59).\n"
        if not new_archive.endswith("\n"):
            new_archive += "\n"
        new_archive += f"\n## Перенесено {stamp} (автоархивация при закрытии)\n\n" + "\n\n".join(blocks) + "\n"

        new_lines = list(card.lines)
        # remove blocks from the end backwards so indices stay valid; collapse blank lines
        # ONLY at the seam left by the removal (cold review: a whole-card collapse rewrote
        # unrelated text, including code blocks, invisibly to the post-check)
        for c in sorted(moved, key=lambda x: x["start"], reverse=True):
            s = next(s for s in card.sections if s["heading"] == c["heading"])
            del new_lines[s["start"]:s["end"]]
            seam = s["start"]
            while 0 < seam < len(new_lines) and new_lines[seam - 1] == "" and new_lines[seam] == "":
                del new_lines[seam]
        def _journal_line(c: dict) -> str:
            base = f"- {stamp}: {c['phase']} → архив (автоархивация при закрытии, WP-{wp}-archive.md)"
            g = c.get("guard") or {}
            if g.get("verdict") == "escalate-overridden-pure-R3":
                ev = ((g.get("payload") or {}).get("evidence") or [{}])[0]
                quote = str(ev.get("text", "")).replace("\n", " ").strip()[:80]
                return base + f"; перенесено под эскалацией Стража R3 (v{g.get('version')}), эвиденс: «{quote}»"
            return base
        new_lines = append_journal_lines(new_lines, [_journal_line(c) for c in moved])
        fm_end = Card.__new__(Card)
        fm_end.lines = new_lines
        fm_end_idx = Card._frontmatter_end(fm_end)
        if fm_end_idx > 0:
            new_lines = update_frontmatter(new_lines, fm_end_idx, {
                "archive": f"WP-{wp}-archive.md", "archived_last": stamp, "auto_archive_policy": POLICY_TAG})
        new_card = "\n".join(new_lines)

        journal = {"wp": wp, "started": _dt.datetime.now(_dt.timezone.utc).isoformat(), "state": "prepared",
                   "source": card.path, "target": archive_path, "card": card.path, "archive": archive_path,
                   "card_sha_before": sha256_text(card_before), "archive_sha_before": sha256_text(archive_before),
                   "blocks": [{"phase": c["phase"], "sha256": c["sha256"], "heading": c["heading"],
                               "range": [c["start"], c["end"]], "guard": c.get("guard")} for c in moved],
                   "card_sha_after": sha256_text(new_card), "archive_sha_after": sha256_text(new_archive)}
        jpath = os.path.join(journal_dir, f"WP-{wp}-{int(time.time())}.json")
        atomic_write(jpath, json.dumps(journal, ensure_ascii=False, indent=1))

        if interrupted["flag"]:
            journal["state"] = "aborted_interrupted"
            atomic_write(jpath, json.dumps(journal, ensure_ascii=False, indent=1))
            raise Refusal("interrupted before the first write; nothing written, journal marked aborted")
        # last look at the disk right before the first write (the guard calls above may have taken minutes)
        if open(card.path, encoding="utf-8").read() != card_before:
            journal["state"] = "aborted_card_changed"
            atomic_write(jpath, json.dumps(journal, ensure_ascii=False, indent=1))
            raise Refusal("precondition: card changed on disk during guard checks -- nothing written, rerun")
        atomic_write(archive_path, new_archive)
        journal["state"] = "archive_written"
        atomic_write(jpath, json.dumps(journal, ensure_ascii=False, indent=1))
        atomic_write(card.path, new_card)

        # post-check by DELTA of exact-block occurrences (Kimi) and byte-exact presence in the archive (Codex)
        card_after = open(card.path, encoding="utf-8").read()
        archive_after = open(archive_path, encoding="utf-8").read()
        problems = []
        for b, c in zip(blocks, moved):
            if card_before.count(b) - card_after.count(b) != 1:
                problems.append(f"{c['phase']}: карточка потеряла блок не ровно один раз")
            if archive_after.count(b) - archive_before.count(b) != 1:
                problems.append(f"{c['phase']}: архив получил блок не ровно один раз")
        if problems:
            atomic_write(card.path, card_before)
            atomic_write(archive_path, archive_before) if archive_before else os.unlink(archive_path)
            journal["state"] = "rolled_back"
            journal["problems"] = problems
            atomic_write(jpath, json.dumps(journal, ensure_ascii=False, indent=1))
            raise Refusal("post-check failed, rolled back: " + "; ".join(problems))
        journal["state"] = "done"
        atomic_write(jpath, json.dumps(journal, ensure_ascii=False, indent=1))
        return {"applied": True, "moved": [c["phase"] for c in moved],
                "moved_under_escalation": [c["phase"] for c in moved if (c.get("guard") or {}).get("verdict") == "escalate-overridden-pure-R3"],
                "skipped_by_guard": skipped,
                "archive": archive_path, "journal": jpath,
                "card_lines_before": card_before.count("\n") + 1, "card_lines_after": card_after.count("\n") + 1}
    finally:
        for s, h in old_handlers.items():
            signal.signal(s, h)
        release_lock(lock_dir)


# ---------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wp", help="WP number (N or WP-N)")
    ap.add_argument("--governance-repo", default=None,
                    help="governance repo root (default: $IWE_WORKSPACE/$IWE_GOVERNANCE_REPO)")
    ap.add_argument("--apply", action="store_true", help="move the candidates (default: dry-run report)")
    ap.add_argument("--keep-last", type=int, default=2, help="never move the last K phase sections (policy, not proof)")
    ap.add_argument("--ostalos-check", action="store_true", help="also report «Осталось» hygiene")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--guard-timeout", type=int, default=30)
    ap.add_argument("--lock-wait", type=int, default=10)
    ap.add_argument("--runtime-dir", default=None, help="default: $IWE_RUNTIME or $IWE_WORKSPACE/.iwe-runtime")
    a = ap.parse_args(argv)

    wp = re.sub(r"^(?i:wp-)", "", a.wp.strip())
    if not wp.isdigit():
        print(f"usage: WP number expected, got {a.wp!r}", file=sys.stderr)
        return 1
    ws = os.environ.get("IWE_WORKSPACE", os.path.expanduser("~/IWE"))
    gov = a.governance_repo or os.path.join(ws, os.environ.get("IWE_GOVERNANCE_REPO", "DS-my-strategy"))
    runtime = a.runtime_dir or os.environ.get("IWE_RUNTIME") or os.path.join(ws, ".iwe-runtime")
    inbox = os.path.join(gov, "inbox")
    card_path = os.path.join(inbox, f"WP-{wp}", f"WP-{wp}.md")
    if not os.path.isfile(card_path):
        print(f"card not found: {card_path}", file=sys.stderr)
        return 1

    card = Card(card_path)
    report: dict = {"wp": wp, "card": card_path, "mode": "apply" if a.apply else "dry-run",
                    "keep_last": a.keep_last, **analyze(card, a.keep_last)}
    if a.ostalos_check:
        report["ostalos"] = ostalos_check(card)
    rc = 0
    if a.apply and report["candidates"]:
        try:
            report["result"] = apply(card, wp, report["candidates"], gov, inbox, runtime, a.guard_timeout, a.lock_wait)
        except Refusal as e:
            report["result"] = {"applied": False, "refused": str(e)}
            rc = 3
    elif a.apply:
        report["result"] = {"applied": False, "reason": "no candidates"}

    if a.json:
        print(json.dumps(report, ensure_ascii=False, indent=1))
    else:
        print(f"WP-{wp}: фаз-секций {report['phase_sections']}, кандидатов на архив {len(report['candidates'])}, "
              f"с вето {len(report['vetoed'])}, без явного маркера закрытия {len(report['no_terminal_marker'])}")
        for c in report["candidates"]:
            print(f"  → {c['phase']} ({c['lines']} строк) {c['heading'][:80]}")
        for v in report["vetoed"]:
            print(f"  ✗ {v['phase']}: {'; '.join(v['vetoes'])}")
        for n in report["no_terminal_marker"]:
            print(f"  ? {n['phase']}: нет явного маркера закрытия (✅ после номера / [done] / frontmatter phases)")
        for at in report["attention"]:
            print(f"  ! {at['phase']}: {at['reason']}")
        if "ostalos" in report:
            o = report["ostalos"]
            print(f"  «Осталось»: {'ок' if o.get('ok') else 'проблемы'} — " + ("; ".join(o.get("problems", [])) or f"{o.get('lines')} строк, {o.get('bytes')} байт"))
        if "result" in report:
            r = report["result"]
            if r.get("applied"):
                print(f"  перенесено: {', '.join(r['moved'])} → {r['archive']} (карточка {r['card_lines_before']} → {r['card_lines_after']} строк)")
            else:
                print(f"  не применено: {r.get('refused') or r.get('reason')}")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
