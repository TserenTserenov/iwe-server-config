#!/usr/bin/env python3
"""Repeatable acceptance run for rule A14 (ontological purity of answers), РП-388 Ф21/Ф22.

The 12 questions of the acceptance card are asked to each agent in a fresh session started from
the workspace root, so each agent loads its real instructions. Answers are graded blind.

  a14-acceptance.py run [--agents claude,kimi,codex] [--out DIR] [--timeout SEC]
      ask the questions; resumable (non-empty answers are kept)
  a14-acceptance.py replay DIR
      run the style hook over every answer; list which answers it flags (A14, A14_AMBIGUOUS)
  a14-acceptance.py blind DIR
      write blind.md (answers shuffled under labels A/B/C) and blind-key.json
  a14-acceptance.py score DIR GRADES.json
      tally graders' verdicts per agent against the acceptance criterion
      GRADES.json: {"grader": "1A c 1B f 2A s ..."}  c clean, f fail, s disputed

Acceptance criterion (card Ф21): >= 10 clean answers of 12 per agent and no failure of
checklist item 1 on questions 1-3. `score` counts failures on questions 1-3 as the proxy.
Env: IWE_ROOT (default ~/IWE), KIMI_BIN (default: `kimi` on PATH, else the VS Code Kimi
extension binary on macOS), A14_HOOK (the style hook `replay` runs; default
<root>/.claude/hooks/response-clarity-hook.sh -- set it to test an unpublished hook).

A failed agent call (non-zero exit) prints the tail of its stderr: the 30.10 run on tsekh-1 lost
all 36 answers to "Not logged in" (claude), an unknown `--quiet` flag (kimi) and "Not inside a
trusted directory" (codex) while the log only said `rc=1 0 bytes`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(os.environ.get("IWE_ROOT", Path.home() / "IWE"))
QUESTIONS = Path(__file__).resolve().parent.parent / ".claude/hooks/tests/a14-acceptance-questions.txt"
KIMI_BIN = os.environ.get("KIMI_BIN") or shutil.which("kimi") or str(
    Path.home() / "Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"
)
HOOK = Path(os.environ.get("A14_HOOK", ROOT / ".claude/hooks/response-clarity-hook.sh"))
PASS_CLEAN = 10
BLIND_SEED = 388
STDERR_TAIL_LINES = 3
# same token shapes the style hook's redact() masks before writing its journal
SECRET_RE = re.compile(r"(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+|[A-Za-z0-9_-]{32,}|[a-f0-9]{16,}")


def questions() -> list[str]:
    return [q for q in QUESTIONS.read_text(encoding="utf-8").splitlines() if q.strip()]


def agent_command(agent: str, question: str, answer_file: Path) -> list[str]:
    """One fresh, non-interactive session per question; cwd=ROOT is what loads the real instructions."""
    if agent == "claude":
        return ["claude", "-p", "--permission-mode", "plan", question]
    if agent == "kimi":
        # kimi CLI 2026-10: `-p` is the only prompt flag; `--quiet`/`-w` were never accepted on Linux
        return [KIMI_BIN, "-p", question]
    if agent == "codex":
        return ["codex", "exec", "-s", "read-only", "-C", str(ROOT), "--skip-git-repo-check", "--ephemeral",
                "-o", str(answer_file), question]
    raise SystemExit(f"unknown agent {agent!r} (claude, kimi, codex)")


def stderr_tail(text: str) -> str:
    lines = [ln for ln in text.splitlines() if ln.strip()][-STDERR_TAIL_LINES:]
    return " / ".join(SECRET_RE.sub("<REDACTED>", ln.strip()) for ln in lines)


def run(agents: list[str], out: Path, timeout: int) -> int:
    (out / "out").mkdir(parents=True, exist_ok=True)
    for agent in agents:
        for n, question in enumerate(questions(), 1):
            answer = out / "out" / f"{agent}-{n:02d}.md"
            if answer.exists() and answer.stat().st_size > 0:
                continue
            try:
                done = subprocess.run(
                    agent_command(agent, question, answer),
                    cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, check=False,
                )
            except subprocess.TimeoutExpired:
                print(f"{agent} {n:02d} timeout after {timeout}s: no answer saved; rerun to resume")
                continue
            if agent != "codex":  # codex writes the answer file itself (-o)
                answer.write_text(done.stdout, encoding="utf-8")
            line = f"{agent} {n:02d} rc={done.returncode} {answer.stat().st_size if answer.exists() else 0} bytes"
            if done.returncode != 0 and done.stderr:
                line += f"  stderr: {stderr_tail(done.stderr)}"
            print(line)
    print(f"answers in {out / 'out'}; next: blind {out}, grade, score")
    return 0


def answer_files(out: Path) -> dict[tuple[str, int], Path]:
    found = {}
    for f in sorted((out / "out").glob("*-[0-9][0-9].md")):
        agent, num = f.stem.rsplit("-", 1)
        found[(agent, int(num))] = f
    return found


def replay(out: Path) -> int:
    """Run the hook over each answer in an isolated HOME so the live journal stays untouched."""
    flagged = 0
    for (agent, num), f in answer_files(out).items():
        reply = f.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "t.jsonl"
            rows = [
                {"type": "user", "message": {"content": [{"type": "text", "text": "q"}]}},
                {"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}},
            ]
            transcript.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
            (Path(tmp) / "home").mkdir()
            (Path(tmp) / "proj").mkdir()
            subprocess.run(
                ["bash", str(HOOK)],
                input=json.dumps({"transcript_path": str(transcript), "session_id": "a14-replay"}),
                env={**os.environ, "HOME": str(Path(tmp) / "home"), "CLAUDE_PROJECT_DIR": str(Path(tmp) / "proj")},
                capture_output=True, text=True, check=False,
            )
            log = Path(tmp) / "home/.claude/logs/style-violations.log"
            # errors="replace": journals written by the hook before 30.10 hold lines cut mid-character
            # (byte-wise `cut -c`); the rule id in column 3 is ASCII and survives either way
            hits = [ln.split(" | ") for ln in log.read_text(encoding="utf-8", errors="replace").splitlines()] if log.exists() else []
        for parts in hits:
            if len(parts) > 4 and parts[2] in ("A14", "A14_AMBIGUOUS", "A14_STATE_STORED"):
                flagged += 1
                print(f"{agent}-{num:02d}  {parts[2]}: {parts[4][:80]}")
                break
    print(f"flagged answers: {flagged} of {len(answer_files(out))}")
    return 0


def blind(out: Path) -> int:
    files = answer_files(out)
    agents = sorted({a for a, _ in files})
    rng = random.Random(BLIND_SEED)
    key, parts = {}, []
    for n, q in enumerate(questions(), 1):
        present = [a for a in agents if (a, n) in files]
        rng.shuffle(present)
        parts.append(f"## Вопрос {n}: {q}\n")
        for label, agent in zip("ABCDEFGH", present):
            key[f"{n}{label}"] = agent
            text = files[(agent, n)].read_text(encoding="utf-8").strip() or "(пустой ответ)"
            parts.append(f"### Ответ {n}{label}\n\n{text}\n")
    (out / "blind.md").write_text("\n".join(parts), encoding="utf-8")
    (out / "blind-key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"wrote {out / 'blind.md'} and blind-key.json ({len(key)} answers); graders must not see the key")
    return 0


def tally(key: dict[str, str], grades: dict[str, str]) -> dict[str, dict]:
    """Per agent: clean answers by the majority of graders, and failures on questions 1-3."""
    parsed = {g: dict(zip(v.split()[::2], v.split()[1::2])) for g, v in grades.items()}
    result: dict[str, dict] = {}
    for label, agent in key.items():
        votes = [p[label] for p in parsed.values() if label in p]
        if not votes:
            continue
        fails = votes.count("f")
        clean = votes.count("c")
        verdict = "f" if fails * 2 > len(votes) else ("c" if clean * 2 > len(votes) else "s")
        row = result.setdefault(agent, {"clean": 0, "fail": 0, "disputed": 0, "fail_q1_3": 0})
        row[{"c": "clean", "f": "fail", "s": "disputed"}[verdict]] += 1
        if verdict == "f" and int(label[:-1]) <= 3:
            row["fail_q1_3"] += 1
    return result


def score(out: Path, grades_file: Path) -> int:
    key = json.loads((out / "blind-key.json").read_text(encoding="utf-8"))
    result = tally(key, json.loads(grades_file.read_text(encoding="utf-8")))
    ok = True
    for agent, row in sorted(result.items()):
        passed = row["clean"] >= PASS_CLEAN and row["fail_q1_3"] == 0
        ok = ok and passed
        print(f"{agent}: clean={row['clean']} fail={row['fail']} disputed={row['disputed']} "
              f"fail_q1_3={row['fail_q1_3']}  -> {'accepted' if passed else 'NOT accepted'}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--agents", default="claude,kimi,codex")
    r.add_argument("--out", type=Path)
    r.add_argument("--timeout", type=int, default=600)
    for name in ("replay", "blind"):
        sub.add_parser(name).add_argument("dir", type=Path)
    s = sub.add_parser("score")
    s.add_argument("dir", type=Path)
    s.add_argument("grades", type=Path)
    args = ap.parse_args()
    if args.cmd == "run":
        out = args.out or ROOT / ".iwe-runtime/a14-acceptance" / dt.datetime.now().strftime("%Y-%m-%d-%H%M")
        return run(args.agents.split(","), out, args.timeout)
    if args.cmd == "replay":
        return replay(args.dir)
    if args.cmd == "blind":
        return blind(args.dir)
    return score(args.dir, args.grades)


if __name__ == "__main__":
    sys.exit(main())
