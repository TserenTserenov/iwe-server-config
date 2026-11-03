#!/usr/bin/env bash
# notify-retry-policy.sh — политика повторов одного и того же алерта пилоту
# (WP-538 Ф8, пир-сессия Kimi+Codex, 26.10): первая отправка сразу, повторы
# с нарастающим шагом 1ч → 4ч; с 24ч от первого события — эскалация ЗАМЕНЯЕТ
# дальнейшие повторы (контракт уточнён холодным ревью Codex, 26.10: ступень
# «повтор через 24ч» при пороге эскалации 24ч недостижима и потому из
# контракта убрана, а не висит мёртвой веткой): источник получает слово
# `escalate` и уходит в notify_escalation_update (своя urgent-каденция).
#
# fingerprint строит источник и он СЕМАНТИЧЕСКИЙ (что именно сломалось), без
# растущих чисел вроде секунд ожидания — иначе каждый тик выглядит «новым»
# событием и подавления нет вообще. Смена fingerprint = новый инцидент =
# сброс окна (первая отправка сразу).
#
# Контракт:
#   notify_repeat_gate <source_key> <fingerprint> [incident_age_sec]
#     stdout, одно слово в первой строке: send | suppress | escalate.
#     При send во второй строке — суффикс возраста «(без изменений N ч)»
#     (возраст = время с последней отправки; при самой первой — «0 ч»).
#     incident_age_sec — возраст ТЕКУЩЕГО инцидента, если источник узнал о
#     нём постфактум (пример: ds-publish узнаёт о длинном ожидании только
#     когда оно уже закончилось): при создании нового state first_epoch
#     отматывается на это число секунд, и одно-единственное суточное
#     ожидание сразу даёт escalate, а не «первую отправку» (холодное ревью
#     Codex, 26.10).
#   notify_repeat_reset <source_key>
#     Сброс после восстановления: state удаляется, следующий gate = send.
#
# State: per-key файл в ${NOTIFY_REPEAT_STATE_DIR:-~/.claude/state/notify-repeat/}
# (имя = source_key с заменой '/' на '__'), формат «fingerprint last_sent_epoch
# first_epoch». Три поля, счётчика отправок нет: ступень выводится из
# (last_sent - first_epoch) — 0 → шаг 1ч, ≥1ч → шаг 4ч, ≥5ч → шаг 24ч.
# flock на всё время чтения-решения-записи (свой FD 9, как остальные
# notify-библиотеки разводят FD между собой), запись через tmp+mv.
# Безопасно под set -u.

NOTIFY_REPEAT_STATE_DIR="${NOTIFY_REPEAT_STATE_DIR:-$HOME/.claude/state/notify-repeat}"
# Порог эскалации — 24ч от первого события (холодное ревью Codex, 26.10:
# при 4ч эскалация наступала раньше ступени повтора 4ч и ступени 4ч/24ч
# были недостижимы). Должен быть не меньше суммы ступеней 1ч+4ч.
NOTIFY_REPEAT_ESCALATE_AFTER_SEC="${NOTIFY_REPEAT_ESCALATE_AFTER_SEC:-86400}"

_notify_repeat_state_file() {
    local safe_key="${1//\//__}"
    printf '%s/%s' "$NOTIFY_REPEAT_STATE_DIR" "$safe_key"
}

# Ступень повтора (секунды) по смещению last_sent относительно first_epoch.
_notify_repeat_step() {
    local offset="$1"
    if [ "$offset" -lt 3600 ]; then
        echo 3600
    elif [ "$offset" -lt 18000 ]; then
        echo 14400
    else
        echo 86400
    fi
}

notify_repeat_gate() {
    local source_key="$1" fingerprint="$2" incident_age_sec="${3:-0}"
    [[ "$incident_age_sec" =~ ^[0-9]+$ ]] || incident_age_sec=0
    local dir="$NOTIFY_REPEAT_STATE_DIR"
    local state_file lock_file
    state_file=$(_notify_repeat_state_file "$source_key")
    lock_file="$state_file.lock"
    mkdir -p "$dir" 2>/dev/null || {
        echo "WARN: notify_repeat_gate: не удалось создать $dir — подавление отключено, шлю" >&2
        echo "send"; echo "(без изменений 0 ч)"
        return 0
    }

    exec 9>"$lock_file" 2>/dev/null || { echo "send"; echo "(без изменений 0 ч)"; return 0; }
    flock 9 2>/dev/null || { exec 9>&-; echo "send"; echo "(без изменений 0 ч)"; return 0; }

    local now stored_fp="" last_sent=0 first_epoch=0
    now=$(date -u +%s)
    if [ -f "$state_file" ]; then
        local raw
        raw=$(cat "$state_file" 2>/dev/null)
        stored_fp=$(printf '%s' "$raw" | awk '{print $1}')
        last_sent=$(printf '%s' "$raw" | awk '{print $2}')
        first_epoch=$(printf '%s' "$raw" | awk '{print $3}')
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        [[ "$first_epoch" =~ ^[0-9]+$ ]] || first_epoch=0
    fi

    local decision suffix_age=0 fp_new=0
    if [ -z "$stored_fp" ] || [ "$stored_fp" != "$fingerprint" ] || [ "$first_epoch" -eq 0 ]; then
        # Первое событие или новый fingerprint — сброс окна. Если источник
        # узнал об инциденте постфактум (incident_age_sec > 0), окно
        # отматывается на реальный возраст: одиночный долгий инцидент сразу
        # получает escalate, а не «первую отправку».
        fp_new=1
        first_epoch=$((now - incident_age_sec))
        if [ "$incident_age_sec" -ge "$NOTIFY_REPEAT_ESCALATE_AFTER_SEC" ]; then
            decision="escalate"
        else
            decision="send"
        fi
    elif [ $((now - first_epoch)) -ge "$NOTIFY_REPEAT_ESCALATE_AFTER_SEC" ]; then
        # Затяжной отказ: дальше источник работает через notify_escalation_update,
        # state НЕ переписываем — после восстановления и reset окно чистое.
        decision="escalate"
    else
        local step
        step=$(_notify_repeat_step $((last_sent - first_epoch)))
        if [ $((now - last_sent)) -ge "$step" ]; then
            decision="send"
            suffix_age=$(( (now - last_sent) / 3600 ))
        else
            decision="suppress"
        fi
    fi

    if [ "$decision" = "send" ] || { [ "$decision" = "escalate" ] && [ "$fp_new" = 1 ]; }; then
        # State пишем и при первом escalate: иначе каждый следующий вызов
        # снова выглядел бы «первым событием» и источник эскалировал бы
        # каждый тик подряд, минуя каденцию notify_escalation_update.
        # fp_new=1, а не «нет файла»: файл со старым fingerprint тоже надо
        # перезаписать, иначе смена fingerprint при escalate не липнет
        # (холодное ревью Codex, 26.10, итерация 3).
        local tmp_file
        tmp_file=$(mktemp "$dir/.notify-repeat.XXXXXX") && {
            printf '%s %s %s\n' "$fingerprint" "$now" "$first_epoch" > "$tmp_file"
            mv -f "$tmp_file" "$state_file"
        }
    fi
    if [ "$decision" = "send" ]; then
        echo "send"
        echo "(без изменений $suffix_age ч)"
    else
        echo "$decision"
    fi
    exec 9>&-
}

notify_repeat_reset() {
    local state_file
    state_file=$(_notify_repeat_state_file "$1")
    rm -f "$state_file"
}
