#!/usr/bin/env python3
"""Show the real state of external repositories next to a WP card (WP-561 Ф74).

Why: on 17-18.11.2026 the template release 0.42.1 was built in the template
repository (a release branch and tags rc.1..rc.6), while the card of the WP
still said "start with #1567/#1568", already closed. The sync bundle reads only
the text of the card, so it could not see work that happens elsewhere.

What it does:
  * finds what to watch for the card: a `watch:` line in the card front matter
    (one JSON value, replaces the registry entry; `watch: []` switches watching
    off) or the registry entry for the WP number in the registry file (JSON:
    {"version": 1, "watch": {"529": [<spec>, ...]}});
  * a spec is {"repo": "<local checkout name>" or "slug": "Org/name",
    "branches": ["release/*"], "tags": ["v*"], "keywords": ["0.42"]};
  * asks GitHub for tags, branches, pull requests, issues and failed runs and
    lists the events that are newer than the card revision and are not named in
    the card text ("review" signal, weaker than the DRIFT of the merge helper);
  * a branch has no creation time, so it is judged by its last commit and by
    whether the card names it; this is said in the output.

Output: markdown lines on stdout; one "REVIEW: external_state — ..." line per
repository with events is appended to --drift-file. Exit 0 whenever the card
was read (GitHub trouble prints UNKNOWN, it is not a review signal); exit 2 on
unreadable input.

The GitHub CLI binary can be replaced via WP_WATCH_GH (used by tests); the
cache of the last successful answers lives in WP_WATCH_CACHE_DIR.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

TOTAL_BUDGET_S = 30.0  # whole run; the bundle runs at every session open
MAX_EVENT_LINES = 15
MAX_RUN_BRANCHES = 3
LIST_LIMIT = 100
DEFAULT_DAYS = 14
TOKEN_RE = re.compile(r"\b(gh[pousr]_|github_pat_)\w+")
FRONT_WATCH_RE = re.compile(r"^watch:\s*(.*?)\s*$")

REFS_QUERY = (
    "query($owner:String!,$name:String!,$prefix:String!,$needle:String!){repository(owner:$owner,name:$name)"
    "{refs(refPrefix:$prefix,query:$needle,first:100,orderBy:{field:TAG_COMMIT_DATE,direction:DESC}){totalCount nodes{name target{__typename "
    "... on Commit{committedDate} ... on Tag{tagger{date} target{... on Commit{committedDate}}}}}}}}"
)


class GitHubTimeout(Exception):
    pass


class GitHubError(Exception):
    pass


def parse_time(stamp: object) -> datetime | None:
    if not stamp:
        return None
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return None


def short(stamp: datetime | None) -> str:
    return stamp.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M") if stamp else "время неизвестно"


def front_matter_watch(text: str) -> tuple[bool, object]:
    """(present, value) of the `watch:` line in the front matter; value is parsed JSON."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return False, None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        found = FRONT_WATCH_RE.match(line)
        if found:
            try:
                return True, json.loads(found.group(1))
            except json.JSONDecodeError as exc:
                raise ValueError(f"watch: в карточке не разобран как JSON ({exc.msg})") from exc
    return False, None


def registry_watch(registry: Path | None, wp: str) -> list[dict] | None:
    if registry is None or not registry.is_file():
        return None
    data = json.loads(registry.read_text(encoding="utf-8"))
    entry = (data.get("watch") or {}).get(str(wp))
    return entry if isinstance(entry, list) else None


def local_slug(workspace: Path, repo: str) -> str | None:
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
    found = re.search(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?$", url)
    return f"{found.group(1)}/{found.group(2)}" if found else None


class Gh:
    """Thin GitHub CLI wrapper with one shared time budget and a cache of the last good answers."""

    def __init__(self, budget_s: float, cache_dir: Path | None) -> None:
        self.binary = os.environ.get("WP_WATCH_GH", "gh")
        self.deadline = time.monotonic() + budget_s
        self.cache_dir = cache_dir
        self.cache_age_min: dict[str, int] = {}

    def _cache_file(self, key: str) -> Path | None:
        if self.cache_dir is None:
            return None
        return self.cache_dir / (re.sub(r"[^\w.-]+", "_", key) + ".json")

    def call(self, key: str, args: list[str]) -> object:
        """JSON answer; on failure the cached answer of the same key, else GitHubError/GitHubTimeout."""
        remaining = self.deadline - time.monotonic()
        if remaining <= 1:
            raise GitHubTimeout
        try:
            done = subprocess.run([self.binary, *args], check=False, capture_output=True, text=True, timeout=remaining)
            if done.returncode != 0:
                last = (done.stderr.strip().splitlines() or [f"код {done.returncode}"])[-1][:160]
                raise GitHubError(TOKEN_RE.sub(r"\1***", last))
            answer = json.loads(done.stdout)
        except subprocess.TimeoutExpired as exc:
            raise GitHubTimeout from exc
        except json.JSONDecodeError as exc:
            raise GitHubError("ответ не JSON") from exc
        except OSError as exc:
            raise GitHubError(type(exc).__name__) from exc
        self._store(key, answer)
        return answer

    def cached_or_raise(self, key: str, error: Exception) -> object:
        path = self._cache_file(key)
        if path is not None and path.is_file():
            try:
                cached = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                raise error from None  # a damaged cache is no answer: report the original GitHub trouble
            self.cache_age_min[key] = int((time.time() - path.stat().st_mtime) // 60)
            return cached
        raise error

    def _store(self, key: str, answer: object) -> None:
        path = self._cache_file(key)
        if path is None:
            return
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(answer), encoding="utf-8")
        except OSError:
            pass  # the cache is a convenience; a read-only home must not break the bundle

    def get(self, key: str, args: list[str]) -> object:
        try:
            return self.call(key, args)
        except (GitHubError, GitHubTimeout) as exc:
            return self.cached_or_raise(key, exc)


def mask_needle(mask: str) -> str:
    """Literal head of a mask: GitHub filters ref names by it, a repo can have hundreds of branches."""
    return re.split(r"[*?\[]", mask, maxsplit=1)[0]


def ref_nodes(gh: Gh, slug: str, prefix: str, masks: list[str], notes: list[str]) -> list[dict]:
    """Refs whose names contain the literal head of any mask (the caller still applies the masks)."""
    owner, name = slug.split("/", 1)
    nodes: dict[str, dict] = {}
    for needle in sorted({mask_needle(m) for m in masks}):
        args = ["api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"prefix={prefix}",
                "-F", f"needle={needle}", "-f", f"query={REFS_QUERY}"]
        data = gh.get(f"{slug}-{prefix}-{needle}", args)
        try:
            refs = data["data"]["repository"]["refs"]  # type: ignore[index]
            found = refs["nodes"]
        except (KeyError, TypeError) as exc:
            raise GitHubError("неожиданная форма ответа") from exc
        total = refs.get("totalCount")
        if isinstance(total, int) and total > len(found):
            notes.append(f"по началу «{needle}» в {prefix} найдено {total}, просмотрено {len(found)} — остальные не сравнивались")
        nodes.update({str(n["name"]): n for n in found if isinstance(n, dict) and n.get("name")})
    return list(nodes.values())


def branch_time(node: dict) -> datetime | None:
    """Last commit time of a branch (a branch has no creation time)."""
    return parse_time((node.get("target") or {}).get("committedDate"))


def tag_time(node: dict) -> tuple[datetime | None, str]:
    """(time, source) of a tag: annotated tags carry their own date, light tags only the commit date."""
    target = node.get("target") or {}
    if target.get("__typename") == "Tag":
        tagged = parse_time((target.get("tagger") or {}).get("date"))
        if tagged:
            return tagged, "дата метки"
        return parse_time((target.get("target") or {}).get("committedDate")), "дата коммита метки"
    return parse_time(target.get("committedDate")), "дата коммита метки"


def mentioned(card_text: str, name: str) -> bool:
    """Whole-name mention: v0.42.1-rc.1 is not named by v0.42.1-rc.10, a tag is not named by its branch release/<tag>."""
    return re.search(rf"(?<![\w/.-]){re.escape(name)}(?![\w-]|\.\w)", card_text) is not None


def matches(name: str, masks: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(name, mask) for mask in masks)


def watch_repo(gh: Gh, slug: str, spec: dict, card_text: str, since: datetime) -> tuple[list[str], list[str], int]:
    """(event lines, notes, count) for one watched repository."""
    events: list[str] = []
    notes: list[str] = []
    branch_masks = [str(m) for m in spec.get("branches") or []]
    tag_masks = [str(m) for m in spec.get("tags") or []]
    keywords = [str(k).lower() for k in spec.get("keywords") or []]

    untimed = 0
    for node in ref_nodes(gh, slug, "refs/tags/", tag_masks, notes) if tag_masks else []:
        name = str(node["name"])
        if not matches(name, tag_masks) or mentioned(card_text, name):
            continue
        when, source = tag_time(node)
        if when is None:
            untimed += 1
        elif when >= since:
            events.append(f"метка {name} ({short(when)} UTC, {source}) — в карточке не названа")
    if untimed:
        notes.append(f"у {untimed} меток нет времени — не сравнивались")

    active_branches: list[str] = []
    untimed_branches = 0
    for node in ref_nodes(gh, slug, "refs/heads/", branch_masks, notes) if branch_masks else []:
        name = str(node["name"])
        if not matches(name, branch_masks):
            continue
        when = branch_time(node)
        if when is None:
            untimed_branches += 1
        elif when >= since:
            active_branches.append(name)
            if not mentioned(card_text, name):
                events.append(
                    f"ветка {name} обнаружена, время появления неизвестно (последний коммит {short(when)} UTC) — в карточке не названа"
                )
    if untimed_branches:
        notes.append(f"у {untimed_branches} веток нет времени последнего коммита — не сравнивались")

    if keywords or branch_masks:
        events += item_events(gh, slug, "pr", keywords, branch_masks, card_text, since)
    if keywords:
        events += item_events(gh, slug, "issue", keywords, [], card_text, since)
    for name in active_branches[:MAX_RUN_BRANCHES]:
        events += failed_runs(gh, slug, name, since)
    if len(active_branches) > MAX_RUN_BRANCHES:
        notes.append(f"сборки проверены у {MAX_RUN_BRANCHES} из {len(active_branches)} активных веток")
    return events, notes, len(events)


def item_events(
    gh: Gh, slug: str, kind: str, keywords: list[str], branch_masks: list[str], card_text: str, since: datetime
) -> list[str]:
    fields = "number,title,state,createdAt,closedAt" + (",headRefName,mergedAt" if kind == "pr" else "")
    items = gh.get(f"{slug}-{kind}", [kind, "list", "-R", slug, "--state", "all", "--limit", str(LIST_LIMIT), "--json", fields])
    out: list[str] = []
    for item in items if isinstance(items, list) else []:
        number = str(item.get("number"))
        branch = str(item.get("headRefName") or "")
        text = f"{item.get('title', '')} {branch}".lower()
        relevant = any(k in text for k in keywords) or (branch and matches(branch, branch_masks))
        if not relevant or re.search(rf"#{re.escape(number)}\b", card_text):
            continue
        stamps = [parse_time(item.get(f)) for f in ("mergedAt", "closedAt", "createdAt")]
        when = max((s for s in stamps if s), default=None)
        if when is None or when < since:
            continue
        label = "запрос на слияние" if kind == "pr" else "обращение"
        state = {"MERGED": "слит", "CLOSED": "закрыт", "OPEN": "открыт"}.get(str(item.get("state")), str(item.get("state")))
        out.append(f"{label} #{number} {state} ({short(when)} UTC) «{str(item.get('title', ''))[:80]}» — в карточке не назван")
    return out


def failed_runs(gh: Gh, slug: str, branch: str, since: datetime) -> list[str]:
    runs = gh.get(
        f"{slug}-runs-{branch}",
        ["run", "list", "-R", slug, "--branch", branch, "--limit", "10", "--json", "conclusion,createdAt,workflowName"],
    )
    out: list[str] = []
    for run in runs if isinstance(runs, list) else []:
        when = parse_time(run.get("createdAt"))
        if run.get("conclusion") == "failure" and when and when >= since:
            out.append(f"красная сборка «{run.get('workflowName', '?')}» на ветке {branch} ({short(when)} UTC)")
    return out


def resolve_specs(card_text: str, registry: Path | None, wp: str) -> tuple[list[dict] | None, str]:
    """(specs, origin): origin is 'card', 'registry', 'off' (card says []) or 'none'."""
    present, value = front_matter_watch(card_text)
    if present:
        if value == []:
            return None, "off"
        if not isinstance(value, list) or not all(isinstance(v, dict) for v in value):
            raise ValueError("watch: в карточке должен быть списком объектов; отключить наблюдение можно только значением []")
        return value, "card"
    specs = registry_watch(registry, wp)
    return (specs, "registry") if specs else (None, "none")


def render(args: argparse.Namespace) -> int:
    text = args.card.read_text(encoding="utf-8")
    print("## Внешнее состояние по наблюдению (РП-561 Ф74)")
    try:
        specs, origin = resolve_specs(text, args.registry, args.wp)
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"- ⚠️ UNKNOWN: наблюдение не разобрано — {exc}")
        print()
        return 0
    if specs is None:
        reason = "отключено в карточке (watch: [])" if origin == "off" else "нет записи в реестре наблюдения и блока watch: в карточке"
        print(f"- UNTRACKED: внешнее состояние не отслеживается — {reason}")
        print()
        return 0

    revised = parse_time(args.revised_at)
    since = revised or datetime.now(timezone.utc) - timedelta(days=args.days)
    basis = (
        f"ревизия карточки {short(revised)} UTC (последняя правка файла, не поля «Следующий шаг»)"
        if revised
        else f"ревизия карточки неизвестна — смотрю события за {args.days} дн."
    )
    print(f"- Источник списка: {'карточка (watch:)' if origin == 'card' else 'реестр наблюдения'}; {basis}")

    gh = Gh(TOTAL_BUDGET_S, args.cache_dir)
    summaries: list[str] = []
    for spec in specs:
        slug = spec.get("slug") or (local_slug(args.workspace, str(spec["repo"])) if spec.get("repo") else None)
        label = str(spec.get("repo") or spec.get("slug") or "?")
        if not slug:
            print(f"- ⚠️ UNKNOWN: {label} — нет адреса origin на GitHub")
            continue
        try:
            events, notes, count = watch_repo(gh, slug, spec, text, since)
        except GitHubTimeout:
            print(f"- ⚠️ UNKNOWN: {label} — GitHub не ответил в пределах {TOTAL_BUDGET_S:.0f} с на весь запуск")
            continue
        except GitHubError as exc:
            print(f"- ⚠️ UNKNOWN: {label} — {exc} (это не расхождение, состояние не известно)")
            continue
        aged = [age for key, age in gh.cache_age_min.items() if key.startswith(slug)]
        if aged:
            print(f"- ⚠️ UNKNOWN: {label} — GitHub недоступен, ниже справочно данные из кэша {max(aged)} мин назад (сигнал «проверить» не поднимается)")
        if not events:
            print(f"- {label}: событий после ревизии карточки, не названных в ней, нет")
        else:
            print(f"- 🔎 проверить — {label}: {count} событий после ревизии карточки, не названных в ней")
            for line in events[:MAX_EVENT_LINES]:
                print(f"  - {line}")
            if count > MAX_EVENT_LINES:
                print(f"  - …и ещё {count - MAX_EVENT_LINES}")
            if not aged:
                summaries.append(f"{label}: {count} событий после ревизии карточки ({short(revised)} UTC) не названы в карточке")
        for note in notes:
            print(f"  - примечание: {note}")
    print()

    if args.drift_file and summaries:
        with args.drift_file.open("a", encoding="utf-8") as out:
            out.writelines(f"REVIEW: external_state — {item}; «Следующий шаг» мог устареть\n" for item in summaries)
    return 0


def env_days() -> int:
    raw = os.environ.get("WP_SYNC_GIT_DAYS", "")
    return int(raw) if raw.isdigit() else DEFAULT_DAYS


def default_cache_dir() -> Path | None:
    raw = os.environ.get("WP_WATCH_CACHE_DIR")
    if raw:
        return Path(raw)
    home = os.environ.get("HOME")
    return Path(home) / ".cache" / "iwe-wp-watch" if home else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("card", type=Path)
    parser.add_argument("--wp", required=True, help="WP number, digits only")
    parser.add_argument("--registry", type=Path)
    parser.add_argument("--revised-at", help="ISO time of the card revision (git commit time of the card file)")
    parser.add_argument("--workspace", type=Path, default=Path(os.environ.get("IWE_WORKSPACE", Path.home() / "IWE")))
    parser.add_argument("--drift-file", type=Path)
    parser.add_argument("--days", type=int, default=env_days())
    parser.add_argument("--cache-dir", type=Path, default=default_cache_dir())
    args = parser.parse_args()
    try:
        return render(args)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"[ERROR] wp-external-watch-check: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
