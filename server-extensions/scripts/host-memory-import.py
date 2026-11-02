#!/usr/bin/env python3
"""Import new memory notes from another host into this host's memory/ (WP-529 F248).

Design: DRR-f248-kanal-pamyati-mezhdu-hostami (variant A', one-way).
Each host keeps its own memory; this tool only adds notes whose name this
memory/ never had (not in the tree, not in its git history), so a note
deleted here on purpose is not brought back. Existing notes are never
overwritten. Canon files and host indexes are skipped. Every candidate is
scanned with gitleaks first; a missing scanner stops the import.

A control record (name -> sha256 of the source at import) lets later runs
see that a note changed on the source host after it was copied; such notes
go to the report for the weekly review instead of being overwritten.

Runs at most once a day unless --force. Exit code is always 0 for
best-effort callers; the outcome is printed.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_SOURCE = "tsekh-1:.claude/projects/-home-tseren-IWE/memory/"
CANON_DIR = ".claude/memory-canon"
HOST_INDEXES = {"MEMORY.md", "MEMORY-warm.md"}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "wb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)


def read_state(path):
    state = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            name, digest, day = line.split("\t")
            state[name] = (digest, day)
    return state


def names_in_history(memory):
    """Every .md name memory/ ever tracked; empty when memory/ is not a git repo."""
    if not (memory / ".git").exists():
        return set()
    out = subprocess.run(["git", "-C", str(memory), "log", "--all", "--name-only", "--format="],
                         check=True, capture_output=True, text=True).stdout
    return {line for line in out.splitlines() if line.endswith(".md") and "/" not in line}


def fetch(source, staging):
    # rsync copies the source dir mode onto staging, so privacy is held by the parent
    staging.mkdir(parents=True, exist_ok=True)
    os.chmod(staging.parent, 0o700)
    subprocess.run(["rsync", "-a", "--checksum", "--delete", "--include=*.md", "--exclude=*",
                    "-e", "ssh -o BatchMode=yes -o ConnectTimeout=5", source, f"{staging}/"],
                   check=True, capture_output=True)


def flagged_by_scanner(staging, scanner):
    report = staging.parent / "gitleaks.json"
    result = subprocess.run([scanner, "dir", str(staging), "--no-banner", "--redact", "-r", str(report)],
                            capture_output=True)
    if result.returncode not in (0, 1):
        raise OSError(f"gitleaks завершился с кодом {result.returncode}")
    findings = json.loads(report.read_text(encoding="utf-8") or "[]")
    report.unlink()
    flagged = {Path(f["File"]).name for f in findings}
    return flagged | {p.name for p in staging.glob("*.md")
                      if has_plain_password(p.read_text(encoding="utf-8", errors="replace"))}


# gitleaks misses passwords written as a labelled value or inside SQL; both
# forms carried live DB passwords between hosts before 02.11 (WP-529 F248).
PLACEHOLDER = re.compile(r"^(<|\*|\$|\{|\[|\.\.\.|x+$)", re.I)
CREDENTIAL_FORMS = (
    re.compile(r"(?:пароль|password)[^:\n]{0,40}:(?:\*\*)?\s*`?([^\s`]{6,})", re.I),
    re.compile(r"PASSWORD\s+'([^']{6,})'", re.I),
    re.compile(r"postgres(?:ql)?://[^:/@\s]+:([^@\s]+)@"),
)


def has_plain_password(text):
    return any(not PLACEHOLDER.match(m.group(1))
               for form in CREDENTIAL_FORMS for m in form.finditer(text))


def note_lines(text):
    """Body lines of a note; frontmatter is host bookkeeping and is ignored."""
    if text.startswith("---\n") and "\n---" in text[4:]:
        text = text[4:].split("\n---", 1)[1]
    return {line.strip() for line in text.splitlines() if line.strip()}


def has_lines_missing_here(src, target, memory):
    """True when the source note has a line no version of the local note ever had.

    Frontmatter is ignored, and a source that is an old copy of a note
    rewritten here is not reported.
    """
    missing = note_lines(src.read_text(encoding="utf-8", errors="replace")) - note_lines(
        target.read_text(encoding="utf-8", errors="replace"))
    if not missing or not (memory / ".git").exists():
        return bool(missing)
    commits = subprocess.run(["git", "-C", str(memory), "log", "--all", "--format=%H", "--", target.name],
                             check=True, capture_output=True, text=True).stdout.split()
    for commit in commits:
        past = subprocess.run(["git", "-C", str(memory), "show", f"{commit}:{target.name}"],
                              capture_output=True, text=True, errors="replace")
        missing -= note_lines(past.stdout)
        if not missing:
            return False
    return True


def plan(staging, memory, root, state, reviewed):
    """`reviewed` maps a name to the source digest already judged in a weekly review."""
    skip = HOST_INDEXES | {p.name for p in (root / CANON_DIR).glob("*.md")}
    history = names_in_history(memory)
    new, changed_at_source, both_differ = [], [], []
    for src in sorted(staging.glob("*.md")):
        name = src.name
        if name in skip:
            continue
        digest = sha256(src.read_bytes())
        record = state.get(name)
        if record is not None:
            if digest != record[0]:
                changed_at_source.append(name)
            continue
        target = memory / name
        if target.exists() or name in history:
            if reviewed.get(name) == digest:
                continue
            if target.exists() and has_lines_missing_here(src, target, memory):
                both_differ.append(name)
            continue
        new.append((name, digest))
    return new, changed_at_source, both_differ


def write_report(path, source, imported, refused, changed_at_source, both_differ):
    def section(title, names):
        body = "".join(f"- {n}\n" for n in names) or "- нет\n"
        return f"\n## {title} ({len(names)})\n\n{body}"
    text = (f"# Перенос памяти с другого хоста — {datetime.date.today().isoformat()}\n\n"
            f"Источник: `{source}`. Отчёт пересоздаётся каждым прогоном; разбор — на закрытии недели.\n"
            + section("Перенесены", imported)
            + section("Не перенесены: сканер секретов", refused)
            + section("Изменены на источнике после переноса", changed_at_source)
            + section("Есть на обоих хостах, на источнике есть строки, которых нет здесь", both_differ))
    write_atomic(path, text.encode())


def run(args):
    root, memory, runtime = Path(args.root), Path(args.memory), Path(args.runtime)
    stamp = runtime / "last-run"
    today = datetime.date.today().isoformat()
    if not args.force and stamp.exists() and stamp.read_text().strip() == today:
        return None
    scanner = shutil.which("gitleaks")
    if scanner is None:
        raise OSError("нет gitleaks — без сканера секретов перенос не выполняется")
    staging = runtime / "staging"
    fetch(args.source, staging)
    state_path = runtime / "state.tsv"
    state = read_state(state_path)
    reviewed_path = runtime / "reviewed.tsv"
    reviewed = {n: d for n, (d, _) in read_state(reviewed_path).items()}
    new, changed_at_source, both_differ = plan(staging, memory, root, state, reviewed)
    if args.mark_reviewed and not args.dry_run:
        for name in both_differ:
            reviewed[name] = sha256((staging / name).read_bytes())
        write_atomic(reviewed_path, "".join(f"{n}\t{d}\t{today}\n" for n, d in sorted(reviewed.items())).encode())
        both_differ = []
    flagged = flagged_by_scanner(staging, scanner) if new else set()
    imported, refused = [], []
    for name, digest in new:
        if name in flagged:
            refused.append(name)
            continue
        if not args.dry_run:
            write_atomic(memory / name, (staging / name).read_bytes())
            state[name] = (digest, today)
        imported.append(name)
    write_report(runtime / "report.md", args.source, imported, refused, changed_at_source, both_differ)
    if args.dry_run:
        return imported, refused, changed_at_source, both_differ
    write_atomic(state_path, "".join(f"{n}\t{d}\t{day}\n" for n, (d, day) in sorted(state.items())).encode())
    if imported and (memory / ".git").exists():
        subprocess.run(["git", "-C", str(memory), "add", "--", *imported], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(memory), "commit", "-q", "-m",
                        f"host-memory-import: {len(imported)} заметок с {args.source.split(':')[0]}"],
                       check=True, capture_output=True)
    write_atomic(stamp, today.encode())
    return imported, refused, changed_at_source, both_differ


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.environ.get("IWE_ROOT_DIR", str(Path.home() / "IWE")))
    parser.add_argument("--memory", help="memory directory (default: <root>/memory)")
    parser.add_argument("--runtime", help="state dir (default: <root>/.iwe-runtime/host-memory-import)")
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="rsync source of the other host's memory/")
    parser.add_argument("--force", action="store_true", help="run even if already ran today")
    parser.add_argument("--dry-run", action="store_true", help="report only, write nothing to memory/")
    parser.add_argument("--mark-reviewed", action="store_true",
                        help="after the weekly review: stop reporting the listed divergent notes "
                             "until their source changes")
    args = parser.parse_args()
    args.memory = args.memory or str(Path(args.root) / "memory")
    args.runtime = args.runtime or str(Path(args.root) / ".iwe-runtime/host-memory-import")
    try:
        outcome = run(args)
    except (subprocess.CalledProcessError, OSError, ValueError) as exc:
        print(f"[host-memory-import] память не тронута: {exc}", file=sys.stderr)
        return 0
    if outcome is None:
        return 0
    imported, refused, changed, differ = outcome
    mode = "пробный прогон, " if args.dry_run else ""
    print(f"[host-memory-import] {mode}перенесено {len(imported)}, отказ сканера {len(refused)}, "
          f"изменены на источнике {len(changed)}, расходятся {len(differ)} — отчёт {args.runtime}/report.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
