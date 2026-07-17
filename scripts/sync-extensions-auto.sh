#!/usr/bin/env bash
# scripts/sync-extensions-auto.sh — автоматическая обёртка над sync-extensions.sh
#
# Root (iwe-local-config) доставляется на сервер декларативно через Nix, не через
# git pull — поэтому pullScript (systemd-timers.nix) его не покрывает; см. WP-485,
# находка 17.07. Эта обёртка автоматизирует ручной шаг с другой стороны: запускает
# sync-extensions.sh, и при реальном diff в server-extensions/ коммитит и пушит —
# push триггерит существующий Action «Deploy to tsekh-1» (nixos-rebuild).
#
# Никогда тихий пропуск на реальном событии: пустой diff — тихо (штатно); сбой
# pull/sync/push — алерт; успешный auto-push — тоже алерт (единственный путь без
# человека в петле перед пересборкой прод-сервера). Lock-коллизия с параллельной
# git-сессией — исключение: ожидаемо, тихий пропуск тика (следующий через 2ч).
#
# Запускается: launchd com.iwe.sync-server-extensions (каждые 2 часа, см. plist).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_PREFIX="[sync-extensions-auto]"
LOCK_KEY="repo:iwe-server-config"
GATEWAY_LOCK_PY="$HOME/IWE/DS-my-strategy/scripts/lib/gateway-lock.py"

AIST_ENV="$HOME/.config/aist/env"
if [ -f "$AIST_ENV" ]; then
  set -a
  source "$AIST_ENV"
  set +a
fi

alert() {
  local text="$1"
  echo "$LOG_PREFIX $text"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=$text" > /dev/null || true
  fi
}

lock_acquire() {
  [ -f "$GATEWAY_LOCK_PY" ] || { echo "$LOG_PREFIX WARN gateway-lock.py not found — proceeding without lock"; return 0; }
  local out rc
  out=$(python3 "$GATEWAY_LOCK_PY" acquire "$LOCK_KEY" 1800 2>&1)
  rc=$?
  [ -n "$out" ] && echo "$LOG_PREFIX $out"
  case "$rc" in
    0) return 0 ;;
    2) echo "$LOG_PREFIX WARN gateway unreachable — proceeding without lock"; return 0 ;;
    *) echo "$LOG_PREFIX lock collision on $LOCK_KEY — другая сессия пишет в репозиторий, тихо пропускаю тик"; return 1 ;;
  esac
}
lock_release() {
  [ -f "$GATEWAY_LOCK_PY" ] || return 0
  python3 "$GATEWAY_LOCK_PY" release "$LOCK_KEY" >/dev/null 2>&1 || true
}

SYNC_LOG=""
on_exit() {
  [ -n "$SYNC_LOG" ] && rm -f "$SYNC_LOG"
  lock_release
}
trap on_exit EXIT

cd "$REPO_ROOT" || { alert "🚨 sync-extensions-auto: cd в $REPO_ROOT провалился"; exit 1; }

lock_acquire || exit 0

# Синхронизируемся с origin ДО генерации diff — иначе можем закоммитить поверх
# устаревшей базы и словить push-reject на каждом последующем тике.
if ! git pull --ff-only --quiet 2>&1; then
  alert "🚨 sync-extensions-auto: git pull --ff-only провалился (iwe-server-config разошёлся с origin) — auto-sync пропущен, нужна ручная проверка"
  exit 1
fi

SYNC_LOG="$(mktemp)"
if ! bash "$REPO_ROOT/scripts/sync-extensions.sh" > "$SYNC_LOG" 2>&1; then
  alert "🚨 sync-extensions-auto: sync-extensions.sh упал с ошибкой: $(tail -3 "$SYNC_LOG" | tr '\n' ' ')"
  exit 1
fi

CHANGED=$(git status --porcelain server-extensions/)
if [ -z "$CHANGED" ]; then
  echo "$LOG_PREFIX нет изменений, выход"
  exit 0
fi

FILE_COUNT=$(echo "$CHANGED" | wc -l | tr -d ' ')
FILE_LIST=$(echo "$CHANGED" | awk '{print $2}' | head -5 | tr '\n' ', ')

# Pathspec на commit (не только на add) — если параллельная сессия уже держит
# в индексе свою незакоммиченную правку вне server-extensions/, она сюда не
# попадёт (CLAUDE.md: несколько агентов работают в одном репозитории разом).
if ! git add server-extensions/; then
  alert "🚨 sync-extensions-auto: git add провалился — auto-sync пропущен"
  exit 1
fi
if ! git commit -m "sync: auto extensions (${FILE_COUNT} файлов) [sync-extensions-auto]" --quiet -- server-extensions/; then
  alert "🚨 sync-extensions-auto: git commit провалился — auto-sync пропущен"
  exit 1
fi

PUSH_OUT=""
if ! PUSH_OUT=$(git push 2>&1); then
  alert "🚨 sync-extensions-auto: коммит создан локально, но push провалился (${FILE_COUNT} файлов: ${FILE_LIST}...): $(echo "$PUSH_OUT" | tail -3 | tr '\n' ' ') — требуется ручное вмешательство"
  exit 1
fi

alert "✅ Автосинк конфигурации на сервер: ${FILE_COUNT} файлов (${FILE_LIST}...) — деплой на tsekh-1 запущен"
