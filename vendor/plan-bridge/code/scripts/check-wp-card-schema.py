#!/usr/bin/env python3
"""Проверка схемы карточки РП (WP-526 Ф12 п.1а, исполнение — Ф13 шаг 2).

Что проверяет — только основной файл РП `inbox/WP-N/WP-N.md`:
  - frontmatter есть (первая строка `---`, закрывающая `---`) и разбирается YAML;
  - обязательные поля `wp`, `title`, `status`, `created` (docs/INBOX-CONVENTION.md,
    «Формат папки»; поля `budget` в соглашении нет — и здесь его нет);
  - `status` входит в закрытый перечень из docs/INBOX-CONVENTION.md (блок
    `wp-status-list`) — перечень читается оттуда, в коде не дублируется;
  - плоский файл `inbox/WP-N*.md` рядом с папками — нарушение «всегда папка».
Не проверяет: дополнительные файлы папки (`WP-N-archive.md`, `<тема>.md`),
`archive/wp-contexts/`, всё вне `inbox/`.

Режимы (выключатель IWE_CARD_SCHEMA_CHECK или --mode):
  report (по умолчанию) — печатает отчёт, код возврата всегда 0;
  off               — ничего не проверяет, код возврата 0.
Блокирующего режима нет (вне Ф13): любое другое значение выключателя
трактуется как report с предупреждением. Ошибка конфигурации (нет соглашения,
нет блока перечня) в режиме report — тоже строка отчёта, не отказ.

Источники карточек:
  --all            все `inbox/WP-*/WP-*.md` рабочего дерева (замер Э2);
  --staged         изменённые в индексе (pre-commit), содержимое — staged blob;
  --range A..B     изменённые в диапазоне коммитов (слот кандидата
                   isolate-push.sh: cherry-pick pre-commit не запускает),
                   содержимое — из B.
Перечень статусов в --staged/--range берётся из той же ревизии, что и
карточки (индекс / B), чтобы правка соглашения и карточки в одном коммите
проверялась согласованно.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

import yaml

CONVENTION = "docs/INBOX-CONVENTION.md"
REQUIRED = ("wp", "title", "status", "created")
BEGIN = "<!-- wp-status-list:begin -->"
END = "<!-- wp-status-list:end -->"
CARD_RE = re.compile(r"^inbox/(WP-\d+)/(WP-\d+)\.md$")
FLAT_RE = re.compile(r"^inbox/WP-\d+[^/]*\.md$")
MODES = ("report", "off")


class ConfigError(Exception):
    pass


def parse_status_list(text: str) -> dict[str, list[str]]:
    """Блок между маркерами: ```yaml ... ``` с группами -> списками статусов."""
    if BEGIN not in text or END not in text:
        raise ConfigError(f"в {CONVENTION} нет блока {BEGIN} … {END}")
    block = text.split(BEGIN, 1)[1].split(END, 1)[0]
    m = re.search(r"```ya?ml\n(.*?)```", block, re.S)
    if not m:
        raise ConfigError(f"в блоке wp-status-list ({CONVENTION}) нет ```yaml```")
    try:
        data = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as e:
        raise ConfigError(f"блок wp-status-list не разбирается: {e}") from e
    groups = data.get("groups") if isinstance(data, dict) else None
    if not isinstance(groups, dict) or not groups:
        raise ConfigError("в блоке wp-status-list нет непустого словаря groups")
    out: dict[str, list[str]] = {}
    for name, values in groups.items():
        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            raise ConfigError(f"группа {name!r}: ожидается список строк")
        out[str(name)] = values
    return out


def allowed_statuses(groups: dict[str, list[str]]) -> set[str]:
    return {v for values in groups.values() for v in values}


def check_card_text(rel: str, text: str, allowed: set[str]) -> list[str]:
    """Список нарушений одной карточки (пустой — прошла)."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return ["нет frontmatter (первая строка не `---`)"]
    try:
        end = next(i for i, ln in enumerate(lines[1:], 1) if ln.strip() == "---")
    except StopIteration:
        return ["frontmatter не закрыт (`---`)"]
    try:
        fm = yaml.safe_load("\n".join(lines[1:end]))
    except yaml.YAMLError as e:
        first = str(e).splitlines()[0] if str(e) else "ошибка"
        return [f"frontmatter не разбирается YAML: {first}"]
    if not isinstance(fm, dict):
        return ["frontmatter не словарь"]
    problems = [f"нет поля `{k}`" for k in REQUIRED if fm.get(k) in (None, "")]
    status = fm.get("status")
    if status not in (None, "") and str(status) not in allowed:
        problems.append(f"статус `{status}` не из перечня {CONVENTION}")
    return problems


def classify(rel: str) -> str | None:
    """'card' | 'flat' | None (не проверяется)."""
    m = CARD_RE.match(rel)
    if m:
        return "card" if m.group(1) == m.group(2) else None
    if FLAT_RE.match(rel):
        return "flat"
    return None


def git(repo: str, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", repo, *args], check=True, capture_output=True, text=True
    ).stdout


def collect(repo: str, source: str, rng: str | None):
    """-> (convention_text | None, [(rel, text|None)])"""
    if source == "all":
        conv_path = os.path.join(repo, CONVENTION)
        conv = open(conv_path, encoding="utf-8").read() if os.path.isfile(conv_path) else None
        items = []
        inbox = os.path.join(repo, "inbox")
        for name in sorted(os.listdir(inbox)) if os.path.isdir(inbox) else []:
            full = os.path.join(inbox, name)
            if os.path.isdir(full) and re.fullmatch(r"WP-\d+", name):
                card = os.path.join(full, f"{name}.md")
                rel = f"inbox/{name}/{name}.md"
                items.append((rel, open(card, encoding="utf-8").read() if os.path.isfile(card) else None))
            elif os.path.isfile(full) and FLAT_RE.match(f"inbox/{name}"):
                items.append((f"inbox/{name}", ""))
        return conv, items
    if source == "staged":
        names = git(repo, "diff", "--cached", "--name-only", "--diff-filter=ACMR").splitlines()
        show = lambda p: git(repo, "show", f":{p}")  # noqa: E731
    else:
        names = git(repo, "diff", "--name-only", "--diff-filter=ACMR", rng).splitlines()
        tip = rng.split("..", 1)[1] or "HEAD"
        show = lambda p: git(repo, "show", f"{tip}:{p}")  # noqa: E731
    try:
        conv = show(CONVENTION)
    except subprocess.CalledProcessError:
        conv = None
    items = [(n, show(n)) for n in names if classify(n)]
    return conv, items


def run(repo: str, source: str, rng: str | None, out=None) -> dict:
    """Печатает отчёт; возвращает сводку (для тестов и замера)."""
    out = out or sys.stdout
    conv, items = collect(repo, source, rng)
    summary = {"checked": 0, "passed": 0, "flat": 0, "violations": {}, "config_error": None}
    try:
        if conv is None:
            raise ConfigError(f"нет {CONVENTION}")
        allowed = allowed_statuses(parse_status_list(conv))
    except ConfigError as e:
        summary["config_error"] = str(e)
        print(f"card-schema [report]: ошибка конфигурации — {e}; проверка статусов пропущена", file=out)
        allowed = None
    for rel, text in items:
        kind = classify(rel)
        if kind == "flat":
            summary["flat"] += 1
            summary["violations"][rel] = ["плоский файл вне папки (INBOX-CONVENTION: всегда папка)"]
            continue
        summary["checked"] += 1
        if text is None:
            problems = ["папка без основного файла"]
        elif allowed is None:
            problems = [p for p in check_card_text(rel, text, set()) if not p.startswith("статус")]
        else:
            problems = check_card_text(rel, text, allowed)
        if problems:
            summary["violations"][rel] = problems
        else:
            summary["passed"] += 1
    for rel, problems in summary["violations"].items():
        print(f"card-schema [report]: {rel}: {'; '.join(problems)}", file=out)
    n, ok = summary["checked"], summary["passed"]
    share = f"{ok / n * 100:.1f}%" if n else "—"
    print(
        f"card-schema [report]: Э2 = {ok}/{n} карточек прошли ({share}); "
        f"плоских файлов: {summary['flat']}; режим только отчёт — не блокирует",
        file=out,
    )
    return summary


def resolve_mode(cli: str | None) -> str:
    mode = cli or os.environ.get("IWE_CARD_SCHEMA_CHECK", "") or "report"
    if mode not in MODES:
        print(
            f"card-schema: WARN режим {mode!r} не поддерживается (есть {', '.join(MODES)}); "
            "работаю как report",
            file=sys.stderr,
        )
        mode = "report"
    return mode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".")
    ap.add_argument("--mode", choices=None, default=None)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--all", action="store_true")
    src.add_argument("--staged", action="store_true")
    src.add_argument("--range")
    ap.add_argument("--quiet-ok", action="store_true", help="молчать, если нечего проверять")
    args = ap.parse_args(argv)
    if resolve_mode(args.mode) == "off":
        return 0
    source = "all" if args.all else "staged" if args.staged else "range"
    try:
        if args.quiet_ok and source != "all":
            _, items = collect(args.repo, source, args.range)
            if not items:
                return 0
        run(args.repo, source, args.range)
    except Exception as e:  # report-only: сбой проверки не должен отказывать коммиту
        print(f"card-schema [report]: WARN проверка не отработала: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
