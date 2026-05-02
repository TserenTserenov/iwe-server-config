#!/usr/bin/env bash
# server-calendar.sh — кросс-платформенная замена mcp__ext-google-calendar для server-mode
# see WP-283 (DS-my-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Выводит готовую markdown-секцию «Календарь» для DayPlan.
#
# Требует:
#   env: GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET
#   или файл ~/.secrets/google-calendar (строки KEY=VALUE)
#   config: day-rhythm-config.yaml → calendar_ids
#
# Использование:
#   bash server-calendar.sh YYYY-MM-DD [CONFIG_PATH]
#   bash server-calendar.sh 2026-05-03

set -uo pipefail

DATE="${1:-$(date +%Y-%m-%d)}"
IWE="${IWE_ROOT:-$HOME/IWE}"
CONFIG="${2:-$IWE/DS-my-strategy/exocortex/day-rhythm-config.yaml}"
SECRETS_FILE="${HOME}/.secrets/google-calendar"

# --- Загружаем credentials ---
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$SECRETS_FILE"; set +a
fi

REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN:-}"
CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

if [[ -z "$REFRESH_TOKEN" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  # Отсутствуют credentials — явный PENDING, не заглушка
  echo "📅 **Календарь ($DATE):** ⚠️ PENDING — Google credentials не настроены. Установить: \`~/.secrets/google-calendar\` (GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET)"
  echo ""
  echo "⏱ Свободных блоков ≥1h: **не определено**"
  exit 0
fi

# --- Получаем access token через refresh ---
TOKEN_RESPONSE=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "refresh_token=${REFRESH_TOKEN}" \
  -d "grant_type=refresh_token" \
  2>/dev/null)

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
  ERROR=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" 2>/dev/null || echo "unknown")
  echo "📅 **Календарь ($DATE):** ⚠️ PENDING — OAuth error: $ERROR"
  echo ""
  echo "⏱ Свободных блоков ≥1h: **не определено**"
  exit 0
fi

# --- Читаем calendar_ids из конфига ---
CALENDAR_IDS=$(python3 -c "
import yaml, sys
try:
    with open('$CONFIG') as f: d = yaml.safe_load(f)
    ids = d.get('calendar_ids', [])
    for cid in ids:
        print(cid)
except Exception as e:
    pass
" 2>/dev/null)

if [[ -z "$CALENDAR_IDS" ]]; then
  echo "📅 **Календарь ($DATE):** ⚠️ PENDING — calendar_ids не найдены в конфиге"
  echo ""
  echo "⏱ Свободных блоков ≥1h: **не определено**"
  exit 0
fi

# --- Временной диапазон: весь день (09:00–22:00 local = UTC+3) ---
# Формат RFC3339 для API
TIME_MIN="${DATE}T00:00:00Z"
TIME_MAX="${DATE}T23:59:59Z"

# --- Собираем события со всех календарей ---
ALL_EVENTS=$(python3 - <<PYEOF
import json, sys

events_all = []
PYEOF
)

# Запрашиваем каждый календарь
EVENTS_JSON=$(python3 << PYEOF
import json, subprocess, urllib.parse, sys

calendar_ids = """${CALENDAR_IDS}""".strip().split('\n')
time_min = "${TIME_MIN}"
time_max = "${TIME_MAX}"
access_token = "${ACCESS_TOKEN}"

all_events = []
errors = []

for cid in calendar_ids:
    if not cid.strip():
        continue
    encoded = urllib.parse.quote(cid.strip(), safe='')
    url = f"https://www.googleapis.com/calendar/v3/calendars/{encoded}/events"
    params = f"timeMin={urllib.parse.quote(time_min)}&timeMax={urllib.parse.quote(time_max)}&singleEvents=true&orderBy=startTime&maxResults=50"

    result = subprocess.run(
        ["curl", "-s", "-H", f"Authorization: Bearer {access_token}",
         f"{url}?{params}"],
        capture_output=True, text=True, timeout=10
    )

    if result.returncode != 0:
        errors.append(f"curl error for {cid}")
        continue

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        errors.append(f"json error for {cid}")
        continue

    if "error" in data:
        # Пропускаем недоступные календари (403, 404)
        continue

    for item in data.get("items", []):
        summary = item.get("summary", "(без названия)")
        start = item.get("start", {})
        end = item.get("end", {})

        # Пропускаем private
        visibility = item.get("visibility", "")
        if visibility == "private":
            continue

        # Время начала
        if "dateTime" in start:
            start_dt = start["dateTime"][:16]  # YYYY-MM-DDTHH:MM
            start_time = start_dt[11:]  # HH:MM
        else:
            start_time = "весь день"

        # Длительность
        if "dateTime" in start and "dateTime" in end:
            from datetime import datetime
            try:
                s = datetime.fromisoformat(start["dateTime"].replace("Z", "+00:00"))
                e = datetime.fromisoformat(end["dateTime"].replace("Z", "+00:00"))
                duration_min = int((e - s).total_seconds() / 60)
                if duration_min < 60:
                    duration = f"{duration_min}м"
                else:
                    h = duration_min // 60
                    m = duration_min % 60
                    duration = f"{h}ч{m:02d}м" if m else f"{h}ч"
            except Exception:
                duration = "?"
        else:
            duration = "весь день"

        all_events.append({
            "start_time": start_time,
            "summary": summary,
            "duration": duration,
        })

# Сортируем по времени
def sort_key(e):
    t = e["start_time"]
    return t if t != "весь день" else "00:00"

all_events.sort(key=sort_key)

print(json.dumps({"events": all_events, "errors": errors}))
PYEOF
)

# --- Формируем markdown секцию ---
python3 << PYEOF
import json, sys

try:
    data = json.loads("""${EVENTS_JSON}""")
except Exception:
    data = {"events": [], "errors": ["parse error"]}

events = data.get("events", [])
errors = data.get("errors", [])
date_str = "${DATE}"

# Читаем DAY_NUM и MONTH_RU из окружения или вычисляем
try:
    from datetime import datetime
    dt = datetime.strptime(date_str, "%Y-%m-%d")
    months = ["","января","февраля","марта","апреля","мая","июня","июля","августа","сентября","октября","ноября","декабря"]
    day_label = f"{dt.day} {months[dt.month]}"
except Exception:
    day_label = date_str

n = len(events)
count_label = f"{n} {'событие' if n==1 else 'события' if 2<=n<=4 else 'событий'}"

print(f"📅 **Календарь ({day_label} {dt.year}):** ✅ Проверено через server-calendar.sh ({count_label}).")
print()

if events:
    print("| Время | Событие | Длит. | Связь с РП |")
    print("|-------|---------|-------|------------|")
    for e in events:
        summary = e["summary"].replace("|", "\\|")
        print(f"| {e['start_time']} | {summary} | {e['duration']} | — |")
    print()

# Свободные блоки 09:00-19:00
if not events:
    print("⏱ Свободных блоков ≥1h: **весь день** (09:00–22:00)")
else:
    # Упрощённый расчёт: есть события → показываем диапазоны
    busy = []
    for e in events:
        t = e["start_time"]
        if t == "весь день":
            continue
        try:
            h, m = map(int, t.split(":"))
            busy.append(h * 60 + m)
        except Exception:
            pass

    if not busy:
        print("⏱ Свободных блоков ≥1h: **весь день** (09:00–22:00)")
    else:
        first = min(busy)
        last = max(busy)
        first_h = first // 60
        last_h = (last // 60) + 2  # +2ч после последнего события

        free_blocks = []
        if first_h > 9:
            free_blocks.append(f"09:00–{first_h:02d}:00")
        if last_h < 22:
            free_blocks.append(f"{last_h:02d}:00–22:00")

        if free_blocks:
            print(f"⏱ Свободных блоков ≥1h: {', '.join(free_blocks)}")
        else:
            print("⏱ Свободных блоков ≥1h: плотный день, свободных окон ≥1h нет")

if errors:
    print()
    print(f"> ⚠️ Пропущено календарей: {len(errors)} (нет доступа или ошибка)")
PYEOF
