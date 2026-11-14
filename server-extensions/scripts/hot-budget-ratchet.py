#!/usr/bin/env python3
"""Hot-core ratchet: the always-loaded instructions may not grow (WP-7 F299, block 5).

The hot set is what Claude Code loads into every session from this repository:
CLAUDE.md and every .claude/rules/**/*.md (the harness loads that folder
recursively, so the set is a glob, not a hand-kept list).

check — compare the hot set at --base and --head:
  FAIL  growth (head > base): adding N bytes needs removing at least N in the
        same change (one-for-one eviction);
  FAIL  while head is above the M2 target, a large change (more than
        TRIVIAL_CHANGE_BYTES of changed lines) that does not shrink the set;
  PASS  otherwise, and small edits of any sign within the trivial threshold.
  A failing change passes as WAIVED only with a waiver: the PR label
  hot-budget-waiver (--waiver-label) or a commit trailer "Hot-Budget-Waiver:",
  plus "Причина: ..." and "Пересмотр: YYYY-MM-DD" in the --waiver-text.
waivers — print a markdown snapshot of merged PRs labelled hot-budget-waiver
  (needs gh), for the weekly rules review.

Exit: 0 PASS or WAIVED, 1 FAIL, 2 usage or git error.
"""

import argparse
import datetime
import fnmatch
import json
import re
import subprocess
import sys

HOT_GLOBS = ("CLAUDE.md", ".claude/rules/*.md", ".claude/rules/**/*.md")
# Agent-specific blocks land whole in the generated AGENTS.md that Kimi, Codex and
# Grok read (WP-7 F309). Not part of Claude's M2 budget, so a separate set that
# only may not grow.
AGENTS_GLOBS = ("AGENTS-agent-blocks.md",)
BYTES_PER_TOKEN = (
    3.105  # calibrated ratio, same as verify-context-budget.sh (median-ratio.conf)
)
M2_TOKENS = 12000
TRIVIAL_CHANGE_BYTES = 200
WAIVER_LABEL = "hot-budget-waiver"
# File headers of a unified diff; a content line "---" shows up as "----", not as these.
DIFF_HEADERS = ("--- a/", "+++ b/", "--- /dev/null", "+++ /dev/null")
REASON = re.compile(r"Причина:[ \t]*\S")  # the reason must be on the same line
REVIEW_DATE = re.compile(r"Пересмотр:\s*(\d{4}-\d{2}-\d{2})")


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True, check=True
    ).stdout


STAGED = ":staged"  # pseudo-ref: the index, for a local commit hook


def hot_paths(repo, ref, globs=HOT_GLOBS):
    if ref == STAGED:
        names = git(repo, "ls-files").splitlines()
    else:
        names = git(repo, "ls-tree", "-r", "--name-only", ref).splitlines()
    return sorted(n for n in names if any(fnmatch.fnmatchcase(n, g) for g in globs))


def hot_bytes(repo, ref, globs=HOT_GLOBS):
    total = 0
    for path in hot_paths(repo, ref, globs):
        total += len(
            subprocess.run(
                [
                    "git",
                    "-C",
                    repo,
                    "show",
                    f":{path}" if ref == STAGED else f"{ref}:{path}",
                ],
                capture_output=True,
                check=True,
            ).stdout
        )
    return total


def changed_bytes(repo, base, head):
    """Bytes of changed content in the hot set between base and head.

    Definition: sum over every added or removed line of the unified diff
    (lines starting with "+" or "-", file headers "+++"/"---" excluded) of
    len(line in UTF-8) - 1, i.e. the line's own bytes without the +/- prefix
    and without the newline. Ten rewritten lines of 99 ASCII chars give 990.
    """
    # Explicit paths, not the globs: a plain pathspec does not treat ** as recursive.
    paths = sorted(set(hot_paths(repo, base)) | set(hot_paths(repo, head)))
    if not paths:
        return 0
    if head == STAGED:
        diff = git(repo, "diff", "--cached", "--unified=0", base, "--", *paths)
    else:
        diff = git(repo, "diff", "--unified=0", base, head, "--", *paths)
    return sum(
        len(line.encode()) - 1
        for line in diff.splitlines()
        if line[:1] in "+-" and not line.startswith(DIFF_HEADERS)
    )


def waiver_ok(label, text):
    """A waiver needs the label or trailer, a reason and a review date."""
    if not (label or "Hot-Budget-Waiver:" in text):
        return False, "нет метки hot-budget-waiver или строки Hot-Budget-Waiver:"
    if not REASON.search(text):
        return False, "в исключении нет строки «Причина: …»"
    match = REVIEW_DATE.search(text)
    if not match:
        return False, "в исключении нет строки «Пересмотр: ГГГГ-ММ-ДД»"
    try:
        datetime.date.fromisoformat(match.group(1))
    except ValueError:
        return False, f"дата пересмотра «{match.group(1)}» не дата"
    return True, ""


def verdict(base_b, head_b, changed, label, text, agents_growth=0):
    head_tokens = round(head_b / BYTES_PER_TOKEN)
    problems = []
    if agents_growth > 0:
        problems.append(
            f"блок агентов (AGENTS-agent-blocks.md) вырос на {agents_growth} байт — уберите столько же в этой правке"
        )
    if head_b > base_b:
        problems.append(
            f"горячий набор вырос на {head_b - base_b} байт — уберите столько же в этой правке"
        )
    if head_tokens > M2_TOKENS and changed > TRIVIAL_CHANGE_BYTES and head_b >= base_b:
        problems.append(
            f"ядро выше цели {M2_TOKENS} токенов, а крупная правка ({changed} байт) его не уменьшает"
        )
    if not problems:
        return "PASS", problems
    ok, why = waiver_ok(label, text)
    if ok:
        return "WAIVED", problems
    return "FAIL", problems + [why]


def check(args):
    try:
        base_b, head_b = (
            hot_bytes(args.repo, args.base),
            hot_bytes(args.repo, args.head),
        )
        changed = changed_bytes(args.repo, args.base, args.head)
        agents_base, agents_head = (
            hot_bytes(args.repo, args.base, AGENTS_GLOBS),
            hot_bytes(args.repo, args.head, AGENTS_GLOBS),
        )
    except subprocess.CalledProcessError as error:
        print(f"git failed: {error.stderr.strip()}", file=sys.stderr)
        return 2
    text = ""
    if args.waiver_text_file:
        with open(args.waiver_text_file, encoding="utf-8") as handle:
            text = handle.read()
    result, problems = verdict(
        base_b, head_b, changed, args.waiver_label, text, agents_head - agents_base
    )
    head_tokens = round(head_b / BYTES_PER_TOKEN)
    print(
        f"{result}: горячий набор {base_b} → {head_b} байт ({head_b - base_b:+d}), "
        f"~{head_tokens} токенов, до цели {M2_TOKENS}: {head_tokens - M2_TOKENS:+d}; изменено {changed} байт"
    )
    print(
        f"  блок агентов: {agents_base} → {agents_head} байт ({agents_head - agents_base:+d})"
    )
    for problem in problems:
        print(f"  - {problem}")
    return 1 if result == "FAIL" else 0


def waivers(args):
    out = subprocess.run(
        [
            "gh",
            "pr",
            "list",
            "-R",
            args.github_repo,
            "--label",
            WAIVER_LABEL,
            "--state",
            "merged",
            "--limit",
            "200",
            "--json",
            "number,title,body,mergedAt,url",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        print(f"gh failed: {out.stderr.strip()}", file=sys.stderr)
        return 2
    prs = json.loads(out.stdout or "[]")
    print(
        f"# Исключения из храповика горячего ядра — снимок {datetime.date.today().isoformat()}\n"
    )
    print(
        f"Репозиторий: {args.github_repo}; слитых запросов с меткой {WAIVER_LABEL}: {len(prs)}\n"
    )
    for pr in sorted(prs, key=lambda p: p["mergedAt"]):
        body = pr.get("body") or ""
        reason = next(
            (ln.strip() for ln in body.splitlines() if REASON.search(ln)),
            "причина не указана",
        )
        review = REVIEW_DATE.search(body)
        overdue = review and review.group(1) < datetime.date.today().isoformat()
        print(
            f"- #{pr['number']} ({pr['mergedAt'][:10]}) {pr['title']} — {reason}; "
            f"пересмотр {review.group(1) if review else 'не указан'}{' — ПРОСРОЧЕН' if overdue else ''} {pr['url']}"
        )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Hot-core ratchet (WP-7 F299)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--repo", default=".")
    c.add_argument("--base", required=True)
    c.add_argument(
        "--head",
        default="HEAD",
        help=f"a ref, or {STAGED} for the index (local commit hook)",
    )
    c.add_argument(
        "--waiver-label",
        action="store_true",
        help="the PR carries the hot-budget-waiver label",
    )
    c.add_argument(
        "--waiver-text-file",
        help="PR body or commit messages with Причина/Пересмотр lines",
    )
    w = sub.add_parser("waivers")
    w.add_argument("--github-repo", default="TserenTserenov/iwe-local-config")
    args = parser.parse_args(argv)
    return check(args) if args.cmd == "check" else waivers(args)


if __name__ == "__main__":
    sys.exit(main())
