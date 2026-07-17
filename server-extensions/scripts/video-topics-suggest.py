#!/usr/bin/env python3
"""
video-topics-suggest.py — WP-433 Ф2: генерирует 5 тем для видео из недельного черновика.

Читает:  DS-Knowledge-Index-Tseren/docs/YYYY/MM-month/week-draft-wNN.md
         DS-Knowledge-Index-Tseren/style/video.md (12 правил стиля)
         DS-my-strategy git log last 7 days (закрытые РП — источники тем)
Пишет:   DS-Knowledge-Index-Tseren/video/ideas/YYYY-MM-DD-<slug>.md (1 файл / тема)
Stdout:  Markdown-таблица для вставки в Контент-план WeekPlan

Вызов:
  python3 video-topics-suggest.py [--week NN] [--proxy-url URL] [--dry-run]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

IWE = Path(os.environ.get("IWE", Path.home() / "IWE"))
KNOWLEDGE = IWE / "DS-Knowledge-Index-Tseren"
DS_STRATEGY = IWE / "DS-my-strategy"

DEFAULT_PROXY_URL = os.environ.get("LLM_PROXY_URL", "http://localhost:18765")
PROXY_TIMEOUT_S = 60

MONTH_NAMES_RU = [
    "январь", "февраль", "март", "апрель", "май", "июнь",
    "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь",
]


def find_week_draft(week: int, year: int) -> Path | None:
    month_num = datetime.date.today().month
    month_reverse = 13 - month_num
    month_name = MONTH_NAMES_RU[month_num - 1]
    draft_dir = KNOWLEDGE / "docs" / str(year) / f"{month_reverse:02d}-{month_name}"
    draft_file = draft_dir / f"week-draft-w{week:02d}.md"
    return draft_file if draft_file.exists() else None


def read_draft_semantics(draft_path: Path) -> str:
    """Extract semantic sections (Мир/Сообщество/Человек/Личное/Инсайты).
    Stops at ## Опубликованные and ## Метрики to skip boilerplate."""
    text = draft_path.read_text(encoding="utf-8")
    lines, capturing, result = text.splitlines(), False, []
    stop_headers = {"опубликованные", "метрики", "итого", "что войдёт"}
    target_headers = {"мир", "сообщество", "человек", "личное", "инсайты"}

    for line in lines:
        if line.startswith("## "):
            section_name = line.lstrip("#").strip().lower()
            if any(s in section_name for s in stop_headers):
                break
            capturing = any(s in section_name for s in target_headers)
        if capturing:
            result.append(line)

    return "\n".join(result[:120])  # cap at ~120 lines


def read_style_rules(style_path: Path) -> str:
    """Extract the 12 rules list from style/video.md."""
    text = style_path.read_text(encoding="utf-8")
    in_rules, lines = False, []
    for line in text.splitlines():
        if "## 12 правил" in line:
            in_rules = True
            continue
        if in_rules and line.startswith("## "):
            break
        if in_rules and re.match(r"^\d+\.", line):
            lines.append(line.split(".", 1)[1].strip())
    return "\n".join(f"{i+1}. {r}" for i, r in enumerate(lines))


def closed_wps_this_week() -> str:
    """One-line git log of commits matching 'закрыт|done|CLOSED' in DS-my-strategy."""
    try:
        result = subprocess.run(
            ["git", "log", "--since=7 days ago", "--oneline"],
            cwd=DS_STRATEGY,
            capture_output=True, text=True, timeout=10,
        )
        lines = [
            l for l in result.stdout.splitlines()
            if re.search(r"закрыт|CLOSED|done|✅", l, re.IGNORECASE)
        ]
        return "\n".join(lines[:15]) or "нет данных"
    except Exception:
        return "нет данных"


def existing_titles() -> list[str]:
    ideas_dir = KNOWLEDGE / "video" / "ideas"
    titles = []
    if ideas_dir.exists():
        for f in sorted(ideas_dir.glob("*.md"))[-20:]:  # last 20
            m = re.search(r'^title:\s*"?(.+?)"?\s*$', f.read_text(), re.MULTILINE)
            if m:
                titles.append(m.group(1))
    return titles


def call_proxy(prompt: str, proxy_url: str) -> str:
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 2048,
    }
    req = urllib.request.Request(
        f"{proxy_url.rstrip('/')}/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=PROXY_TIMEOUT_S) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        for block in data.get("content", []):
            if block.get("type") == "text":
                return block["text"]
        return data.get("text", "")


def call_claude_subprocess(prompt: str) -> str:
    result = subprocess.run(
        ["claude", "-p", prompt, "--model", "claude-sonnet-4-6"],
        capture_output=True, text=True, timeout=120,
    )
    return result.stdout.strip()


def call_llm(prompt: str, proxy_url: str) -> str:
    try:
        text = call_proxy(prompt, proxy_url)
        if text:
            return text
    except (urllib.error.URLError, Exception):
        pass
    # Fallback: claude CLI subprocess
    return call_claude_subprocess(prompt)


def build_prompt(draft: str, style_rules: str, closed_wps: str, skip_titles: list[str], week: int) -> str:
    skip_block = "\n".join(f"- {t}" for t in skip_titles) or "нет"
    return f"""Предложи ровно 5 тем для коротких видео (45-75 сек) на следующую неделю.

Автор: просветитель. Тематика: системное мышление, ИИ, саморазвитие.
Аудитория: думающие взрослые, обучающиеся.

Каждая тема — реальный инсайт или достижение из недели, а не абстракция.
Крючок должен быть контринтуитивным или переворачивать привычное.

12 ПРАВИЛ СТИЛЯ:
{style_rules}

ЧТО БЫЛО СДЕЛАНО ЗА НЕДЕЛЮ (черновик W{week}):
{draft or "Черновик недели не найден."}

ЗАКРЫТЫЕ РП НЕДЕЛИ (источники тем):
{closed_wps}

УЖЕ ЕСТЬ В БАНКЕ (не дублировать):
{skip_block}

Выведи ровно 5 тем в формате JSON-массива и ничего больше:

[
  {{
    "title": "Крючок 4-8 слов",
    "thesis": "Один тезис — что поймёт зритель за 30 сек",
    "source": "из какого РП или инсайта черновика",
    "channel": "TikTok+Reels+Shorts",
    "slug": "latin-slug-no-spaces"
  }}
]

Только JSON, без пояснений.
"""


def slugify(s: str) -> str:
    s = re.sub(r"[^a-z0-9\s-]", "", s.lower())
    return re.sub(r"\s+", "-", s.strip())[:40]


def save_idea(ideas_dir: Path, today: str, topic: dict, dry_run: bool) -> str:
    slug = topic.get("slug") or slugify(topic.get("title", "tema"))
    filename = f"{today}-{slug}.md"
    filepath = ideas_dir / filename

    card = (
        f"---\n"
        f"type: video-theme\n"
        f'title: "{topic["title"]}"\n'
        f"status: draft\n"
        f"created: {today}\n"
        f"channel: [{topic.get('channel', 'TikTok+Reels+Shorts')}]\n"
        f'source_knowledge: "{topic.get("source", "")}"\n'
        f"wp: WP-433\n"
        f"---\n\n"
        f"# {topic['title']}\n\n"
        f"**Тезис:** {topic['thesis']}\n\n"
        f"## Сценарий (под суфлёр)\n\n"
        f"<!-- PENDING: написать сценарий по шаблону style/video.md -->\n\n"
        f"**Источник:** {topic.get('source', '')}\n"
    )

    if filepath.exists():
        print(f"  пропущена (уже есть): {filename}", file=sys.stderr)
    elif dry_run:
        print(f"  [dry-run] создала бы: {filename}", file=sys.stderr)
    else:
        filepath.write_text(card, encoding="utf-8")
        print(f"  создана: {filename}", file=sys.stderr)

    return filename


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--week", type=int, default=datetime.date.today().isocalendar()[1])
    parser.add_argument("--proxy-url", default=DEFAULT_PROXY_URL)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    today = datetime.date.today()
    year = today.year
    next_week = args.week + 1

    print(f"=== Темы для видео W{next_week} ===", file=sys.stderr)

    # --- Gather context ---
    draft_path = find_week_draft(args.week, year)
    if draft_path:
        draft = read_draft_semantics(draft_path)
        print(f"  черновик: {draft_path.name}", file=sys.stderr)
    else:
        draft = ""
        print(f"  WARN: week-draft W{args.week} не найден", file=sys.stderr)

    style_path = KNOWLEDGE / "style" / "video.md"
    style_rules = read_style_rules(style_path) if style_path.exists() else ""

    closed = closed_wps_this_week()
    skip_titles = existing_titles()

    # --- Call LLM ---
    prompt = build_prompt(draft, style_rules, closed, skip_titles, args.week)
    raw = call_llm(prompt, args.proxy_url)

    if not raw:
        print("ERR: LLM не ответил", file=sys.stderr)
        sys.exit(1)

    # --- Parse JSON ---
    json_match = re.search(r"\[.*\]", raw, re.DOTALL)
    if not json_match:
        print(f"ERR: не найден JSON в ответе LLM:\n{raw[:300]}", file=sys.stderr)
        sys.exit(1)

    try:
        topics = json.loads(json_match.group(0))
    except json.JSONDecodeError as e:
        print(f"ERR: JSON parse error: {e}\n{json_match.group(0)[:300]}", file=sys.stderr)
        sys.exit(1)

    if not topics:
        print("ERR: LLM вернул пустой список", file=sys.stderr)
        sys.exit(1)

    # --- Save idea files ---
    ideas_dir = KNOWLEDGE / "video" / "ideas"
    ideas_dir.mkdir(parents=True, exist_ok=True)
    today_str = today.isoformat()

    saved = []
    for topic in topics[:5]:
        fname = save_idea(ideas_dir, today_str, topic, args.dry_run)
        saved.append((topic, fname))

    # --- Print Контент-план table for WeekPlan ---
    print(f"\n### Темы для видео W{next_week} (из сделанного за W{args.week})\n")
    print("| # | Тема | Источник | Канал | Когда |")
    print("|---|------|---------|-------|-------|")
    for i, (topic, _) in enumerate(saved, 1):
        ch = topic.get("channel", "TikTok+Reels+Shorts")
        print(f"| V{i} | **{topic['title']}** | {topic.get('source', '')} | {ch} | W{next_week} |")

    if not args.dry_run:
        print(
            f"\n> Карточки сохранены: {KNOWLEDGE}/video/ideas/\n"
            f"> Вставь таблицу выше в WeekPlan W{next_week} §Контент-план\n",
        )


if __name__ == "__main__":
    main()
