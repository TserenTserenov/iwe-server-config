#!/usr/bin/env python3
"""Check pull requests and branches named in a WP card against GitHub (WP-561 Ф60).

Why: on 10.11.2026 an actualization of WP-616 repeated the card's own stale
claim "branch wp616-translator-role, merge request after close" although the
branch had already been merged as PACK-digital-platform #64; the merge was
recorded only in the pack repo. This helper puts the real merge state into
the sync bundle.

What it does:
  * finds references in the card text: "<repo> [PR] #N", GitHub pull URLs and
    "ветка `name`" (attributed to the nearest repo name on the same line);
    repo names are local checkouts with the ecosystem prefixes below, alias
    FMT -> FMT-exocortex-template;
  * asks GitHub once per repo for the recent pull requests, within one total
    time budget for the whole run;
  * flags a mismatch when the text next to a reference disagrees with the
    real state: merged but described as pending, open but called merged,
    closed without merge but not called closed, a branch merged by a pull
    request while the card still describes it as pending.
  Only merges and closures within --days are compared: older status words are
  history, not a claim about the present.

Output: markdown lines on stdout; one "DRIFT: ..." line per mismatch appended
to --drift-file. Exit 0 whenever the card was read (GitHub trouble is
reported in the output, it is not drift); exit 2 on unreadable input.

The GitHub CLI binary can be replaced via WP_MERGE_REFS_GH (used by tests).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ALIASES = {"FMT": "FMT-exocortex-template"}
REPO_NAME_RE = re.compile(r"^(?:(?:DS|PACK|FMT|iwe|MC)-[\w.-]+|FPF|SPF)$")
PR_WINDOW = 300
TOTAL_BUDGET_S = 30.0  # whole run; the bundle runs at every session open
MAX_REPOS = 12
CONTEXT_AFTER = 70
CONTEXT_BEFORE = 40
DEFAULT_DAYS = 14
DEFAULT_BRANCHES = {"main", "master"}

URL_RE = re.compile(r"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
BRANCH_RE = re.compile(r"(?:ветк[а-яё]*|branch)\s+`([A-Za-z0-9][\w./-]*)`", re.IGNORECASE)
BARE_PR_RE = re.compile(r"#(\d+)\b")
MD_LINK_TAIL_RE = re.compile(r"^\]\([^)]*\)")
NEGATION = r"(?<![Нн]е )(?<!будет )"
MERGED_RE = re.compile(NEGATION + r"\b(?:слит[аоы]?|влит[аоы]?|merged|смёрж\w*)\b", re.IGNORECASE)
CLOSED_RE = re.compile(r"\b(?:закрыт\w*|отклон\w*|closed)\b", re.IGNORECASE)
# Words saying "not merged yet"; a bare reference or one next to a commit id is not a claim.
PENDING_RE = re.compile(
    r"(?:жд[её]т|ожида\w*|после\s+закрыти\w*|\bоткрыт\b|на\s+ревью|создать|создам|не\s+создан\w*"
    r"|не\s+(?:слит|влит|смёрж)\w*|черновиком|\bpending\b|\bdraft\b)",
    re.IGNORECASE,
)
TOKEN_RE = re.compile(r"\b(gh[pousr]_|github_pat_)\w+")


@dataclass
class Mention:
    line_no: int
    line: str
    window: str  # text right around the reference, where a status word would sit


@dataclass
class Ref:
    repo: str  # local directory name
    kind: str  # "pr" | "branch"
    key: str  # PR number as string, or branch name
    mentions: list[Mention] = field(default_factory=list)

    def label(self) -> str:
        return f"{self.repo} #{self.key}" if self.kind == "pr" else f"ветка `{self.key}` ({self.repo})"


def local_repos(workspace: Path) -> list[str]:
    if not workspace.is_dir():
        return []
    return sorted(p.name for p in workspace.iterdir() if REPO_NAME_RE.match(p.name) and (p / ".git").exists())


def repo_token_re(repos: list[str]) -> re.Pattern[str] | None:
    names = sorted(set(repos) | {a for a, target in REPO_ALIASES.items() if target in repos}, key=len, reverse=True)
    if not names:
        return None
    alternation = "|".join(re.escape(n) for n in names)
    return re.compile(rf"(?<![\w/-])({alternation})(?![\w-])")


def status_window(line: str, start: int, end: int, token_re: re.Pattern[str], own_repo: str | None = None) -> str:
    """Text a status word would occupy: bounded by the neighbouring references on both sides.

    `own_repo` (branches only): that repo name belongs to the reference itself, so it does not end the window.
    """
    after = line[end:]
    tail = MD_LINK_TAIL_RE.match(after)
    if tail:
        after = after[tail.end() :]
    after = re.split(r"[;#]", after[:CONTEXT_AFTER], maxsplit=1)[0]
    next_repo = next((m for m in token_re.finditer(after) if m.group(1) != own_repo), None)
    if next_repo:
        after = after[: next_repo.start()]
    before = line[max(0, start - CONTEXT_BEFORE) : start]
    if re.search(r"#\d+", before):
        before = ""  # words left of here belong to the previous reference
    before = re.split(r"[;)]", before)[-1]
    return before + line[start:end] + after


def nearest_repo(token_re: re.Pattern[str], line: str, pos: int) -> str | None:
    found = [(abs(m.start() - pos), m.group(1)) for m in token_re.finditer(line)]
    return min(found)[1] if found else None


def collect_refs(text: str, repos: list[str]) -> dict[tuple[str, str, str], Ref]:
    token_re = repo_token_re(repos)
    refs: dict[tuple[str, str, str], Ref] = {}

    def add(repo: str, kind: str, key: str, line_no: int, line: str, start: int, end: int) -> None:
        own = repo if kind == "branch" else None
        mention = Mention(line_no, line, status_window(line, start, end, token_re, own))
        repo = REPO_ALIASES.get(repo, repo)
        refs.setdefault((repo, kind, key), Ref(repo, kind, key)).mentions.append(mention)

    if token_re is None:
        return refs
    pr_re = re.compile(token_re.pattern + r"(?:\s+(?:PR|запрос[а-яё]*(?:\s+на\s+слияние)?))?\s*#(\d+)")
    for line_no, line in enumerate(text.splitlines(), start=1):
        for m in URL_RE.finditer(line):
            if m.group(2) in repos:
                add(m.group(2), "pr", m.group(3), line_no, line, m.start(), m.end())
        for m in pr_re.finditer(line):
            add(m.group(1), "pr", m.group(2), line_no, line, m.start(), m.end())
        for m in BRANCH_RE.finditer(line):
            repo = nearest_repo(token_re, line, m.start())
            if repo and m.group(1) not in DEFAULT_BRANCHES:
                add(repo, "branch", m.group(1), line_no, line, m.start(), m.end())
    return refs


def bare_merged_numbers(text: str, token_re: re.Pattern[str] | None) -> set[str]:
    """Numbers acknowledged as merged without a repo name ("запрос #46 слит")."""
    numbers = set()
    for line in text.splitlines():
        for m in BARE_PR_RE.finditer(line):
            preceding = " ".join(line[max(0, m.start() - 60) : m.start()].split()[-2:])
            if token_re and token_re.search(preceding):
                continue  # "<repo> [PR] #N" is a repo-bound reference, judged per repo
            window = re.split(r"[;#]", line[m.end() : m.end() + 30], maxsplit=1)[0]
            if MERGED_RE.search(window):
                numbers.add(m.group(1))
    return numbers


def github_slug(workspace: Path, repo: str) -> str | None:
    try:
        url = subprocess.run(
            ["git", "-C", str(workspace / repo), "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else None


class GitHubTimeout(Exception):
    pass


def fetch_pulls(slug: str, timeout_s: float) -> list[dict] | str:
    """Recent pull requests of one repo, or an error text; raises GitHubTimeout on a hang."""
    gh = os.environ.get("WP_MERGE_REFS_GH", "gh")
    fields = "number,state,headRefName,mergedAt,closedAt"
    cmd = [gh, "pr", "list", "-R", slug, "--state", "all", "--limit", str(PR_WINDOW), "--json", fields]
    try:
        done = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired as exc:
        raise GitHubTimeout from exc
    except (OSError, subprocess.SubprocessError) as exc:
        return type(exc).__name__
    if done.returncode != 0:
        last = (done.stderr.strip().splitlines() or [f"код {done.returncode}"])[-1][:160]
        return TOKEN_RE.sub(r"\1***", last)
    try:
        pulls = json.loads(done.stdout)
    except json.JSONDecodeError:
        return "ответ не JSON"
    if not isinstance(pulls, list) or not all(isinstance(p, dict) for p in pulls):
        return "неожиданная форма ответа"
    return pulls


def says_merged(ref: Ref) -> bool:
    return any(MERGED_RE.search(m.window) for m in ref.mentions)


def says_closed(ref: Ref) -> bool:
    return any(CLOSED_RE.search(m.window) for m in ref.mentions)


def says_pending(ref: Ref) -> bool:
    return any(PENDING_RE.search(m.window) for m in ref.mentions)


def changed_since(pr: dict, since: datetime) -> bool:
    stamp = pr.get("mergedAt") or pr.get("closedAt")
    if not stamp:
        return True  # still open: always current
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")) >= since
    except ValueError:
        return True  # unknown date: compare rather than hide


def short_time(pr: dict) -> str:
    return str(pr.get("mergedAt") or "")[:16].replace("T", " ")


def judge(ref: Ref, pulls: list[dict], merged_numbers_in_card: set[str], since: datetime) -> str | None:
    """Mismatch description, None when the card agrees; raises LookupError when there is nothing to compare."""
    if ref.kind == "pr":
        pr = next((p for p in pulls if str(p.get("number")) == ref.key), None)
        if pr is None or not changed_since(pr, since):
            raise LookupError
        state, when = pr.get("state"), short_time(pr)
        if state == "MERGED" and ref.key not in merged_numbers_in_card and says_pending(ref) and not says_merged(ref):
            return f"слит {when} UTC, а карточка пишет о нём как о неслитом"
        if state == "OPEN" and says_merged(ref):
            return "открыт, а карточка называет его слитым"
        if state == "CLOSED" and not says_closed(ref):
            return "закрыт без слияния, а карточка этого не говорит"
        return None
    merged = [
        p for p in pulls if p.get("headRefName") == ref.key and p.get("state") == "MERGED" and changed_since(p, since)
    ]
    if not merged:
        raise LookupError
    numbers = [str(p.get("number")) for p in merged]
    if says_merged(ref) or not says_pending(ref) or any(n in merged_numbers_in_card for n in numbers):
        return None
    return f"слита запросом #{', #'.join(numbers)} ({short_time(merged[0])} UTC), а карточка пишет о ней как о неслитой"


def check_repo(refs: list[Ref], pulls: list[dict], bare_merged: set[str], since: datetime) -> tuple[int, list[str]]:
    merged_in_card = bare_merged | {r.key for r in refs if r.kind == "pr" and says_merged(r)}
    compared, mismatches = 0, []
    for ref in refs:
        try:
            problem = judge(ref, pulls, merged_in_card, since)
        except LookupError:
            continue
        compared += 1
        if problem:
            first = ref.mentions[0]
            mismatches.append(f"{ref.label()} — {problem}; строка {first.line_no}: «{first.line.strip()[:200]}»")
    return compared, mismatches


def render(card: Path, workspace: Path, drift_file: Path | None, days: int) -> int:
    text = card.read_text(encoding="utf-8")
    repos = local_repos(workspace)
    refs = collect_refs(text, repos)
    bare_merged = bare_merged_numbers(text, repo_token_re(repos))
    since = datetime.now(timezone.utc) - timedelta(days=days)
    print("## Запросы на слияние и ветки из карточки (РП-561 Ф60)")
    if not refs:
        print("- В карточке нет ссылок на запросы на слияние или ветки известных хранилищ.")
        print()
        return 0

    by_repo: dict[str, list[Ref]] = {}
    for ref in refs.values():
        by_repo.setdefault(ref.repo, []).append(ref)

    deadline = time.monotonic() + TOTAL_BUDGET_S
    compared, mismatches, unavailable = 0, [], []
    order = sorted(by_repo)
    for index, repo in enumerate(order[:MAX_REPOS]):
        remaining = deadline - time.monotonic()
        if remaining <= 1:
            unavailable.append(f"{', '.join(order[index:MAX_REPOS])}: исчерпан бюджет {TOTAL_BUDGET_S:.0f} с")
            break
        slug = github_slug(workspace, repo)
        try:
            pulls = fetch_pulls(slug, remaining) if slug else "нет адреса origin на GitHub"
        except GitHubTimeout:
            unavailable.append(f"{', '.join(order[index:MAX_REPOS])}: GitHub не ответил, опрос остановлен")
            break
        if isinstance(pulls, str):
            unavailable.append(f"{repo}: {pulls}")
            continue
        repo_compared, repo_mismatches = check_repo(by_repo[repo], pulls, bare_merged, since)
        compared += repo_compared
        mismatches += repo_mismatches

    print(f"- Сверено ссылок: {compared} (слияния и закрытия за {days} дн.); расхождений: {len(mismatches)}")
    for item in mismatches:
        print(f"- ⚠️ {item}")
    for item in unavailable:
        print(f"- Проверка недоступна — {item} (это не расхождение, состояние не известно)")
    if order[MAX_REPOS:]:
        print(f"- Не проверялись (лимит {MAX_REPOS} хранилищ): {', '.join(order[MAX_REPOS:])}")
    print()

    if drift_file and mismatches:
        with drift_file.open("a", encoding="utf-8") as out:
            out.writelines(f"DRIFT: merge_ref_mismatch — {item}\n" for item in mismatches)
    return 0


def env_days() -> int:
    raw = os.environ.get("WP_SYNC_GIT_DAYS", "")
    return int(raw) if raw.isdigit() else DEFAULT_DAYS


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("card", type=Path)
    parser.add_argument("--workspace", type=Path, default=Path(os.environ.get("IWE_WORKSPACE", Path.home() / "IWE")))
    parser.add_argument("--drift-file", type=Path)
    parser.add_argument("--days", type=int, default=env_days())
    args = parser.parse_args()
    try:
        return render(args.card, args.workspace, args.drift_file, args.days)
    except (OSError, UnicodeDecodeError) as exc:
        print(f"[ERROR] wp-merge-refs-check: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
