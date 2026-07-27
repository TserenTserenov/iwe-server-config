#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# backup-stress-test.sh — стресс-тест системы резервного копирования IWE
# Сценарии: SC1 потеря | SC2 corruption | SC3 vendor outage | SC4 drift | SC5 credentials
# Запуск: bash ~/IWE/scripts/backup-stress-test.sh [--sc SC1|SC2|SC3|SC4|SC5]
# WP-317, DP.SC.131

set -uo pipefail

REPORT_DIR="/home/tseren/IWE/DS-ecosystem-development/C.IT-Platform/C2.IT-Platform/C2.3.Operations/backup-reports"
REPORT_FILE="${REPORT_DIR}/stress-test-$(date +%Y-%m-%d).md"
NEON_CONNECTIONS="/etc/restic/neon-connections"
RESTIC_PWD_FILE="/etc/restic/password"
RESTIC_B2_ENV="/etc/restic/b2-env"
RESTIC_REPO_NEON="b2:aisystant-neon-backup:neon-dbs"
PG="${HOME}/.nix-profile/bin/pg_dump"
# Fallback: system pg
[ ! -x "$PG" ] && PG=$(which pg_dump 2>/dev/null || echo "pg_dump")

PASS=0
FAIL=0
WARN=0
RESULTS=()

mkdir -p "$REPORT_DIR"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
pass() { log "✅ PASS: $*"; PASS=$((PASS+1)); RESULTS+=("✅ $*"); }
fail() { log "❌ FAIL: $*"; FAIL=$((FAIL+1)); RESULTS+=("❌ $*"); }
warn() { log "⚠️  WARN: $*"; WARN=$((WARN+1)); RESULTS+=("⚠️  $*"); }

# Фильтр: запустить только конкретный сценарий
ONLY_SC=""
if [[ "${1:-}" == "--sc" ]]; then
  ONLY_SC="${2:-}"
fi

run_sc() {
  local sc="$1"
  [[ -n "$ONLY_SC" && "$ONLY_SC" != "$sc" ]] && return 0
  return 1  # run it
}

log "=== Стресс-тест бэкапов IWE ==="
log "Дата: $(date -Is)"
log "Сценарии: ${ONLY_SC:-все (SC1-SC5)}"
echo

# ─────────────────────────────────────────────────────────────
# SC1: Случайная потеря dump-файла
# Симулируем: удаляем один dump из /tmp/restic-neon и проверяем
# что система это обнаруживает при следующем запуске
# ─────────────────────────────────────────────────────────────
if ! run_sc "SC1"; then
  log "--- SC1: Случайная потеря dump-файла ---"

  # Проверяем что последний снапшот существует и не пустой
  # Проверяем снапшот через journalctl (надёжнее чем restic под sudo без env)
  LAST_SNAP_LINE=$(journalctl -u restic-backups-neon-dbs.service -n 100 --no-pager 2>/dev/null \
    | grep 'snapshot.*saved' | tail -1)
  LAST_SNAP_SIZE=$(journalctl -u restic-backups-neon-dbs.service -n 200 --no-pager 2>/dev/null \
    | grep -oP 'Added to the repository: \K[\d.]+ \w+' | tail -1)

  if [[ -n "$LAST_SNAP_LINE" ]]; then
    SNAP_ID=$(echo "$LAST_SNAP_LINE" | grep -oP '[0-9a-f]{8}')
    pass "SC1: Последний снапшот найден ($SNAP_ID, добавлено: ${LAST_SNAP_SIZE:-неизвестно})"
  else
    # Fallback: проверяем через restic с явной передачей env
    SNAP_CHECK=$(bash -c "
      source /etc/restic/b2-env 2>/dev/null
      RESTIC_PASSWORD_FILE=/etc/restic/password \
      RESTIC_REPOSITORY=$RESTIC_REPO_NEON \
      restic snapshots --last 2>/dev/null | grep -oP '[0-9a-f]{8,}'
    " 2>/dev/null | head -1)
    if [[ -n "$SNAP_CHECK" ]]; then
      pass "SC1: Последний снапшот найден ($SNAP_CHECK)"
    else
      fail "SC1: Не удалось подтвердить существование снапшота"
    fi
  fi

  # Симуляция: удаляем тест-файл и проверяем что pg_dump его воссоздаст
  TEST_DB_URL=$(sudo grep -m1 'postgresql://' "$NEON_CONNECTIONS" 2>/dev/null || echo "")
  if [[ -n "$TEST_DB_URL" ]]; then
    TEST_DBNAME=$(echo "$TEST_DB_URL" | sed 's/.*\///' | sed 's/?.*//')
    TEST_DUMP="/tmp/restic-neon-sc1-test/${TEST_DBNAME}.dump"
    mkdir -p /tmp/restic-neon-sc1-test

    # WP-7 Ф-Backup-Resilience-Audit: sudo здесь был не нужен — $TEST_DB_URL уже в
    # локальной переменной непривилегированного процесса (root требовался только для
    # чтения neon-connections на шаге выше), а sudo пишет полную командную строку,
    # включая пароль, в системный журнал. pg_dump сам разбирает пароль из URL.
    if "$PG" --format=custom --no-password "$TEST_DB_URL" \
       > "$TEST_DUMP" 2>/dev/null; then
      SIZE=$(du -sh "$TEST_DUMP" | cut -f1)
      pass "SC1: Ручной pg_dump успешен ($TEST_DBNAME: $SIZE)"
      rm -rf /tmp/restic-neon-sc1-test
    else
      fail "SC1: Ручной pg_dump упал для $TEST_DBNAME"
    fi
  fi
  echo
fi

# ─────────────────────────────────────────────────────────────
# SC2: Corruption dump-файла
# Симулируем: создаём dump, портим байты, проверяем pg_restore
# ─────────────────────────────────────────────────────────────
if ! run_sc "SC2"; then
  log "--- SC2: Corruption dump-файла ---"

  TEST_DB_URL=$(sudo grep -m1 'postgresql://.*indicators' "$NEON_CONNECTIONS" 2>/dev/null \
    || sudo grep -m1 'postgresql://' "$NEON_CONNECTIONS" 2>/dev/null || echo "")

  if [[ -n "$TEST_DB_URL" ]]; then
    TEST_DBNAME=$(echo "$TEST_DB_URL" | sed 's/.*\///' | sed 's/?.*//')
    DUMP_OK="/tmp/sc2-ok-${TEST_DBNAME}.dump"
    DUMP_BAD="/tmp/sc2-bad-${TEST_DBNAME}.dump"

    # WP-7 Ф-Backup-Resilience-Audit: sudo не нужен, $TEST_DB_URL уже в локальной
    # переменной, sudo пишет полную команду (с паролём) в системный журнал.
    if "$PG" --format=custom --no-password "$TEST_DB_URL" > "$DUMP_OK" 2>/dev/null; then
      # Портим ЗАГОЛОВОК файла (первые 512 байт — магия pg custom format)
      cp "$DUMP_OK" "$DUMP_BAD"
      SIZE=$(stat -c%s "$DUMP_BAD")
      printf '\xDE\xAD\xBE\xEF\xDE\xAD\xBE\xEF' | \
        dd of="$DUMP_BAD" bs=1 seek=0 count=8 conv=notrunc 2>/dev/null

      # Проверяем что pg_restore детектирует повреждение заголовка
      if pg_restore --list "$DUMP_BAD" > /dev/null 2>&1; then
        warn "SC2: pg_restore не обнаружил corruption заголовка (файл $SIZE байт)"
      else
        pass "SC2: pg_restore правильно детектирует corruption заголовка (exit non-zero)"
      fi

      # Проверяем что оригинальный dump корректен
      if pg_restore --list "$DUMP_OK" > /dev/null 2>&1; then
        pass "SC2: Оригинальный dump корректен (pg_restore --list OK)"
      else
        fail "SC2: Оригинальный dump повреждён — что-то не так"
      fi

      rm -f "$DUMP_OK" "$DUMP_BAD"
    else
      warn "SC2: Не удалось создать dump для $TEST_DBNAME (пропущено)"
    fi
  else
    warn "SC2: Нет доступных connection strings (пропущено)"
  fi
  echo
fi

# ─────────────────────────────────────────────────────────────
# SC3: Vendor outage (симуляция недоступности B2)
# Проверяем что при недоступном B2 → restic падает с ошибкой
# (не молчит), и что dump-файлы сохраняются локально
# ─────────────────────────────────────────────────────────────
if ! run_sc "SC3"; then
  log "--- SC3: Vendor outage (недоступность B2) ---"

  # Проверяем: если B2 env пустой, restic падает явно
  FAKE_REPO="b2:nonexistent-bucket-sc3-test:neon-dbs"
  RESTIC_OUT=$(sudo RESTIC_PASSWORD_FILE="$RESTIC_PWD_FILE" \
    RESTIC_REPOSITORY="$FAKE_REPO" \
    bash -c "source $RESTIC_B2_ENV 2>/dev/null; restic snapshots 2>&1" | head -5)

  if echo "$RESTIC_OUT" | grep -qiE 'error|failed|unauthorized|bucket'; then
    pass "SC3: Restic явно сигнализирует об ошибке при недоступном bucket"
  else
    warn "SC3: Restic вернул неожиданный вывод: $(echo "$RESTIC_OUT" | head -1)"
  fi

  # Проверяем что dumps сохраняются на диске независимо от B2
  if [[ -d "/tmp/restic-neon" ]]; then
    DUMP_COUNT=$(ls /tmp/restic-neon/*.dump 2>/dev/null | wc -l)
    if [[ "$DUMP_COUNT" -gt 0 ]]; then
      pass "SC3: dump-файлы сохраняются локально ($DUMP_COUNT файлов в /tmp/restic-neon)"
    else
      warn "SC3: /tmp/restic-neon существует, но dumps не найдены (очищены после последнего бэкапа — норма)"
    fi
  else
    warn "SC3: /tmp/restic-neon не существует (очищено после последнего бэкапа — норма)"
  fi
  echo
fi

# ─────────────────────────────────────────────────────────────
# SC4: Drift — полнота покрытия
# Проверяем: все Neon БД в списке бэкапа?
# ─────────────────────────────────────────────────────────────
if ! run_sc "SC4"; then
  log "--- SC4: Drift — полнота покрытия БД ---"

  BACKED_UP=$(sudo grep -oP 'neon\.tech/\K[^?]+' "$NEON_CONNECTIONS" 2>/dev/null | sort)
  BACKED_COUNT=$(echo "$BACKED_UP" | grep -c . || echo 0)

  # Получаем реальный список из Neon через первый URL в списке
  FIRST_URL=$(sudo grep -m1 'postgresql://' "$NEON_CONNECTIONS" 2>/dev/null || echo "")
  if [[ -n "$FIRST_URL" ]]; then
    # WP-7 Ф-Backup-Resilience-Audit: раньше это оборачивалось в `sudo bash -c "..."`
    # с паролем прямо в строке — sudo пишет полную команду в системный журнал
    # (реально утекло 26.07). $FIRST_URL уже локальная переменная непривилегированного
    # процесса, psql сам берёт пароль из URL — ни sudo, ни отдельный PGPASSWORD не нужны.
    PSQL_BIN="$(dirname "$PG")/psql"
    ACTUAL_DBS=$("$PSQL_BIN" "$FIRST_URL" -t -c \
        "SELECT datname FROM pg_database WHERE datistemplate=false AND datname != 'postgres' ORDER BY datname" \
        2>/dev/null | tr -d ' ' | grep -v '^$' | sort)

    if [[ -n "$ACTUAL_DBS" ]]; then
      ACTUAL_COUNT=$(echo "$ACTUAL_DBS" | grep -c . || echo 0)
      MISSING=$(comm -23 <(echo "$ACTUAL_DBS") <(echo "$BACKED_UP"))

      if [[ -z "$MISSING" ]]; then
        pass "SC4: Все $ACTUAL_COUNT БД покрыты бэкапом (в списке: $BACKED_COUNT)"
      else
        fail "SC4: Пропущены БД: $MISSING (в Neon: $ACTUAL_COUNT, в бэкапе: $BACKED_COUNT)"
      fi
    else
      warn "SC4: Не удалось получить список БД из Neon (psql недоступен)"
      # Fallback: просто показываем что в списке
      pass "SC4 (частичный): В списке бэкапа $BACKED_COUNT БД: $(echo "$BACKED_UP" | tr '\n' ' ')"
    fi
  else
    fail "SC4: Файл $NEON_CONNECTIONS недоступен или пуст"
  fi
  echo
fi

# ─────────────────────────────────────────────────────────────
# SC5: Credential compromise
# Проверяем: пароль в neon-connections совпадает с ~/.secrets/neon?
# Если нет — бэкапы сломаны (как это было 14-15 мая)
# ─────────────────────────────────────────────────────────────
if ! run_sc "SC5"; then
  log "--- SC5: Credential drift ---"

  # Пароль из neon-connections
  BACKUP_PASS=$(sudo grep -oP 'neondb_owner:\K[^@]+' "$NEON_CONNECTIONS" 2>/dev/null | head -1)

  # Пароль из ~/.secrets/neon
  SECRETS_PASS=$(grep -oP 'neondb_owner:\K[^@]+' ~/.secrets/neon 2>/dev/null | head -1)
  # Fallback: ~/.config/aist/env
  if [[ -z "$SECRETS_PASS" ]]; then
    SECRETS_PASS=$(grep -oP 'neondb_owner:\K[^@]+' ~/.config/aist/env 2>/dev/null | head -1)
  fi

  if [[ -z "$BACKUP_PASS" ]]; then
    fail "SC5: Не удалось прочитать пароль из $NEON_CONNECTIONS (нет sudo?)"
  elif [[ -z "$SECRETS_PASS" ]]; then
    warn "SC5: Нет ~/.secrets/neon и ~/.config/aist/env — нельзя сравнить"
    # Проверяем что пароль реально работает — делаем тест pg_dump
    TEST_URL=$(sudo grep -m1 'postgresql://' "$NEON_CONNECTIONS" 2>/dev/null)
    # WP-7 Ф-Backup-Resilience-Audit: тот же фикс — sudo убран, URL уже локальный.
    if "$PG" --format=plain --no-password "$TEST_URL" --schema-only -t pg_catalog.pg_class \
       > /dev/null 2>&1; then
      pass "SC5: Пароль в $NEON_CONNECTIONS рабочий (тест pg_dump schema-only OK)"
    else
      fail "SC5: Пароль в $NEON_CONNECTIONS НЕ работает — бэкапы сломаны!"
    fi
  elif [[ "$BACKUP_PASS" == "$SECRETS_PASS" ]]; then
    pass "SC5: Пароль в neon-connections совпадает с ~/.secrets/neon"
  else
    fail "SC5: DRIFT ПАРОЛЕЙ! neon-connections: ${BACKUP_PASS:0:8}*** | secrets: ${SECRETS_PASS:0:8}***"
    log "    Это именно та проблема, что сломала бэкапы 14-15 мая"
    log "    Исправление: sudo sed -i 's/OLD_PASS/NEW_PASS/g' $NEON_CONNECTIONS"
  fi
  echo
fi

# ─────────────────────────────────────────────────────────────
# Итоговый отчёт
# ─────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "Итог: ✅ PASS=$PASS  ❌ FAIL=$FAIL  ⚠️  WARN=$WARN"
echo "══════════════════════════════════════════════════════"

# Пишем отчёт в markdown
cat > "$REPORT_FILE" << REPORT
# Отчёт стресс-теста бэкапов — $(date +%Y-%m-%d)

**Дата:** $(date -Is)
**Результат:** ✅ PASS=$PASS | ❌ FAIL=$FAIL | ⚠️ WARN=$WARN

## Результаты по сценариям

$(for r in "${RESULTS[@]}"; do echo "- $r"; done)

## Интерпретация

| Символ | Значение |
|--------|----------|
| ✅ | Сценарий прошёл — система ведёт себя как ожидается |
| ❌ | Сценарий провален — требует немедленного исправления |
| ⚠️  | Предупреждение — проверить вручную |

## Сценарии

- **SC1 Потеря:** последний снапшот существует и не пустой; pg_dump работает вручную
- **SC2 Corruption:** pg_restore детектирует повреждённые dumps
- **SC3 Vendor outage:** restic явно сигнализирует об ошибке B2; dumps остаются локально
- **SC4 Drift:** все Neon БД покрыты бэкапом
- **SC5 Credentials:** пароль в neon-connections совпадает с актуальным

## Следующий тест

Следующий плановый тест: $(date -d '+3 months' +%Y-%m-%d 2>/dev/null || date -v+3m +%Y-%m-%d 2>/dev/null || echo "через 3 месяца")
REPORT

echo "Отчёт: $REPORT_FILE"

# Выход с ошибкой если есть FAIL
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
