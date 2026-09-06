#!/usr/bin/env bash
# agent-session-hooks.sh — общий обработчик служебных вызовов жизненного цикла
# сессии (РП-544 Ф8.7, вариант Г). Один файл, три тонких регистрации в
# нативных хуках Claude Code / Kimi Code / Codex CLI, вместо того чтобы каждый
# раннер спрашивал разрешение на буквальную команду `bash ~/IWE/scripts/…`
# в тексте инструкций.
#
# Область (найдено при внедрении, сузило вариант Г против первоначального
# АрхГейта): `session-guard.sh open` требует номер РП обязательным
# аргументом, а номер определяется внутри разговора после WP Gate — то есть
# ПОСЛЕ старта раннера. На событие запуска (SessionStart) его физически нет,
# поэтому open остаётся внутри разговора и сюда не переносится. Close не
# требует номера — session-guard.sh сам резолвит открытый семафор агента
# (и уже умеет предупреждать при неоднозначности нескольких открытых сессий).
#
# Использование:
#   agent-session-hooks.sh close --agent <claude-code|kimi|codex>
#   agent-session-hooks.sh heartbeat-start --agent <kimi> [--interval N]
#
# Оба режима fail-open: раннер не должен зависать или падать из-за сторожа
# сессионного учёта. Диагностика — в stderr, не в stdout (у Kimi/Codex stdout
# хука может стать видимым текстом ответа модели).
#
# Реально подключено сейчас (проверь перед правкой, не верь этому комментарию
# как факту навсегда): SessionStart Kimi Code → heartbeat-start --agent kimi
# (`~/.kimi-code/config.toml`). Ветка close написана заранее для Claude/Codex,
# но ни для одного раннера пока не зарегистрирована — мёртвый код до тех пор.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_GUARD="$SCRIPT_DIR/session-guard.sh"

AGENT=""
INTERVAL=120
MODE="${1:-}"
shift || true

# "${2:-}" — не "$2": с `set -u` голый "$2" на "--agent" без значения (либо
# любой другой хвостовой флаг без пары) падает `unbound variable` и рушит
# весь скрипт, ровно то, что fail-open в шапке файла обещает не делать
# (найдено ревью перед первой заливкой в канон, до реального инцидента).
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:-}"; shift 2 2>/dev/null || shift ;;
    --interval) INTERVAL="${2:-$INTERVAL}"; shift 2 2>/dev/null || shift ;;
    *) shift ;;
  esac
done

if [ -z "$AGENT" ]; then
  echo "agent-session-hooks.sh: --agent обязателен" >&2
  exit 0  # fail-open — раннер не должен упасть из-за сторожа учёта
fi

case "$MODE" in
  close)
    # session-guard.sh close сам резолвит открытый семафор этого агента и
    # предупреждает при неоднозначности (несколько открытых РП) — здесь не
    # дублируем эту логику. Единственный открытый семафор → закрыт молча.
    IWE_AGENT="$AGENT" bash "$SESSION_GUARD" close --agent "$AGENT" >&2 2>&1 || \
      echo "agent-session-hooks.sh: close для $AGENT не прошёл (см. вывод выше) — не блокирует раннер, ручное закрытие текстом по-прежнему работает" >&2
    ;;
  heartbeat-start)
    # Идемпотентность: не плодить второй фоновый маяк, если он уже стучится
    # по семафору этого агента (повторный SessionStart в той же ОС-сессии —
    # например, после сжатия контекста). mkdir атомарен на POSIX — два почти
    # одновременных SessionStart больше не проходят проверку "PID мёртв" оба
    # разом (живой баг ревью перед первой заливкой: без замка второй запуск
    # плодил осиротевший фоновый процесс, который ни одна будущая проверка
    # уже не видела).
    HEARTBEAT_PID_FILE="$IWE_ROOT/.iwe-runtime/heartbeat-${AGENT}.pid"
    HEARTBEAT_LOCK_DIR="$IWE_ROOT/.iwe-runtime/heartbeat-${AGENT}.lock"
    if ! mkdir "$HEARTBEAT_LOCK_DIR" 2>/dev/null; then
      exit 0  # кто-то другой уже в этой же проверке прямо сейчас — не мешаем
    fi
    trap 'rmdir "$HEARTBEAT_LOCK_DIR" 2>/dev/null || true' EXIT

    if [ -f "$HEARTBEAT_PID_FILE" ] && kill -0 "$(cat "$HEARTBEAT_PID_FILE" 2>/dev/null)" 2>/dev/null; then
      exit 0  # уже стучит — второй не нужен
    fi
    # -f, не -x: скрипт запускается через `bash "$HEARTBEAT_SCRIPT"` ниже, а
    # не напрямую — исполняемый бит на файле для этого не нужен, и его
    # отсутствие (как у kimi-auto-heartbeat.sh в этом репозитории) не должно
    # маскироваться под «маяк не настроен» (живой баг, найден при первом
    # реальном прогоне после доставки в канон).
    HEARTBEAT_SCRIPT="$SCRIPT_DIR/${AGENT}-auto-heartbeat.sh"
    if [ ! -f "$HEARTBEAT_SCRIPT" ]; then
      echo "agent-session-hooks.sh: нет $HEARTBEAT_SCRIPT — для $AGENT маяк не настроен, пропускаю" >&2
      exit 0
    fi
    nohup bash "$HEARTBEAT_SCRIPT" --interval "$INTERVAL" >/dev/null 2>&1 &
    echo $! > "$HEARTBEAT_PID_FILE" 2>/dev/null || true
    ;;
  *)
    echo "agent-session-hooks.sh: неизвестный режим '$MODE' (ожидался close|heartbeat-start)" >&2
    exit 0
    ;;
esac

exit 0
