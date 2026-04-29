#!/usr/bin/env python3
"""
rule-classifier.py — async post-hoc анализ журнала rule-engine.sh через Haiku R23.

Архитектура (WP-272 Ф2):
- Regex-hook (rule-engine.sh) даёт мгновенный verdict в runtime — для interactive UX.
- Этот script читает журнал ~/logs/rule-engine/YYYY-MM-DD.jsonl, для warn/block записей
  отправляет в Haiku запрос «нарушение или false positive?», обогащает журнал.
- Метрика FP rate агрегируется из обогащённого журнала (см. fp-stats.py).

Использование:
  rule-classifier.py [--date YYYY-MM-DD] [--rule AR.NNN] [--limit N]

Запуск: можно вручную или из cron (раз в час / при Day Close).
"""

import json
import sys
import subprocess
import argparse
import yaml
from datetime import date
from pathlib import Path

JOURNAL_DIR = Path.home() / "logs" / "rule-engine"
PACK_RULES = Path.home() / "IWE" / "PACK-agent-rules" / "rules"
# WP-272 Ф2 fix (R23 audit): shutil.which для переносимости (Linux / Intel Mac)
import shutil
CLAUDE_BIN = shutil.which("claude") or "/home/tseren/.npm-global/bin/claude"
MODEL = "claude-haiku-4-5-20251001"
TIMEOUT_S = 60


def load_rule(rule_id):
    """Найти AR.NNN-*.md и вернуть (frontmatter_dict, body_text)."""
    matches = list(PACK_RULES.glob(f"{rule_id}-*.md"))
    if not matches:
        return None
    content = matches[0].read_text(encoding="utf-8")
    parts = content.split("---", 2)
    if len(parts) < 3:
        return None
    try:
        fm = yaml.safe_load(parts[1])
        body = parts[2].strip()
        return fm, body
    except yaml.YAMLError:
        return None


def build_classifier_prompt(rule_fm, rule_body, regex_verdict, response_text, context):
    """Сформировать system + user prompt для Haiku."""
    system = f"""Ты — Верификатор правил агента (R23) с context isolation.

Твоя задача — независимо классифицировать конкретный фрагмент ответа агента Claude:
- "violation" — реальное нарушение правила
- "ok" — НЕ нарушение, ложное срабатывание regex (применимо exception)
- "uncertain" — неуверенно

# Правило для проверки

ID: {rule_fm['id']}
Name: {rule_fm['name']}
Type: {rule_fm['type']}
Priority: {rule_fm['priority']}

## Tests positive (должно сработать)
{json.dumps(rule_fm['tests']['positive'], ensure_ascii=False, indent=2)}

## Tests negative (НЕ должно срабатывать — exceptions)
{json.dumps(rule_fm['tests']['negative'], ensure_ascii=False, indent=2)}

## Exceptions
{json.dumps(rule_fm.get('exceptions', []), ensure_ascii=False, indent=2)}

## Текст правила (body)

{rule_body}

# Формат ответа

Только JSON одной строкой, без markdown:
{{"verdict": "violation|ok|uncertain", "reason": "1-2 предложения", "confidence": 0.0-1.0}}
"""

    user = f"""# Контекст

Regex-классификатор пометил это как: **{regex_verdict}**

# Текст ответа агента (фрагмент)

{response_text[:3000]}

# Метаданные

{json.dumps(context, ensure_ascii=False, indent=2)[:500]}

Классифицируй. Только JSON, без объяснений вокруг."""

    return system, user


def call_haiku(system, user):
    """Вызвать claude CLI в bare режиме, вернуть распарсенный JSON или error-dict."""
    # --bare требует ANTHROPIC_API_KEY (у пользователя его нет → используем OAuth-сессию).
    # Полная сессия даёт ~10s overhead но работает без API key.
    try:
        result = subprocess.run(
            [CLAUDE_BIN, "-p", "--model", MODEL,
             "--append-system-prompt", system, user],
            capture_output=True, text=True, timeout=TIMEOUT_S,
        )
        if result.returncode != 0:
            return {"verdict": "uncertain",
                    "reason": f"claude CLI error rc={result.returncode}: {result.stderr[:200]}",
                    "confidence": 0.0}
        out = result.stdout.strip()
        # Удалить возможные markdown-блоки
        if out.startswith("```"):
            out = out.split("\n", 1)[1] if "\n" in out else out
            if "```" in out:
                out = out.rsplit("```", 1)[0]
            out = out.strip()
        # Удалить префиксы вроде "json\n"
        if out.startswith("json\n"):
            out = out[5:].strip()
        return json.loads(out)
    except subprocess.TimeoutExpired:
        return {"verdict": "uncertain", "reason": "timeout", "confidence": 0.0}
    except json.JSONDecodeError as e:
        return {"verdict": "uncertain", "reason": f"JSON parse: {e} | raw: {out[:200]}", "confidence": 0.0}


def normalize_context(ctx):
    """RULE_CONTEXT может прийти как dict или как невалидный JSON-string. Привести к dict."""
    if isinstance(ctx, dict):
        return ctx
    if isinstance(ctx, str):
        try:
            return json.loads(ctx)
        except json.JSONDecodeError:
            return {"raw": ctx}
    return {}


def process_journal(target_date, rule_filter=None, limit=None):
    journal = JOURNAL_DIR / f"{target_date}.jsonl"
    if not journal.exists():
        print(f"No journal for {target_date} at {journal} — nothing to classify", file=sys.stderr)
        return 0

    out_path = JOURNAL_DIR / f"{target_date}-classified.jsonl"

    classified = 0
    skipped = 0
    errors = 0

    with journal.open(encoding="utf-8") as f, out_path.open("w", encoding="utf-8") as fout:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                errors += 1
                continue

            verdict = entry.get("verdict")
            rule = entry.get("rule")

            # Классифицируем только warn/block (ok — нечего проверять)
            if verdict not in ("warn", "block"):
                skipped += 1
                continue

            if rule_filter and rule != rule_filter:
                continue
            if rule == "none":
                continue

            if limit and classified >= limit:
                break

            rule_data = load_rule(rule)
            if not rule_data:
                entry["llm_verdict"] = "uncertain"
                entry["llm_reason"] = f"rule {rule} not found in PACK-agent-rules"
                fout.write(json.dumps(entry, ensure_ascii=False) + "\n")
                errors += 1
                continue

            fm, body = rule_data
            ctx = normalize_context(entry.get("context", {}))
            response = ctx.get("response_text") or ctx.get("file_path", "") or json.dumps(ctx)

            print(f"  [{rule}] regex={verdict} → asking Haiku...", file=sys.stderr)
            system, user = build_classifier_prompt(fm, body, verdict, response, ctx)
            llm = call_haiku(system, user)

            entry["llm_verdict"] = llm.get("verdict")
            entry["llm_reason"] = llm.get("reason")
            entry["llm_confidence"] = llm.get("confidence")
            # Agreement: если regex сказал warn/block И llm violation → agree
            #            если regex warn/block И llm ok → false positive
            entry["false_positive"] = (llm.get("verdict") == "ok")
            entry["agreement"] = (llm.get("verdict") == "violation")

            fout.write(json.dumps(entry, ensure_ascii=False) + "\n")
            classified += 1

    print(f"OK: classified={classified}, skipped={skipped}, errors={errors}")
    print(f"     output → {out_path}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", default=str(date.today()), help="YYYY-MM-DD (default: today)")
    parser.add_argument("--rule", help="filter by rule id, e.g. AR.002")
    parser.add_argument("--limit", type=int, help="max entries to classify")
    args = parser.parse_args()
    sys.exit(process_journal(args.date, args.rule, args.limit))


if __name__ == "__main__":
    main()
