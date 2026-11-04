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
блоком «Участие за вчера». Если сессий с заявкой не было, показать одну строку
из сводки, без вопроса. Если есть строки «ждёт подтверждения», сводка сама
просит ответа: пилота не торопить, молчание за ответ не считать.

**Пилот ответил** («подтверждаю» или «2 — 40 мин»). Чтобы записать ответ,
взять номер сводки и коммит плана из последней строки той сводки, на которую
он ответил: `Сводка <номер> по опубликованному плану <коммит>`. «Подтверждаю»
— это `--all`; поправка строки — `--row 2=40`; можно вместе: `--all --row 2=40`.

Заявку закрывает только тот канал, который её подал. Поэтому ответ собирается
дважды — для строк «Цеха» и для строк «Мака» — и каждая часть уходит своим
каналом:

```bash
REPO="$HOME/IWE/DS-my-strategy"
answer() {  # $1 = holder; same flags as the pilot's answer
  uv run -q --no-project --with rfc8785 --with pyyaml python \
    "$REPO/scripts/plan-summary-answer.py" build --repository "$REPO" \
    --date <дата сводки> --summary-id <номер> --commit <коммит> \
    --trust-intra-commit-order --holder "$1" --all
}
answer tsekh-agent-channel | ssh -o BatchMode=yes tsekh-1 'set -e; T=$(mktemp -d);
  cd ~/IWE/DS-my-strategy; git fetch -q origin main
  for f in plan-summary-answer.py plan-session-reserve.py plan-event-send.py; do
    git show origin/main:scripts/$f > $T/$f; done
  python3 $T/plan-summary-answer.py send; rm -rf $T'
answer mac-agent-channel | ssh -i "$HOME/.ssh/iwe-plan-mac" -o IdentitiesOnly=yes \
  -o BatchMode=yes iwe-plan-mac@95.216.75.148 answer
```

Пустая часть («requests» пуст) ничего не меняет, её отправка безвредна.
Строки из `not_answerable` (без отметки о начале, уже закрыты другим ответом,
отменены) «подтверждаю» не закрывает — назвать их пилоту номерами.
Канал Мака принимает только такие ответы пилота, любой другой запрос он
отклонит как `NotPilotAnswer`. Через
минуту построить сводку той же даты заново и показать пилоту: строки должны
стать «подтверждено». Отказ `AnswerRefused` (сводка не та, строка уже закрыта
другим ответом) — показать пилоту причину, повторять не надо.
