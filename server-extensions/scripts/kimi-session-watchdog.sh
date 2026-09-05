#!/usr/bin/env bash
#
# kimi-session-watchdog.sh
# External mechanical guard against silent/hung agent sessions.
#
# Two detectors:
#   1. Legacy heartbeat check — semaphore heartbeat_at older than
#      SILENCE_THRESHOLD_S. Heartbeat only proves the heartbeat loop is
#      alive, not the agent (WP-7 F105: on 2026-09-03 a dead session
#      "lived" 24h on its heartbeat; on 2026-09-04 the reverse case
#      spammed this log every minute for 4h+). Alerts are now deduped:
#      one notification per episode, not one per loop iteration.
#   2. Progress detector (WP-7 F105, peer-session
#      2026-09-04-30-wp7-f105-thinking-hangs) — zombie = conjunction of:
#        a) session transcript file (wire.jsonl / harness .jsonl) silent
#           longer than WIRE_SILENCE_THRESHOLD_S;
#        b) cumulative CPU counters of the agent process tree show zero
#           delta between loop iterations (~60s interval, NOT point
#           samples — burst activity like 5s-per-90s polling still
#           registers);
#        c) zero network byte delta on the agent's connections.
#      Confirmed on two consecutive iterations before alerting.
#      Any single signal active => "busy, not hung" => stay silent.
#
#      Precondition (turn state): a session whose last turn has ENDED is
#      waiting for the pilot, not hung — no matter how long the transcript
#      stays silent. Without this filter every finished session would
#      alert 15 minutes after the agent's final answer (on 2026-09-05,
#      5 of 14 open Claude Code sessions were in exactly that state, one
#      for 13 hours). Kimi: wire.jsonl has explicit turn.prompt /
#      prompt.completed|prompt.aborted markers. Claude Code: the last
#      user|assistant record — assistant with stop_reason end_turn|
#      stop_sequence|max_tokens = turn ended; assistant with stop_reason
#      tool_use = waiting for a tool result OR the permission panel
#      (the pilot does not see that panel, so this IS worth an alert);
#      user = turn in flight. Unknown turn state falls through to the
#      three signals (never suppresses an alert on its own).
#
#      KNOWN LIMITATION (signal c, unvalidated): a silent-but-alive
#      stream (server computing without keep-alives) is
#      indistinguishable from a dead connection by byte counters alone.
#      Signal (c) was validated only on a true-positive case
#      (2026-09-04, frozen stream to the model API, zero bytes between
#      samples). VALIDATION PROTOCOL: the first 10 alerts are logged to
#      progress-detector-validation.jsonl with a full signal snapshot
#      and pilot_confirmed=null. Downgrade criterion after 10
#      pilot-confirmed episodes: 0-1 false positives (<=10%) => signal
#      (c) stays; >=2 false positives (>=20%) => drop signal (c) from
#      the conjunction and raise WIRE_SILENCE_THRESHOLD_S 900 -> 1500.
#      Until then every alert carries "unvalidated, check manually".
#
#      Extension-host weakness: Kimi sessions inside the VS Code
#      extension share one host process, so signals (b)/(c) are computed
#      against the whole extension-host tree — if ANY hosted session is
#      active we stay silent for all (false negatives accepted, false
#      positives avoided).
#
#      PID reuse: tree pids are snapshotted per iteration; a pid freed
#      and recycled by the OS between snapshot and poll could attribute
#      counters to an unrelated process. Not fixable without
#      pid+start-time pairing; accepted as a known limitation.
#
# Run manually:
#   bash scripts/kimi-session-watchdog.sh
# Or via launchd (see exocortex/launchd/com.iwe.kimi-watchdog.plist).

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
SILENCE_THRESHOLD_S="${SILENCE_THRESHOLD_S:-180}"
WIRE_SILENCE_THRESHOLD_S="${WIRE_SILENCE_THRESHOLD_S:-900}"
CHECK_INTERVAL_S="${CHECK_INTERVAL_S:-60}"
STATE_DIR="$IWE_ROOT/.iwe-runtime/watchdog-progress"
LOG_DIR="$IWE_ROOT/.iwe-runtime/logs"
VALIDATION_LOG="$LOG_DIR/progress-detector-validation.jsonl"
KIMI_SESSIONS_ROOT="${KIMI_SESSIONS_ROOT:-$HOME/.kimi-code/sessions}"
CLAUDE_PROJECTS_ROOT="${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

now_epoch() { date +%s; }

mac_notify() {
  local msg="$1" subtitle="$2"
  # Экранирование для интерполяции в AppleScript-строку: без этого кавычка
  # или обратный слэш в тексте ломают osascript, и уведомление молча
  # пропадает, хотя alert_once уже пометил эпизод как оповещённый.
  msg=${msg//\\/\\\\}; msg=${msg//\"/\\\"}
  subtitle=${subtitle//\\/\\\\}; subtitle=${subtitle//\"/\\\"}
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"IWE Watchdog\" subtitle \"$subtitle\" sound name \"Purr\"" 2>/dev/null || true
  fi
}

# alert_once <target-key> <message> <subtitle> <evidence-json> [quiet]
# One notification per episode: silent until the target shows activity again.
# quiet=1 — только лог (без macOS-уведомления и валидационного снимка);
# используется legacy heartbeat-детектором, чтобы не дублировать уведомление
# детектора прогресса об одном и том же эпизоде.
alert_once() {
  local key="$1" msg="$2" subtitle="$3" evidence="$4" quiet="${5:-0}"
  local state="$STATE_DIR/$key.state"
  if [ -f "$state" ] && grep -q '^alerted=1' "$state"; then
    return 0
  fi
  [ "$quiet" = "1" ] || mac_notify "$msg" "$subtitle"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $msg | $key" >> "$LOG_DIR/kimi-watchdog.log"
  # Validation protocol (see header): full snapshot for the first 10 alerts.
  if [ "$quiet" != "1" ]; then
    local n_alerts=0
    [ -f "$VALIDATION_LOG" ] && n_alerts=$(wc -l < "$VALIDATION_LOG" | tr -d ' ')
    if [ "$n_alerts" -lt 10 ]; then
      printf '{"recorded_at":"%s","target":"%s","pilot_confirmed":null,"signals":%s}\n' \
        "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$key" "$evidence" >> "$VALIDATION_LOG"
    fi
  fi
  update_counter "$key" alerted 1
}

# clear_alert <target-key> — called when the target is active again.
clear_alert() {
  local state="$STATE_DIR/$1.state"
  [ -f "$state" ] && update_counter "$1" alerted 0 || true
}

target_key() { printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || true; }

# --- signal b: cumulative CPU seconds of a pid set -------------------------
cpu_seconds() {
  # `|| true`: ps завершится ненулевым кодом, если pid умер между сбором
  # дерева и опросом (штатная гонка); под pipefail это уронило бы весь демон.
  # Дни в формате dd-hh:mm:ss отделяем ДО каскада *60: день — 86400 секунд,
  # а не 60*3600.
  ps -o time= -p "$1" 2>/dev/null | awk '
    {
      days=0; rest=$0
      if (rest ~ /-/) { split(rest, dh, "-"); days=dh[1]; rest=dh[2] }
      n=split(rest, a, ":"); m=1; s=0
      for (i=n; i>=1; i--) { s+=a[i]*m; m*=60 }
      total += days*86400 + s
    }
    END { print total+0 }' || true
}

tree_pids() {
  local p="$1" c
  echo "$p"
  for c in $(pgrep -P "$p" 2>/dev/null || true); do
    tree_pids "$c"
  done
}

# --- signal c: network bytes (in+out) for a pid set ------------------------
# Возвращает -1 при ошибке измерения (нет прав на nettop под launchd и т.п.) —
# «не смогли измерить» не должно быть неотличимо от «трафика нет» (инвариант:
# unknown => молчим). Вызывающий код трактует -1 как unknown.
# Источник данных — NET_SNAPSHOT: один снимок nettop на итерацию главного
# цикла (иначе N сессий = N вызовов nettop за цикл). Прямой вызов nettop
# остаётся как fallback (тесты, ручной запуск функции).
# Формат снимка — ТОЛЬКО `nettop -L` (CSV: `name.pid,bytes_in,bytes_out,`).
# `-l` печатает колонки через пробелы; парсер ниже их не понимает и молча
# возвращал 0 для любого pid, то есть сигнал (c) был «idle» всегда.
NET_SNAPSHOT_CMD=(nettop -P -L 1 -J "bytes_in,bytes_out" -x)
net_bytes() {
  local pids="$1" total=0 line pid bytes out
  # ${NET_SNAPSHOT+set}: отличаем «переменная не задана» (fallback на свой
  # вызов nettop) от «снимок снят, но вывод пуст» (это -1=unknown, а не
  # повторный вызов nettop на каждую сессию).
  if [ -n "${NET_SNAPSHOT+set}" ]; then
    out="$NET_SNAPSHOT"
  else
    out=$("${NET_SNAPSHOT_CMD[@]}" 2>/dev/null) || { echo "-1"; return 0; }
  fi
  [ "$out" != "NETTOP_FAILED" ] && [ -n "$out" ] || { echo "-1"; return 0; }
  while IFS= read -r line; do
    pid="${line##*.}"; pid="${pid%%,*}"
    case ",$pids," in *,"$pid",*)
      bytes=$(printf '%s' "$line" | awk -F',' '{print $2+$3}')
      total=$((total + bytes));;
    esac
  done <<< "$out"
  echo "$total"
}

# update_counter <key> <field> <value> — persist for next iteration.
update_counter() {
  local state="$STATE_DIR/$1.state" field="$2" value="$3"
  # Значение может содержать спецсимволы sed (&, /, \) — экранируем,
  # иначе запись в state-файл молча портится.
  value=${value//\\/\\\\}; value=${value//&/\\&}; value=${value//\//\\/}
  touch "$state"
  if grep -q "^$field=" "$state"; then
    sed -i '' "s/^$field=.*/$field=$value/" "$state"
  else
    echo "$field=$value" >> "$state"
  fi
}

read_counter() {
  grep "^$2=" "$STATE_DIR/$1.state" 2>/dev/null | cut -d= -f2 || echo ""
}

# turn_state <kind> <transcript-file> → idle | busy | unknown
# idle  = последний ход завершён, сессия ждёт пилота (не зависание).
# busy  = ход не завершён: ждём инструмент, модель или решение пилота на
#         панели разрешений (её пилот не видит — это повод для сигнала).
# unknown = маркеров в хвосте нет → решают три сигнала ниже (как раньше).
# Смотрим только хвост файла: у завершённого хода маркер конца всегда в
# последних строках; журналы бывают на десятки мегабайт.
turn_state() {
  local kind="$1" transcript="$2"
  [ -r "$transcript" ] || { echo unknown; return 0; }
  case "$kind" in
    kimi)
      # wire.jsonl: turn.prompt/prompt.accepted открывают ход,
      # prompt.completed/prompt.aborted закрывают; берём последний маркер.
      tail -n 400 "$transcript" | awk '
        /"type": ?"(turn\.prompt|prompt\.accepted)"/    { s = "busy" }
        /"type": ?"(prompt\.completed|prompt\.aborted)"/ { s = "idle" }
        END { print (s == "" ? "unknown" : s) }'
      ;;
    claude)
      # harness .jsonl: строки бывают длиной в мегабайты (tool_result),
      # поэтому JSON разбираем python3, а не регулярками по сырому тексту.
      command -v python3 >/dev/null 2>&1 || { echo unknown; return 0; }
      tail -n 200 "$transcript" | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get("type") in ("user", "assistant"):
        last = rec
if last is None:
    print("unknown")
elif last["type"] == "user":
    print("busy")
else:
    stop = (last.get("message") or {}).get("stop_reason")
    print("idle" if stop in ("end_turn", "stop_sequence", "max_tokens") else "busy")
'
      ;;
    *) echo unknown ;;
  esac
}

# progress_check <key> <kind> <transcript-file> <pid-list-csv> <label>
# Turn-state precondition, then three-signal conjunction; alert only when
# the turn is not finished and all three signals are silent on two
# consecutive iterations.
progress_check() {
  local key="$1" kind="$2" transcript="$3" pids="$4" label="$5"
  local wire_age now mtime turn
  now=$(now_epoch)
  mtime=$(stat -f '%m' "$transcript" 2>/dev/null || echo 0)
  wire_age=$((now - mtime))

  if [ "$wire_age" -le "$WIRE_SILENCE_THRESHOLD_S" ]; then
    update_counter "$key" streak 0
    clear_alert "$key"
    return 0
  fi

  # Ход завершён — сессия ждёт пилота, а не зависла (см. шапку).
  turn=$(turn_state "$kind" "$transcript")
  if [ "$turn" = "idle" ]; then
    update_counter "$key" streak 0
    clear_alert "$key"
    return 0
  fi

  # ps выводит CPU с долями секунды ("0:00.03") — дельты считаем через awk,
  # арифметика bash целочисленная и упала бы на дробном значении.
  local cpu net prev_cpu prev_net cpu_state="unknown" net_state="unknown"
  if [ -n "$pids" ]; then
    # Фильтр живости: мёртвый pid в списке — это отсутствие сигнала
    # (unknown => молчим), а не «процесс простаивает».
    local live_pids="" p
    for p in ${pids//,/ }; do
      kill -0 "$p" 2>/dev/null && live_pids="$live_pids $p"
    done
    pids=$(printf '%s' "$live_pids" | tr -s ' ' | sed 's/^ //; s/ /,/g')
  fi
  if [ -n "$pids" ]; then
    cpu=$(cpu_seconds "$pids")
    net=$(net_bytes "$pids")
    prev_cpu=$(read_counter "$key" cpu)
    prev_net=$(read_counter "$key" net)
    if [ -n "$prev_cpu" ]; then
      cpu_state=$(awk -v a="$cpu" -v b="$prev_cpu" 'BEGIN{print ((a-b)>0 ? "active" : "idle")}')
    fi
    # net_bytes = -1: измерение не удалось (например, нет прав на nettop) —
    # это unknown, а не «сеть молчит»; счётчик не портим.
    if [ "$net" != "-1" ]; then
      if [ -n "$prev_net" ]; then
        net_state=$(awk -v a="$net" -v b="$prev_net" 'BEGIN{print ((a-b)>0 ? "active" : "idle")}')
      fi
      update_counter "$key" net "$net"
    fi
    update_counter "$key" cpu "$cpu"
  fi

  # Signals b/c unknown (no attributable process) => cannot prove idle =>
  # stay silent (documented extension-host limitation, fail to no-alert).
  if [ "$cpu_state" = "unknown" ] || [ "$net_state" = "unknown" ]; then
    return 0
  fi
  if [ "$cpu_state" = "active" ] || [ "$net_state" = "active" ]; then
    update_counter "$key" streak 0
    clear_alert "$key"
    return 0
  fi

  local streak
  streak=$(read_counter "$key" streak)
  streak=$(( ${streak:-0} + 1 ))
  update_counter "$key" streak "$streak"
  [ "$streak" -lt 2 ] && return 0

  local turn_note="ход не завершён"
  [ "$turn" = "unknown" ] && turn_note="состояние хода неизвестно"
  alert_once "$key" \
    "Сессия молчит ${wire_age}s (${turn_note}): журнал, процесс и сеть неподвижны. Зависание (сигнал сети не валидирован — проверь глазами)." \
    "$label" \
    "{\"wire_age_s\":$wire_age,\"turn\":\"$turn\",\"cpu\":\"$cpu_state\",\"net\":\"$net_state\",\"streak\":$streak}"
}

latest_heartbeat_age() {
  local session_file="$1"
  local last_hb
  last_hb="$(grep "^heartbeat_at: " "$session_file" | tail -1 | cut -d' ' -f2- || true)"
  if [ -z "$last_hb" ]; then
    # No heartbeat yet: use session open time
    last_hb="$(grep "^opened_at: " "$session_file" | cut -d' ' -f2- || true)"
  fi
  if [ -z "$last_hb" ]; then
    # Битый/неполный семафор (нет ни heartbeat, ни opened_at): неизвестный
    # возраст — молчим (инвариант 3), а не алертим с бессмысленным числом.
    echo "0"
    return
  fi
  local hb_epoch now
  # heartbeat_at пишется в UTC с суффиксом Z. macOS date -j -f интерпретирует
  # литеральный Z как часть формата и парсит время как локальное, завышая возраст
  # на смещение часового пояса. Убираем Z и парсим как UTC (-u).
  hb_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${last_hb%Z}" +%s 2>/dev/null || date -d "$last_hb" +%s 2>/dev/null || echo "")"
  if [ -z "$hb_epoch" ]; then
    # Значение есть, но не парсится ни одним парсером (усечённая/битая запись):
    # неизвестный возраст — молчим, а не считаем от unix-эпохи (это давало бы
    # возраст ~1.7e9 секунд и гарантированный ложный алерт).
    echo "0"
    return
  fi
  now="$(now_epoch)"
  echo "$((now - hb_epoch))"
}

# kimi_wire_files — transcripts touched in the last 24h (active chats).
kimi_wire_files() {
  find "$KIMI_SESSIONS_ROOT" -name wire.jsonl -mtime -1 2>/dev/null || true
}

# kimi_pids — CLI processes if any, else the VS Code extension host(s).
kimi_pids() {
  local cli ext
  cli=$(pgrep -f 'kimi-code.*bin/kimi|\.kimi-code/bin/kimi' 2>/dev/null || true)
  if [ -n "$cli" ]; then
    printf '%s\n' "$cli" | paste -sd, -
    return 0
  fi
  ext=$(pgrep -f 'Code Helper \(Plugin\)' 2>/dev/null || true)
  printf '%s\n' "$ext" | paste -sd, -
}

run_forever() {
while true; do
  # Один снимок nettop на итерацию — разделяют все проверки прогресса.
  NET_SNAPSHOT=$("${NET_SNAPSHOT_CMD[@]}" 2>/dev/null || printf 'NETTOP_FAILED')

  # Detector 1: legacy heartbeat (deduped, log-only — уведомление даёт
  # детектор прогресса, чтобы не было двух сообщений об одном эпизоде).
  for session in "$SESSION_DIR"/kimi-*.open; do
    [ -f "$session" ] || continue
    age="$(latest_heartbeat_age "$session")"
    if [ "$age" -gt "$SILENCE_THRESHOLD_S" ]; then
      wp="$(grep "^wp: " "$session" | cut -d' ' -f2- || echo "unknown")"
      task="$(grep "^task: " "$session" | cut -d' ' -f2- || echo "unknown")"
      alert_once "$(target_key "$session")" \
        "Kimi молчит ${age}s в WP:${wp}. Возможно, зависание (heartbeat-сигнал, низкая точность)." \
        "$task" \
        "{\"heartbeat_age_s\":$age,\"signal\":\"heartbeat-only\"}" \
        1
    else
      clear_alert "$(target_key "$session")"
    fi
  done

  # Detector 2a: claude-code sessions (pid + harness transcript known).
  for session in "$SESSION_DIR"/claude-code-*.open; do
    [ -f "$session" ] || continue
    pid="$(grep "^pid: " "$session" | tail -1 | cut -d' ' -f2- || true)"
    hsid="$(grep "^harness_session_id: " "$session" | tail -1 | cut -d' ' -f2- || true)"
    [ -n "$pid" ] && [ -n "$hsid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    # -print -quit: find сам останавливается на первом совпадении; связка
    # `find | head -1` под pipefail убивала демон через SIGPIPE (141), когда
    # совпадений несколько (.worktrees/ содержит копии того же hsid.jsonl).
    transcript=$(find "$CLAUDE_PROJECTS_ROOT" -name "$hsid.jsonl" -mtime -1 -print -quit 2>/dev/null || true)
    [ -n "$transcript" ] || continue
    all_pids=$(tree_pids "$pid" | paste -sd, - || true)
    wp="$(grep "^wp: " "$session" | cut -d' ' -f2- || echo "unknown")"
    progress_check "$(target_key "claude-$hsid")" claude "$transcript" "$all_pids" "claude-code $wp"
  done

  # Detector 2b: kimi sessions (wire.jsonl; process attribution weak for
  # the VS Code extension host — see header).
  # KIMI_PID_OVERRIDE — test hook: pin the pid set explicitly.
  kpids="${KIMI_PID_OVERRIDE:-$(kimi_pids)}"
  while IFS= read -r wire; do
    [ -n "$wire" ] || continue
    sid=$(basename "$(dirname "$(dirname "$(dirname "$wire")")")")
    progress_check "$(target_key "kimi-$sid")" kimi "$wire" "$kpids" "kimi $sid"
  done < <(kimi_wire_files)

  # Гигиена состояния: state-файлы завершившихся сессий старше 7 дней
  # удаляем, иначе демон копит по файлу на каждую когда-либо виденную сессию.
  find "$STATE_DIR" -name '*.state' -mtime +7 -delete 2>/dev/null || true

  sleep "$CHECK_INTERVAL_S"
done
}

# Запущен как программа — крутим цикл; подключён через `source` (тесты) —
# только определяем функции.
[ "${BASH_SOURCE[0]}" != "$0" ] || run_forever
