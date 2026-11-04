## Сводка участия пилота за вчера (РП-561 Ф55, контракт v3 DR-06)

Показать пилоту одну сводку: сколько его времени ушло вчера на сессии по РП.
Сводка строится по опубликованному плану, поэтому оценки, которые пилот
подтвердит, ложатся в общий учёт Мака и «Цеха». Нужен `uv` (есть на Маке).
Его нет — шаг пропустить молча.

```bash
command -v uv >/dev/null || exit 0
REPO="$HOME/IWE/DS-my-strategy"
git -C "$REPO" fetch -q origin main
YESTERDAY=$(python3 -c 'from datetime import datetime, timedelta; from zoneinfo import ZoneInfo; print((datetime.now(ZoneInfo("Asia/Nicosia")) - timedelta(days=1)).date())')
uv run -q --no-project --with rfc8785 --with pyyaml python \
  "$REPO/scripts/lib/plan_daily_summary.py" --repository "$REPO" \
  --date "$YESTERDAY" --commit origin/main --trust-intra-commit-order
```

Текст сводки показать пилоту в отчёте открытия дня как есть, отдельным
блоком «Участие за вчера». Сессий с заявкой не было — одна строка из сводки,
без вопроса. Есть строки «ждёт подтверждения» — сводка сама просит ответа;
пилота не торопить и молчание за ответ не считать.

**Пилот ответил** («подтверждаю» или «2 — 40 мин»). Записать ответ — номер
сводки и коммит плана взять из последней строки той сводки, на которую он
ответил: `Сводка <номер> по опубликованному плану <коммит>`. «Подтверждаю» —
`--all`; поправка строки — `--row 2=40`; можно вместе: `--all --row 2=40`.

```bash
REPO="$HOME/IWE/DS-my-strategy"
uv run -q --no-project --with rfc8785 --with pyyaml python \
  "$REPO/scripts/plan-summary-answer.py" build --repository "$REPO" \
  --date <дата сводки> --summary-id <номер> --commit <коммит> \
  --trust-intra-commit-order --all > /tmp/plan-answer.json
ssh -o BatchMode=yes tsekh-1 'set -e; T=$(mktemp -d); cd ~/IWE/DS-my-strategy;
  git fetch -q origin main
  for f in plan-summary-answer.py plan-session-reserve.py plan-event-send.py; do
    git show origin/main:scripts/$f > $T/$f; done
  python3 $T/plan-summary-answer.py send; rm -rf $T' < /tmp/plan-answer.json
```

Ответ уходит через «Цех»: подтвердить строку может только хост, который подал
заявку, а заявки пока подаёт только «Цех». Через минуту построить сводку той же
даты заново и показать пилоту — строки должны стать «подтверждено». Отказ
`AnswerRefused` (сводка не та, строка уже закрыта другим ответом) — показать
пилоту причину, повторять не надо.
