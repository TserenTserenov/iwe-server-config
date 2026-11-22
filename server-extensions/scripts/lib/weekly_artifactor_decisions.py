"""Summarize accepted Artifactor checks for the informational weekly report."""

import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path


def report(log_path: Path, now: datetime) -> None:
    since = (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    until = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    titles: Counter[str] = Counter()
    legacy_heads: Counter[str] = Counter()
    try:
        with log_path.open(encoding="utf-8", errors="replace") as lines:
            for line in lines:
                fields = line.rstrip("\r\n").split("\t")
                if len(fields) not in (7, 8):
                    continue
                stamp, agent, _, mode, head, outcome, _ = fields[:7]
                if agent != "artifactor" or mode != "gate" or not since <= stamp <= until:
                    continue
                if outcome not in {"miss->0", "ambiguous->0", "modifier->0"}:
                    continue
                if len(fields) == 8 and fields[7].strip():
                    titles[fields[7].strip()] += 1
                elif head.strip():
                    legacy_heads[head.strip().casefold()] += 1
    except FileNotFoundError:
        print("  Журнал решений Артефактора ещё не создан.")
        return
    except OSError as err:
        print(f"  Разбор названий пропущен: не удалось прочитать журнал ({err.strerror}).")
        return

    for heading, counts in (
        ("Проверенные названия РП", titles),
        ("Старые записи: сохранилось только первое слово названия", legacy_heads),
    ):
        if counts:
            print(f"  {heading} (число успешных проверок):")
            for label, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
                print(f"    {label} — {count}")
    if not titles and not legacy_heads:
        print("  Успешных проверок с уточнением за семь дней нет.")


if __name__ == "__main__":
    report(Path(sys.argv[1]), datetime.now(timezone.utc))
