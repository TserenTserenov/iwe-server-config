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

# Re-exec under a modern bash if one is installed (WP-7 Ф174, 24.09.2026):
# the launchd plist's restricted PATH resolves plain `bash` to /bin/bash,
# Apple's stock 3.2.57 — its brace-expansion scanner does not skip $(...),
# so `eval "$(sed -n "/^f() {/,/^}/p" "$1")"` (used by session-guard's own
# tests) silently splits into two broken sed invocations and every such
# test reports its target function "not found". That stalled this script's
# own commits for 5 days (test gate below, "GATE FAIL" on every tick) with
# no way to tell from the log that the interpreter, not the code, was at
# fault. Prepending a Homebrew bash to PATH fixes every subsequent bare
# `bash` call in this script too (the test gate's `test_runner=(bash ...)`).
if [ "${BASH_VERSINFO[0]}" -lt 5 ] && [ -z "${SYNC_EXTENSIONS_REEXEC:-}" ]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$candidate" ] || continue
    export SYNC_EXTENSIONS_REEXEC=1 PATH="$(dirname "$candidate"):$PATH"
    exec "$candidate" "$0" "$@"
  done
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_PREFIX="[sync-extensions-auto]"
LOCK_KEY="repo:iwe-server-config"
GATEWAY_LOCK_PY="$HOME/IWE/DS-my-strategy/scripts/lib/gateway-lock.py"

AIST_ENV="$HOME/.config/aist/env"
if [ -f "$AIST_ENV" ]; then
  # A syntax error partway through this file (WP-7 Ф174, 24.09.2026: an
  # unquoted value on line 17 broke on `<`/`>`) makes `source` run every
  # line before the error and silently stop -- variables declared after
  # it, including TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID, never get set, and
  # alert()/send_telegram() then fail open with no message at all instead
  # of a warning. bash -n catches that before source runs anything.
  if ! bash -n "$AIST_ENV" 2>/dev/null; then
    echo "$LOG_PREFIX WARN: $AIST_ENV has a syntax error -- variables past the bad line will not load"
  fi
  set -a
  source "$AIST_ENV"
  set +a
fi

# Stateful-эскалация вместо слепого realtime-на-каждый-тик (WP-538 Ф7, 08.09,
# пир-сессия с Kimi+Codex — этот скрипт бьёт каждые 2 часа и раньше слал
# идентичный текст на каждый повтор одного и того же хронического сбоя без
# подавления, до 4+ раз/ночь). notify_escalation_update() — DS-my-strategy,
# та же state-директория, что уже 3 месяца работает под notify_dedup_allow
# (bash 3.2-совместимость, per-key flock, fail-open) — не заводить свою
# отдельную реализацию. Все известные классы сбоя этого скрипта, для alert_ok
# (перечислять новый класс сюда при добавлении нового failure-branch):
ALERT_CLASSES=(cd pull source-behind source-snapshot sync-script test-env test-gate add commit push)
NOTIFY_LIB="${SYNC_EXTENSIONS_NOTIFY_LIB:-$HOME/IWE/DS-my-strategy/scripts/lib/notification-render.sh}"
NOTIFY_LIB_AVAILABLE=false
if [ -f "$NOTIFY_LIB" ]; then
  # shellcheck source=/dev/null
  . "$NOTIFY_LIB"
  NOTIFY_LIB_AVAILABLE=true
fi

send_telegram() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    # Previously silent (WP-7 Ф174, 24.09.2026): a broken $AIST_ENV upstream
    # (see the bash -n check above) left these unset for 5 days, and every
    # alert()/alert_ok() call after that did nothing with no trace in the
    # log -- indistinguishable from "the dedup throttle suppressed it".
    echo "$LOG_PREFIX WARN: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set -- message not sent: $text"
    return 0
  fi
  local response
  response=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$text") || {
    echo "$LOG_PREFIX WARN: Telegram send failed (curl error) -- message not delivered"
    return 0
  }
  case "$response" in
    *'"ok":true'*) : ;;
    *) echo "$LOG_PREFIX WARN: Telegram send rejected: ${response:0:200}" ;;
  esac
}

# alert <class> <text>: сбой класса <class>. Первый раз — сразу; повтор того
# же класса — не чаще раза в NOTIFY_ESCALATION_REPEAT_MIN (дефолт 360 = раз
# в 6 часов на двухчасовом таймере), с длительностью и числом попыток в
# тексте повтора вместо голого дубля.
#
# --urgent-after-sec (WP-484, 14.09, пир-сессия с Kimi+Codex): живой
# инцидент — этот же троттлинг 3 суток подряд подавлял один и тот же класс
# `pull`, и текст «повторяется N раз» никогда не ушёл пилоту, потому что
# каждый повтор попадал в то же 6-часовое окно подавления. Порог ниже
# работает НЕЗАВИСИМО от repeat_after_min: при пересечении длительности
# инцидента одно сообщение уходит немедленно, минуя частотный троттлинг,
# после чего откат на собственный цикл urgent_repeat_after_min — не «раз в
# сутки навсегда», а «раз в сутки, пока инцидент открыт».
NOTIFY_ESCALATION_URGENT_AFTER_SEC="${NOTIFY_ESCALATION_URGENT_AFTER_SEC:-21600}"
NOTIFY_ESCALATION_URGENT_REPEAT_MIN="${NOTIFY_ESCALATION_URGENT_REPEAT_MIN:-1440}"
alert() {
  local class="$1" text="$2"
  echo "$LOG_PREFIX $text"
  local full_text="$text"
  if $NOTIFY_LIB_AVAILABLE; then
    if notify_escalation_update "sync-extensions-auto/$class" fail \
         --repeat-after-min 360 \
         --urgent-after-sec "$NOTIFY_ESCALATION_URGENT_AFTER_SEC" \
         --urgent-repeat-after-min "$NOTIFY_ESCALATION_URGENT_REPEAT_MIN"; then
      if [ "$NOTIFY_ESCALATION_PHASE" = "urgent" ]; then
        full_text="🆘 $text — конвейер доставки стоит уже $(notify_format_duration "$NOTIFY_ESCALATION_DURATION_SEC") ($NOTIFY_ESCALATION_COUNT попыток подряд), нужно ручное вмешательство"
      elif [ "$NOTIFY_ESCALATION_PHASE" = "ongoing" ]; then
        full_text="$text (повторяется $NOTIFY_ESCALATION_COUNT раз подряд, не решается уже $(notify_format_duration "$NOTIFY_ESCALATION_DURATION_SEC"))"
      fi
    else
      echo "$LOG_PREFIX подавлено (эскалация того же класса уже отправлена недавно, попытка #${NOTIFY_ESCALATION_COUNT:-?})"
      return 0
    fi
  fi
  send_telegram "$full_text"
}

# alert_ok <text>: успешный прогон — снимает активную эскалацию у КАЖДОГО
# класса, у которого она есть (cold-review WP-538 Ф7, 08.09: один прогон
# роняет максимум один класс, но между прогонами могут накопиться отдельные
# незакрытые инциденты в РАЗНЫХ классах — например pull упал на прогоне N,
# push упал на прогоне N+1 уже после того, как pull снова заработал; первый
# успешный прогон после этого восстанавливает оба сразу). Раньше цикл
# перезаписывал recovered_from на каждой итерации — восстановление первого
# класса терялось молча, пилот видел цифры только последнего.
alert_ok() {
  local text="$1"
  local full_text="$text"
  if $NOTIFY_LIB_AVAILABLE; then
    local class recovered_parts=()
    for class in "${ALERT_CLASSES[@]}"; do
      if notify_escalation_update "sync-extensions-auto/$class" ok; then
        recovered_parts+=("$class: $NOTIFY_ESCALATION_COUNT попыток, $(notify_format_duration "$NOTIFY_ESCALATION_DURATION_SEC")")
      fi
    done
    if [ "${#recovered_parts[@]}" -gt 0 ]; then
      local joined
      joined=$(printf '%s; ' "${recovered_parts[@]}")
      full_text="$text (восстановилось: ${joined%; })"
    fi
  fi
  echo "$LOG_PREFIX $full_text"
  send_telegram "$full_text"
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
SOURCE_CLONE_LOG=""
SOURCE_SNAPSHOT=""

# Test env shim (WP-530, peer-session 2026-09-16 с Kimi): ~15 скриптов в
# server-extensions/scripts/*.sh делают `source ".../.claude/lib/..."`, но
# этот checkout хранит ту же библиотеку под именем `claude-lib/` (без точки)
# — на tsekh-1 разрыва нет, там modules/iwe-extensions-sync.nix rsync'ит
# claude-lib/ в реальный .claude/lib/ при деплое. Здесь символические ссылки
# только на время прогона тестового гейта: коммитить их нельзя — на Цехе уже
# есть настоящий .claude/lib/ от Nix, симлинк с тем же именем поверх него
# столкнётся с деплоем непредсказуемо.
EXT_DIR="$REPO_ROOT/server-extensions"
TEST_ENV_CREATED=()
setup_test_env() {
  local pairs=(claude-lib:.claude/lib claude-skills:.claude/skills claude-hooks:.claude/hooks claude-scripts:.claude/scripts)
  local pair src target rel
  for pair in "${pairs[@]}"; do
    src="${pair%%:*}"
    target="${pair#*:}"
    rel="../$src"
    mkdir -p "$EXT_DIR/$(dirname "$target")"
    if [ -e "$EXT_DIR/$target" ] || [ -L "$EXT_DIR/$target" ]; then
      if [ -L "$EXT_DIR/$target" ] && [ "$(readlink "$EXT_DIR/$target")" = "$rel" ]; then
        continue  # уже настроено (например, хвост незавершённого прошлого прогона) — не наш симлинк, cleanup его не трогает
      fi
      echo "$LOG_PREFIX ABORT: $EXT_DIR/$target уже существует и это не ожидаемый симлинок на $src — окружению нельзя доверять, тестовый гейт не запускаю" >&2
      return 1
    fi
    ln -s "$rel" "$EXT_DIR/$target"
    TEST_ENV_CREATED+=("$EXT_DIR/$target")
  done
}
cleanup_test_env() {
  local path
  for path in "${TEST_ENV_CREATED[@]:-}"; do
    [ -n "$path" ] && rm -f "$path"
  done
}

on_exit() {
  [ -n "$SYNC_LOG" ] && rm -f "$SYNC_LOG"
  [ -n "$SOURCE_CLONE_LOG" ] && rm -f "$SOURCE_CLONE_LOG"
  [ -n "$SOURCE_SNAPSHOT" ] && rm -rf "$SOURCE_SNAPSHOT"
  cleanup_test_env
  lock_release
}
trap on_exit EXIT

cd "$REPO_ROOT" || { alert cd "🚨 sync-extensions-auto: cd в $REPO_ROOT провалился"; exit 1; }

lock_acquire || exit 0

# Синхронизируемся с origin ДО генерации diff — иначе можем закоммитить поверх
# устаревшей базы и словить push-reject на каждом последующем тике.
if ! git pull --ff-only --quiet 2>&1; then
  alert pull "🚨 sync-extensions-auto: git pull --ff-only провалился (iwe-server-config разошёлся с origin) — auto-sync пропущен, нужна ручная проверка"
  exit 1
fi

# Канонический ~/IWE — общая рабочая копия нескольких живых сессий. Защитный
# iwe-safe-pull по контракту только проверяет её и никогда не двигает HEAD,
# поэтому прежняя связка «safe-pull, затем ожидаем обновлённый HEAD» навсегда
# блокировала доставку после первого push из изолированной worktree. Берём
# отдельный снимок origin/main и вообще не меняем общую копию.
SOURCE_REMOTE=$(git -C "$HOME/IWE" remote get-url origin 2>/dev/null || true)
if [ -z "$SOURCE_REMOTE" ]; then
  alert source-snapshot "🚨 sync-extensions-auto: не удалось определить origin источника ~/IWE — auto-sync пропущен"
  exit 1
fi
SOURCE_SNAPSHOT=$(mktemp -d "${TMPDIR:-/tmp}/iwe-extension-source.XXXXXX")
SOURCE_CLONE_LOG=$(mktemp)
if ! git clone --quiet --depth 1 --branch main "$SOURCE_REMOTE" "$SOURCE_SNAPSHOT" > "$SOURCE_CLONE_LOG" 2>&1; then
  echo "$LOG_PREFIX source snapshot error tail: $(tail -3 "$SOURCE_CLONE_LOG" | tr '\n' ' ')"
  alert source-snapshot "🚨 sync-extensions-auto: не удалось получить чистый снимок origin/main для ~/IWE — auto-sync пропущен"
  exit 1
fi

SYNC_LOG="$(mktemp)"
if ! IWE_EXTENSIONS_SOURCE_ROOT="$SOURCE_SNAPSHOT" \
     bash "$REPO_ROOT/scripts/sync-extensions.sh" > "$SYNC_LOG" 2>&1; then
  echo "$LOG_PREFIX sync-extensions.sh error tail: $(tail -3 "$SYNC_LOG" | tr '\n' ' ')"
  alert sync-script "🚨 sync-extensions-auto: sync-extensions.sh упал с ошибкой — подробности в логе на Маке"
  exit 1
fi

CHANGED=$(git status --porcelain server-extensions/)
if [ -z "$CHANGED" ]; then
  echo "$LOG_PREFIX нет изменений, выход"
  exit 0
fi

FILE_COUNT=$(echo "$CHANGED" | wc -l | tr -d ' ')
FILE_LIST=$(echo "$CHANGED" | awk '{print $2}' | head -5 | tr '\n' ', ')

# Test gate (WP-7 Ф111, живой инцидент 06.09: черновик хука со всеми
# известными позже дефектами уехал на сервер через 5 минут после написания,
# раньше первого ревью — это тик, который его бы синхронизировал). Для
# каждого изменённого файла ищем соседний tests/-каталог и любой тест,
# чьё имя содержит имя файла (обе конвенции этого репо: test-<name>.sh и
# <name>-<scenario>-smoke.sh), запускаем; провал — тик отменяется целиком.
#
# Честная граница (peer-review с Kimi, 06.09): гейт снижает вероятность
# ПОВТОРА уже известной регрессии — он не ловит то, для чего теста ещё не
# написано. Сегодняшний инцидент был именно такого рода (тесты прошли,
# два круга холодного ревью потом нашли то, что тесты ещё не проверяли) —
# этот гейт его не поймал бы. Файл без соседнего теста проходит без
# проверки, как и раньше.
#
# Открытое несогласие (peer, зафиксировано дословно по требованию
# Kimi — WP-7 карточка, пир-сессия 2026-09-06-13): «ленивый гейт (skip if
# no test) создаёт перверсный стимул к удалению тестов вместо их починки.
# Рекомендуется при следующем ревизии рассмотреть обязательность тестового
# покрытия для всех файлов в server-extensions/ либо альтернативный
# механизм стимула (например, блокировка merge при снижении покрытия)».
# The re-exec at the top of this script already tried to get a bash >= 5
# onto PATH; if none was installed, every `test_runner=(bash "$test_file")`
# call below still runs under Apple's stock 3.2 and can reproduce the
# false-failure class this fixes (WP-7 Ф174) again. Fail loud instead of
# silently testing under the interpreter that caused the 5-day stall.
GATE_BASH_VERSION=$(bash -c 'echo "$BASH_VERSION"')
case "$GATE_BASH_VERSION" in
  [0-4].*)
    alert test-env "🚨 sync-extensions-auto: только bash $GATE_BASH_VERSION найден -- тестовый гейт не запускаю, нужен bash >= 5 (например, brew install bash)"
    exit 1
    ;;
esac

if ! setup_test_env; then
  alert test-env "🚨 sync-extensions-auto: тестовое окружение (.claude/lib и соседи) не удалось подготовить — auto-sync отменён, подробности в логе на Маке"
  exit 1
fi

GATE_LOG=$(mktemp)
GATE_FAILED=false
delivery_source_path() {
  local delivered_path="$1"
  case "$delivered_path" in
    server-extensions/scripts/*)
      printf '%s/scripts/%s\n' "$SOURCE_SNAPSHOT" "${delivered_path#server-extensions/scripts/}"
      ;;
    server-extensions/extensions/*)
      printf '%s/extensions/%s\n' "$SOURCE_SNAPSHOT" "${delivered_path#server-extensions/extensions/}"
      ;;
    server-extensions/claude-skills/*)
      printf '%s/.claude/skills/%s\n' "$SOURCE_SNAPSHOT" "${delivered_path#server-extensions/claude-skills/}"
      ;;
    server-extensions/claude-hooks/*)
      printf '%s/.claude/hooks/%s\n' "$SOURCE_SNAPSHOT" "${delivered_path#server-extensions/claude-hooks/}"
      ;;
    server-extensions/claude-scripts/*)
      printf '%s/.claude/scripts/%s\n' "$SOURCE_SNAPSHOT" "${delivered_path#server-extensions/claude-scripts/}"
      ;;
    *) return 1 ;;
  esac
}
while IFS= read -r changed_line; do
  [ -n "$changed_line" ] || continue
  rel_path=$(echo "$changed_line" | awk '{print $2}')
  [ -n "$rel_path" ] || continue
  case "$rel_path" in
    */tests/*) continue ;;  # тест сам себя не тестирует
  esac
  source_path=$(delivery_source_path "$rel_path" || true)
  [ -n "$source_path" ] && [ -f "$source_path" ] || continue
  base_noext=$(basename "$source_path")
  base_noext="${base_noext%.*}"
  test_dir="$(dirname "$source_path")/tests"
  [ -d "$test_dir" ] || continue
  found_tests=$(find "$test_dir" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) 2>/dev/null | grep -F -- "$base_noext" || true)
  [ -n "$found_tests" ] || continue
  while IFS= read -r test_file; do
    [ -n "$test_file" ] || continue
    case "$test_file" in
      *.py) test_runner=(python3 "$test_file") ;;
      *)    test_runner=(bash "$test_file") ;;
    esac
    if ! "${test_runner[@]}" >> "$GATE_LOG" 2>&1; then
      echo "GATE FAIL: $test_file (для $rel_path)" >> "$GATE_LOG"
      GATE_FAILED=true
    fi
  done <<< "$found_tests"
done <<< "$CHANGED"

if [ "$GATE_FAILED" = true ]; then
  # Раньше в лог (и в Telegram) шёл tail -5 всего GATE_LOG — при нескольких
  # запущенных тестах в одном тике хвост почти всегда состоит из PASS-строк
  # ПОСЛЕДНЕГО (прошедшего) теста, а сама строка "GATE FAIL: <file>" от более
  # раннего провалившегося теста тонет выше и не попадает даже в лог агенту
  # (найдено этой сессией по факту: живой лог 09.09 показывал только PASS/WARN,
  # не саму причину провала). Явно выделяем FAIL-маркеры + пишем полный лог.
  echo "$LOG_PREFIX test-gate failed: $(grep '^GATE FAIL:' "$GATE_LOG" | tr '\n' ' ')"
  echo "$LOG_PREFIX test-gate full output follows:"
  cat "$GATE_LOG"
  alert test-gate "🚨 sync-extensions-auto: тестовый гейт нашёл провал — auto-sync отменён, коммит не создан ни для одного из ${FILE_COUNT} файлов (${FILE_LIST}...), подробности в логе на Маке"
  rm -f "$GATE_LOG"
  exit 1
fi
rm -f "$GATE_LOG"

# Явно, не полагаясь на on_exit() в конце скрипта (cold-review, Critical,
# WP-530 2026-09-16): trap срабатывает ПОСЛЕ git add/commit/push ниже --
# симлинки setup_test_env() ещё лежат бы в дереве в момент add и реально
# закоммитились бы (`git add -n` живьём подтвердил: подхватывает все 4
# .claude/{lib,skills,hooks,scripts}), нарушая ровно то, ради чего они
# сделаны временными (см. комментарий у setup_test_env выше).
cleanup_test_env

# Pathspec на commit (не только на add) — если параллельная сессия уже держит
# в индексе свою незакоммиченную правку вне server-extensions/, она сюда не
# попадёт (CLAUDE.md: несколько агентов работают в одном репозитории разом).
if ! git add server-extensions/; then
  alert add "🚨 sync-extensions-auto: git add провалился — auto-sync пропущен"
  exit 1
fi
if ! git commit -m "sync: auto extensions (${FILE_COUNT} файлов) [sync-extensions-auto]" --quiet -- server-extensions/; then
  alert commit "🚨 sync-extensions-auto: git commit провалился — auto-sync пропущен"
  exit 1
fi

PUSH_OUT=""
if ! PUSH_OUT=$(git push 2>&1); then
  echo "$LOG_PREFIX push error tail: $(echo "$PUSH_OUT" | tail -3 | tr '\n' ' ')"
  alert push "🚨 sync-extensions-auto: коммит создан локально, но push провалился (${FILE_COUNT} файлов: ${FILE_LIST}...) — требуется ручное вмешательство, подробности в логе на Маке"
  exit 1
fi

alert_ok "✅ Автосинк конфигурации на сервер: ${FILE_COUNT} файлов (${FILE_LIST}...) — деплой на tsekh-1 запущен"
