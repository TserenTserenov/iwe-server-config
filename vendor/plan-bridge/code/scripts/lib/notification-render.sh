#!/bin/bash
# notification-render.sh — перевод машинного статуса публикации в человекочитаемую
# фразу для Telegram-уведомлений (WP-538) + маршрутизация по каналу доставки.
#
# Разговорный стиль (DP.SC.050) обычно применяется LLM-агентом на генерации
# ответа; у скриптов публикации (ds-publish.sh, ledger-publish.sh) LLM в цепочке
# нет — этот файл переносит те же правила (без служебных меток, без жаргона,
# короткая фраза) в bash, для конечного набора канонических статусов.
# Техническая деталь (exit code, путь, git-вывод) остаётся в stderr/audit-логе
# у вызывающего скрипта — сюда не передаётся и в Telegram не уходит.
#
# Использование: . "$SCRIPT_DIR/lib/notification-render.sh" && notify_translate <status> <label>
# status: ok | fail | conflict | manual_action_required | retry — конечный
#   алфавит; неизвестный статус не считается ошибкой вызова, попадает в
#   fallback-ветку ниже.
# label: короткое человеческое название процесса ("публикация журнала событий").
#
# Архитектура выбрана в пир-сессии с Codex (консенсус, 3 хода, без эскалаций):
# sessions/2026-08/17/2026-08-17-07-wp538-notification-architecture/report.md
#
# notify_channel <status> [--retries-exhausted] [--force-notify]: вычисляет
# КУДА должен идти этот исход — не сам текст. Найдено 20.08 (пир-сессия с
# Codex, sessions/2026-08/20/2026-08-20-27-wp538-notif-volume-reduce/): текст
# fail/conflict уже признаёт «действие не нужно прямо сейчас», но канал был
# жёстко зашит на realtime независимо от текста — прямое противоречие. Канал
# смотрит не на имя статуса, а на то, нужна ли реакция пилота СЕЙЧАС:
#   realtime  — manual_action_required (всегда); ok при --force-notify (явный
#               opt-in вызывающего кода, не дефолт); fail/conflict при
#               --retries-exhausted (автоматика уже сдалась, есть риск
#               устаревания/SLA — это и есть «настоящий сбой», не рутина)
#   digest    — fail/conflict без --retries-exhausted (первая попытка, план
#               восстановления ещё есть, копия/повтор сохранены)
#   log-only  — ok (дефолт, было --quiet-ok opt-in — теперь обратный порядок),
#               retry (сам текст говорит «действие не нужно»)
# Контракт консенсуса (пир-сессия 20.08, зафиксирован для миграции внешних
# источников в WP-545): реалтайм разрешён только для (а) manual_action_required,
# (б) fail/conflict после исчерпания автоматических попыток восстановления с
# риском для SLA/актуальности, (в) ok — ТОЛЬКО при явном --force-notify.
# Всё остальное — log-only или digest.
notify_channel() {
    local status="$1"; shift
    local retries_exhausted=false force_notify=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --retries-exhausted) retries_exhausted=true; shift ;;
            --force-notify) force_notify=true; shift ;;
            *) shift ;;
        esac
    done

    case "$status" in
        manual_action_required)
            echo "realtime" ;;
        ok)
            [ "$force_notify" = true ] && echo "realtime" || echo "log-only" ;;
        fail|conflict)
            [ "$retries_exhausted" = true ] && echo "realtime" || echo "digest" ;;
        retry)
            echo "log-only" ;;
        *)
            # Неизвестный статус — тот же принцип, что unsupported-history
            # (fail() в ds-publish.sh): непредвиденное лучше показать сразу,
            # не прятать в дайджест, где заметят только на day-close.
            echo "realtime" ;;
    esac
}

notify_translate() {
    local status="$1"
    local label="${2:-Публикация}"
    shift 2 2>/dev/null || shift $#
    local repeat=false conflict_file="" behind="" duration=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repeat) repeat=true; shift ;;
            --conflict-file) conflict_file="${2:-}"; shift 2 ;;
            --behind) behind="${2:-}"; shift 2 ;;
            --duration) duration="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    # --repeat: тот же сбой уже подавлялся дедупом раньше (WP-538, 24.08) —
    # «действие не нужно» неверно для длящейся проблемы, меняем формулировку.
    case "$status" in
        ok)
            echo "✅ $label: прошло успешно."
            ;;
        recovered)
            echo "✅ $label: снова заработало после сбоя."
            ;;
        fail)
            if [ "$repeat" = true ]; then
                local dur_clause="Само не восстановится"
                [ -n "$duration" ] && dur_clause="Не решается уже $duration — само не восстановится"
                echo "🚨 $label: снова не получилось (повторяется). $dur_clause — если увидишь это ещё раз, загляни в лог или напиши мне."
            else
                echo "🚨 $label: не получилось, попытки закончились. Действие не нужно прямо сейчас — данные не потеряны, повторю на следующем плановом запуске."
            fi
            ;;
        conflict)
            # conflict_file задан только вызывающими, которые знают КОНКРЕТНЫЙ
            # не сошедшийся объект (сейчас — drain в ledger-publish.sh, append-only
            # конфликт журнала, не git). Без него — исходный текст ds-publish.sh
            # про git cherry-pick конфликт, не трогаем: там "копии сохранены"
            # правда (isolate-push.sh реально сохраняет временный worktree).
            # WP-538, 25.08, пир-сессия с Codex: та же фраза для drain была
            # неточной — при append-only конфликте ничего не копируется, файл
            # просто не перезаписывается.
            if [ -n "$conflict_file" ]; then
                local hint=""
                [ -n "$behind" ] && [ "$behind" != "0" ] \
                    && hint=" Возможная причина: исходный репозиторий отстаёт от сервера на $behind коммит(ов)."
                if [ "$repeat" = true ]; then
                    local dur_clause="Само не решится"
                    [ -n "$duration" ] && dur_clause="Не решается уже $duration — само не решится"
                    echo "⚠️ $label: снова не сошёлся файл $conflict_file (повторяется).$hint $dur_clause — сам замечу и разберусь, когда в следующий раз буду работать с этим репозиторием; если срочно, напиши мне раньше."
                else
                    echo "⚠️ $label: не сошёлся файл $conflict_file — публикация его не перезаписала.$hint Действие не нужно прямо сейчас — сам замечу и разберусь, когда в следующий раз буду работать с этим репозиторием."
                fi
            elif [ "$repeat" = true ]; then
                echo "⚠️ $label: снова не смог сам объединить изменения (повторяется). Копии сохранены, но конфликт сам не разрешится — сам замечу и разберусь, когда в следующий раз буду работать с этим репозиторием; если срочно, напиши мне раньше."
            else
                echo "⚠️ $label: не смог сам объединить изменения — конфликт. Действие не нужно прямо сейчас — сохранил копию для разбора, сам замечу и разберусь, когда в следующий раз буду работать с этим репозиторием."
            fi
            ;;
        manual_action_required)
            echo "🆘 $label: сам продолжить не могу — нужно твоё решение. Напиши мне в чат, когда будет время посмотреть."
            ;;
        retry)
            echo "🔁 $label: с первого раза не вышло, пробую ещё раз. Действие не нужно."
            ;;
        # WP-568 Ф10: the phase is known (ds-publish PUBLISH_PHASE), so say
        # plainly whether the changes reached the server.
        unexpected_after_publish)
            echo "ℹ️ $label: изменения на сервер дошли. После этого упал служебный шаг самой публикации, опубликованное он не задевает. Действие не нужно, упавшая команда записана в журнал публикаций."
            ;;
        unexpected_after_push_fail)
            echo "⚠️ $label: изменения на сервер не дошли, отправка отказала, и следом упал разбор этого отказа. Изменения лежат в локальной копии и уйдут со следующей публикацией."
            ;;
        unexpected_before_publish)
            echo "⚠️ $label: изменения на сервер не отправлялись, сбой случился раньше отправки. Они лежат в локальной копии и уйдут со следующей публикацией."
            ;;
        *)
            echo "🚨 $label: упал непредусмотренный шаг, на каком этапе публикации, неизвестно. Упавшая команда записана в журнал публикаций, агент разберёт её при следующей работе с этим репозиторием."
            ;;
    esac
}

# notify_digest_append <status> <label> [detail]: пишет одну JSON-строку в
# сегодняшний дайджест-файл вместо отправки в Telegram. day-close-mechanical.sh
# читает и суммирует этот файл одним сообщением (только если он непустой) —
# консенсус 20.08: «одна сводка в day-close, только при ненулевой активности»,
# не фиксированный интервал (интервальные сообщения сами создают шум-паттерн,
# был инцидент 18.08 с уведомлениями подряд).
# notify_digest_append_checked: notify_digest_append, but exit 1 when the
# record was not written (callers that must not lose a text silently).
notify_digest_append_checked() {
    local digest_file="${DS_PUBLISH_DIGEST_DIR:-$HOME/IWE/.claude/state/notify-digest}/$(date -u +%Y-%m-%d).jsonl"
    local before=0 after=0
    [ -f "$digest_file" ] && before=$(wc -l < "$digest_file")
    notify_digest_append "$@"
    [ -f "$digest_file" ] && after=$(wc -l < "$digest_file")
    [ "$after" -gt "$before" ]
}

notify_digest_append() {
    local status="$1" label="$2" detail="${3:-}" run_id="${4:-}"
    local digest_dir="${DS_PUBLISH_DIGEST_DIR:-$HOME/IWE/.claude/state/notify-digest}"
    local digest_file
    digest_file="$digest_dir/$(date -u +%Y-%m-%d).jsonl"
    mkdir -p "$digest_dir" 2>/dev/null || return 0
    # run_id (WP-538 Ф7, 11.09, peer-session with Kimi+Codex): the run
    # correlation id travels as its OWN field, never folded into detail text
    # and never truncated — the 8-char "#rid:" tail in the human label stays
    # a readability aid, this field is the one an agent greps for.
    python3 -c '
import json, sys
ts, status, label, detail, run_id = sys.argv[1:]
row = {"ts": ts, "status": status, "label": label, "detail": detail}
if run_id:
    row["run_id"] = run_id
print(json.dumps(row))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$label" "$detail" "$run_id" >> "$digest_file" 2>/dev/null \
        || true
}

# notify_repo_id <path>: короткий стабильный идентификатор репозитория для
# составных dedup-ключей (WP-538, 25.08, пир-сессия с Codex) — не basename
# (разные пути с одинаковым именем папки схлопнутся в один ключ), не сырой
# путь (слэши небезопасны в имени файла и как glob-паттерн). Хеш канонического
# абсолютного пути гарантирует уникальность; basename в префиксе — только для
# читаемости при ручном просмотре state-директории, уникальность даёт хеш.
notify_repo_id() {
    local path="$1"
    local real
    real="$(cd -- "$path" 2>/dev/null && pwd -P)" || real="$path"
    local hash
    if command -v sha256sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$real" | sha256sum | cut -c1-10)"
    else
        hash="$(printf '%s' "$real" | shasum -a 256 | cut -c1-10)"
    fi
    # basename только для читаемости (см. выше), но попадает в имя state-файла
    # и в glob-паттерн notify_dedup_clear_prefix -- санитизация той же нормой,
    # что safe_file в fail() (ledger-publish.sh), на случай каталога с
    # пробелом/glob-метасимволом в имени (cold-context review, 25.08).
    local safe_base
    safe_base="$(basename -- "$real" | tr -c 'a-zA-Z0-9._-' '-')"
    printf '%s-%s' "$safe_base" "$hash"
}

# notify_format_duration <seconds>: секунды с начала инцидента → "Nч Mм" —
# для текста повторного алерта (WP-538, 25.08): "не решается уже 2ч 15м"
# вместо голого "повторяется" без числа.
notify_format_duration() {
    local secs="${1:-0}"
    [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then
        printf '%dч %dм' "$h" "$m"
    else
        printf '%dм' "$m"
    fi
}

# notify_dedup_key <reason>: сворачивает переменный --reason ("ledger: 3
# файл(ов) #rid:a1b2c3d4", "day-close: 2026-08-21") в стабильный тег одного
# и того же ПРОИЗВОДИТЕЛЯ ("ledger", "day-close") — счётчики файлов и id
# запуска в reason меняются на каждый вызов, поэтому дедуп по всему тексту
# reason никогда бы не сработал (WP-538, всплеск 20-21.08: одна и та же
# зависшая публикация слала разный reason на каждый повтор планового
# таймера). Режется РОВНО по первому ":" (не по первому пробелу/скобке —
# нашёл cold-context review: "week-open day section: $DATE" и
# "week-open: $WEEK → $NEXT_WEEK" — два РАЗНЫХ, не связанных вызывающих
# скрипта — резались по первому пробелу в одинаковый тег "week-open",
# чужой сбой глушил чужой дедуп-подавлением. Все реальные вызывающие
# (`grep -rn -- '--reason "' scripts/*.sh`) следуют формату
# "стабильный-префикс: переменная-деталь" — резать по ":" безопасно для
# каждого из них и не требует знания их списка здесь.
notify_dedup_key() {
    local reason="${1:-}"
    local tag="${reason%%:*}"
    tag="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    # sed, не ${tag##-}/${tag%%-} -- та пара снимает РОВНО один ведущий/
    # хвостовой дефис (glob-паттерн "-" не повторяется автоматически), не
    # весь пробег из нескольких (found cold-context review: "неделя: ..."
    # после tr давал "----------", ## снимал только первый).
    tag="$(printf '%s' "$tag" | sed 's/^-*//; s/-*$//')"
    # Известное ограничение: нелатинский префикс (например "журнал: ...")
    # целиком выпадает в "-"-ы -> схлопывается в "default" вместе с ЛЮБЫМ
    # другим нелатинским производителем -- сейчас безопасно (все реальные
    # --reason из scripts/*.sh латинские, проверено grep'ом), но не
    # универсально. Не решается здесь -- нужен явный --dedup-key от
    # вызывающего, если появится нелатинский производитель.
    [ -n "$tag" ] || tag="default"
    printf '%s' "$tag"
}

# notify_dedup_key_full <reason>: та же санитизация, что notify_dedup_key, но
# НЕ режет по первому ":" -- оставляет весь reason. Нужна там, где дедуп по
# ПРОИЗВОДИТЕЛЮ (как у fail/conflict выше) был бы дефектом, а не удобством:
# manual_action_required (WP-538, 09.10, найдено cold-context review) намеренно
# исключён из глобального гейта именно потому, что пилоту нужно решение
# СЕЙЧАС, откладывать нельзя. Общий тег-по-производителю схлопнул бы ДВА
# РАЗНЫХ срочных решения одного источника (например, два разных конфликта
# `isolate-push.sh` с разным --reason) в "один и тот же", если оба попали в
# общее TTL-окно -- тихо отложив настоящее новое решение в дневной digest.
# Полный текст reason как ключ: тот же самый повтор (буквальный дубль одного
# инцидента) всё ещё даёт тот же ключ и дедупится; разные reason — разные
# ключи, не дедупятся. Урезано до 80 символов -- стабильный безопасный для
# имени файла ключ, не предназначен для чтения человеком. То же известное
# ограничение, что у notify_dedup_key выше: нелатинский reason целиком
# схлопывается в "-"-ы -- при пустом/нелатинском --reason риск того же
# ложного совпадения остаётся, просто на более узком случае.
notify_dedup_key_full() {
    local reason="${1:-}"
    local tag
    tag="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    tag="$(printf '%s' "$tag" | sed 's/^-*//; s/-*$//')"
    tag="${tag:0:80}"
    [ -n "$tag" ] || tag="default"
    printf '%s' "$tag"
}

# notify_dedup_allow <status> <key>: TTL-подавление ПОВТОРОВ одного и того же
# realtime-сбоя между ОТДЕЛЬНЫМИ запусками ds-publish.sh (не одного процесса —
# каждый плановый таймер запускает новый процесс). Тот же принцип, что уже
# реализован и ждёт переноса в git-dirty-guard.sh (сессия 6, WP-538):
# первый алерт — сразу, дальше тишина TTL минут, потом ОДНО повторное
# напоминание (не молчать навсегда). Возвращает 0 (слать) или 1 (подавить).
# Не может персистировать (нет прав на state-dir) — fail open: 0, лучше
# лишний раз сообщить пилоту, чем потерять реальный сбой.
# flock вокруг чтения-проверки-записи (не просто mkdir -p) — cold-context
# review нашёл: два процесса, столкнувшихся в одно и то же TTL-окно без
# лока, оба читают "не подавлено" и оба пишут state -- реальный второй сбой
# может проиграть гонку и не отправиться (ровно тот класс дубля/потери,
# ради которого это всё пишется). Отдельный lock-файл на ключ, не общий
# на весь dedup_dir -- разные ключи не должны сериализоваться друг за
# другом.
notify_dedup_allow() {
    local status="$1" key="$2"
    local dedup_dir="${DS_PUBLISH_DEDUP_DIR:-$HOME/IWE/.claude/state/notify-dedup}"
    local ttl_min="${NOTIFY_DEDUP_TTL_MIN:-60}"
    local state_file="$dedup_dir/${status}-${key}.state"
    local lock_file="$dedup_dir/${status}-${key}.lock"
    # Was there already a state file for this key before this call? Read by
    # the caller (ds-publish.sh, ledger-publish.sh) to pick a --repeat text
    # via notify_translate — an alert past its TTL is a repeat of an ongoing
    # failure, not a fresh one, and the message should say so (WP-538, 24.08).
    NOTIFY_DEDUP_WAS_REPEAT=false
    NOTIFY_DEDUP_FIRST_SEEN=""
    [ -f "$state_file" ] && NOTIFY_DEDUP_WAS_REPEAT=true
    # Диагностика в stderr при недоступности dedup_dir (cold-context review):
    # fail-open молча возвращает "слать" -- без этой строки дедуп мог бы
    # незаметно перестать работать в проде (например, state-dir стал
    # read-only) и повторился бы ровно тот флуд, который эта сессия чинит,
    # без единого сигнала о том, что причина именно тут.
    mkdir -p "$dedup_dir" 2>/dev/null \
        || { echo "WARN: notify_dedup_allow: не удалось создать $dedup_dir — дедуп отключён, шлю без подавления" >&2; return 0; }

    # Fixed FD (8), not `exec {VAR}>...`: ledger-publish.sh/ds-publish.sh both
    # resolve to whatever `bash` the caller's shebang picks -- macOS still
    # ships bash 3.2 by default, and the pilot running `--probe` there hits
    # bash 3.2 directly. The dynamic-fd form is bash 4.1+ only; on 3.2 it's a
    # parse-time abort of the whole script, not a soft failure `||` can catch
    # (bug-2026-08-25-notification-dedup-crashes-on-bash-3.2.md). FD 9 is
    # already each caller's own top-level process lock (`exec 9>"$LOCK_FILE"`)
    # -- 8 stays free for this narrower per-key dedup lock.
    exec 8>"$lock_file" 2>/dev/null || return 0
    flock 8 2>/dev/null || { exec 8>&-; return 0; }

    local allow=0
    local first_seen="" last_sent=0 now
    now=$(date -u +%s)
    if [ -f "$state_file" ]; then
        local raw
        raw="$(cat "$state_file" 2>/dev/null)"
        # WP-538, 25.08: state-файл теперь хранит "first_seen:last_sent" —
        # старый формат (голое число, до этой правки) читаем как оба поля.
        if [[ "$raw" == *:* ]]; then
            first_seen="${raw%%:*}"
            last_sent="${raw#*:}"
        else
            first_seen="$raw"
            last_sent="$raw"
        fi
        [[ "$first_seen" =~ ^[0-9]+$ ]] || first_seen="$now"
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        [ $(( (now - last_sent) / 60 )) -lt "$ttl_min" ] && allow=1
    fi
    if [ "$allow" -eq 0 ]; then
        [ -n "$first_seen" ] || first_seen="$now"
        printf '%s:%s' "$first_seen" "$now" > "$state_file" 2>/dev/null
    fi
    NOTIFY_DEDUP_FIRST_SEEN="$first_seen"

    exec 8>&-
    return "$allow"
}

# notify_dedup_clear <key>: вызывается на status=ok — снимает подавление,
# оставшееся от предыдущих fail/conflict с тем же ключом, чтобы СЛЕДУЮЩИЙ
# реальный сбой алертил сразу, а не ждал остаток чужого TTL-окна. Возвращает
# 0, если реально было что снимать (был хотя бы один подавленный alert) —
# вызывающий код использует это, чтобы решить, стоит ли слать "recovered".
notify_dedup_clear() {
    local key="$1"
    local dedup_dir="${DS_PUBLISH_DEDUP_DIR:-$HOME/IWE/.claude/state/notify-dedup}"
    local had_state=1
    local f
    for f in "$dedup_dir/fail-$key.state" "$dedup_dir/conflict-$key.state"; do
        [ -f "$f" ] && { rm -f "$f" 2>/dev/null; had_state=0; }
    done
    return "$had_state"
}

# notify_dedup_clear_any <key> [key...]: notify_dedup_clear over several
# keys at once (a caller with multiple failure stages, e.g. ledger-publish.sh
# bootstrap/checkout/fetch/drain, clears them all on one successful run) —
# returns 0 if ANY key had pending state, so the caller sends one combined
# "recovered" instead of one per stage.
notify_dedup_clear_any() {
    local had_any=1 key
    for key in "$@"; do
        notify_dedup_clear "$key" && had_any=0
    done
    return "$had_any"
}

# notify_escalation_update <key> <fail|ok> [--repeat-after-min N]: stateful
# incident tracker for a source with NO other dedup/digest routing of its own
# (WP-538 Ф7, 08.09, пир-сессия с Kimi+Codex — sync-extensions-auto.sh шлёт
# сырой curl на каждый двухчасовой тик без какого-либо подавления). Отвечает
# на другой вопрос, чем notify_dedup_allow: тот подавляет ПОВТОР одного и того
# же текста по TTL, этот отслеживает ЖИЗНЕННЫЙ ЦИКЛ инцидента (первый раз /
# продолжается / восстановился), поэтому — отдельный state, не общий
# notify-dedup (не заводить вторую конкурирующую state machine поверх той же
# записи).
#
# Контракт: устанавливает NOTIFY_ESCALATION_PHASE=first|ongoing|recovered|
# suppressed, NOTIFY_ESCALATION_COUNT, NOTIFY_ESCALATION_FIRST_SEEN (epoch),
# NOTIFY_ESCALATION_DURATION_SEC. Возвращает 0 — вызывающему стоит слать
# сообщение сейчас; 1 — подавить (или "ok" без предшествующего инцидента,
# восстанавливать нечего). "ok" удаляет state только после того, как он
# использован для NOTIFY_ESCALATION_* — вызывающий код может собрать текст
# восстановления ДО следующего вызова этой функции.
notify_escalation_update() {
    local key="$1" event="$2" repeat_after_min="${NOTIFY_ESCALATION_REPEAT_MIN:-360}"
    # --urgent-after-sec/--urgent-repeat-after-min (WP-484, 14.09, пир-сессия
    # с Kimi+Codex): repeat_after_min throttles FREQUENCY, but a chronic
    # incident (sync-extensions-auto.sh stuck 3 days) stayed invisible behind
    # it — every retry was correctly suppressed, so nobody ever saw a message
    # saying the pipeline had been down for days. Both flags optional and
    # unset by default: a caller that doesn't pass them gets byte-identical
    # behaviour to before this change (no third state field is ever consulted).
    local urgent_after_sec="" urgent_repeat_after_min=""
    while [ "$#" -gt 2 ]; do
        case "$3" in
            --repeat-after-min) repeat_after_min="$4"; shift 2 ;;
            --urgent-after-sec) urgent_after_sec="$4"; shift 2 ;;
            --urgent-repeat-after-min) urgent_repeat_after_min="$4"; shift 2 ;;
            *) shift ;;
        esac
    done
    # Defensive validation, not just at the call site: this is a shared
    # library function, and a bad value here must never silently disable
    # escalation (an empty/zero/negative threshold would make every fail
    # "urgent" instantly, a bogus huge one would never fire).
    if [ -n "$urgent_after_sec" ]; then
        if ! [[ "$urgent_after_sec" =~ ^[0-9]+$ ]] || [ "$urgent_after_sec" -lt 1 ] || [ "$urgent_after_sec" -gt 604800 ]; then
            echo "WARN: notify_escalation_update: --urgent-after-sec вне диапазона (1-604800): '$urgent_after_sec' — urgent-эскалация отключена для этого вызова" >&2
            urgent_after_sec=""
        fi
    fi
    if [ -n "$urgent_repeat_after_min" ]; then
        if ! [[ "$urgent_repeat_after_min" =~ ^[0-9]+$ ]] || [ "$urgent_repeat_after_min" -lt 1 ]; then
            echo "WARN: notify_escalation_update: --urgent-repeat-after-min некорректен: '$urgent_repeat_after_min' — использую repeat-after-min ($repeat_after_min)" >&2
            urgent_repeat_after_min=""
        fi
    fi
    [ -n "$urgent_after_sec" ] && [ -z "$urgent_repeat_after_min" ] && urgent_repeat_after_min="$repeat_after_min"
    local dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}/incidents"
    local safe_key
    safe_key="$(printf '%s' "$key" | tr -c 'a-zA-Z0-9._-' '-')"
    local state_file="$dir/$safe_key.state"
    local lock_file="$dir/$safe_key.lock"
    NOTIFY_ESCALATION_PHASE="suppressed"
    NOTIFY_ESCALATION_COUNT=0
    NOTIFY_ESCALATION_FIRST_SEEN=""
    NOTIFY_ESCALATION_DURATION_SEC=0
    mkdir -p "$dir" 2>/dev/null \
        || { echo "WARN: notify_escalation_update: не удалось создать $dir — эскалация отключена, шлю без подавления" >&2; NOTIFY_ESCALATION_PHASE="first"; return 0; }

    # Собственный FD (6), отдельный от notify_dedup_allow (8) и
    # notify_admission_allow/flush (7) — та же причина, что развела их между
    # собой: разные ключи не должны сериализоваться друг за другом, а вложенный
    # вызов из другой функции этой же библиотеки не должен унаследовать чужую
    # занятую FD.
    exec 6>"$lock_file" 2>/dev/null || { NOTIFY_ESCALATION_PHASE="first"; return 0; }
    flock 6 2>/dev/null || { exec 6>&-; NOTIFY_ESCALATION_PHASE="first"; return 0; }

    local now first_seen="" last_sent=0 count=0 last_urgent=0
    now=$(date -u +%s)
    if [ -f "$state_file" ]; then
        local raw
        raw="$(cat "$state_file" 2>/dev/null)"
        first_seen="$(printf '%s' "$raw" | cut -d: -f1)"
        last_sent="$(printf '%s' "$raw" | cut -d: -f2)"
        count="$(printf '%s' "$raw" | cut -d: -f3)"
        last_urgent="$(printf '%s' "$raw" | cut -d: -f4)"  # WP-484: 4th field, absent (empty) on state written before this change
        [[ "$first_seen" =~ ^[0-9]+$ ]] || first_seen=""
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        [[ "$last_urgent" =~ ^[0-9]+$ ]] || last_urgent=0
    fi

    local rc=1
    if [ "$event" = "ok" ]; then
        if [ -n "$first_seen" ]; then
            NOTIFY_ESCALATION_PHASE="recovered"
            NOTIFY_ESCALATION_COUNT="$count"
            NOTIFY_ESCALATION_FIRST_SEEN="$first_seen"
            NOTIFY_ESCALATION_DURATION_SEC=$(( now - first_seen ))
            rm -f "$state_file" 2>/dev/null
            rc=0
        else
            NOTIFY_ESCALATION_PHASE="suppressed"
            rc=1
        fi
    else
        count=$(( count + 1 ))
        if [ -z "$first_seen" ]; then
            first_seen="$now"
            printf '%s:%s:%s:%s' "$first_seen" "$now" "$count" "$last_urgent" > "$state_file" 2>/dev/null
            NOTIFY_ESCALATION_PHASE="first"
            rc=0
        elif [ -n "$urgent_after_sec" ] && [ $(( now - first_seen )) -ge "$urgent_after_sec" ] \
             && { [ "$last_urgent" -eq 0 ] || [ $(( (now - last_urgent) / 60 )) -ge "$urgent_repeat_after_min" ]; }; then
            # Chronic incident past the hard duration threshold: bypass the
            # frequency throttle once, on its own cadence — otherwise the
            # very suppression that stops spam is what hid a 3-day outage.
            last_urgent="$now"
            printf '%s:%s:%s:%s' "$first_seen" "$now" "$count" "$last_urgent" > "$state_file" 2>/dev/null
            NOTIFY_ESCALATION_PHASE="urgent"
            rc=0
        elif [ $(( (now - last_sent) / 60 )) -ge "$repeat_after_min" ]; then
            printf '%s:%s:%s:%s' "$first_seen" "$now" "$count" "$last_urgent" > "$state_file" 2>/dev/null
            NOTIFY_ESCALATION_PHASE="ongoing"
            rc=0
        else
            printf '%s:%s:%s:%s' "$first_seen" "$last_sent" "$count" "$last_urgent" > "$state_file" 2>/dev/null
            NOTIFY_ESCALATION_PHASE="suppressed"
            rc=1
        fi
        NOTIFY_ESCALATION_COUNT="$count"
        NOTIFY_ESCALATION_FIRST_SEEN="$first_seen"
        NOTIFY_ESCALATION_DURATION_SEC=$(( now - first_seen ))
    fi

    exec 6>&-
    return "$rc"
}

# notify_admission_allow <label> <text> [incident_key] [run_id]: глобальный
# лимит realtime-сообщений НА ВЕСЬ БОТ (не на источник) — WP-538, 01.09.2026,
# пир-сессия с Codex (сессия 18). Проблема, которую per-source дедуп не
# решает: несколько независимых источников (git-dirty-guard по разным
# репозиториям, ds-publish/ledger-publish) могут КАЖДЫЙ по отдельности решить
# "это мой первый алерт, шлю сейчас" в одно и то же окно, если несколько
# репозиториев сломались одновременно — живой случай 01.09 (5 репо dirty
# разом, поток из 14 сообщений за час). То, что не прошло — не пропадает, а
# копится в очередь и уходит ОДНИМ склеенным сообщением при следующей
# разрешённой отправке (anti-starvation оговорка Codex: одиночная
# подавленная проблема без второго триггера всё равно не пропадёт молча —
# см. notify_route(), который параллельно всегда пишет то же самое в
# дневной digest как страховку, даже если разрешение так и не наступит).
#
# WP-538 Ф7 (11.09, пир-сессия Kimi+Codex, консенсус за 2 раунда): окно
# различает КЛАСС ИНЦИДЕНТА, а не только время. До этой фазы единственным
# состоянием была голая эпоха last-sent.state — "тот же сбой повторился" и
# "сломалось что-то принципиально новое" были неразличимы, второе ждало в
# очереди за первым до 15 минут. Инварианты (формулировка Codex, раунд 1):
#   - окно = ФИКСИРОВАННАЯ ГЕНЕРАЦИЯ, начатая первой обычной realtime-
#     отправкой; прорывы новых классов границу НЕ сдвигают;
#   - новый (не виденный в этой генерации) incident_key проходит realtime
#     сразу, но не более NOTIFY_ADMISSION_NEW_KEYS_MAX (дефолт 3) раз за
#     генерацию — вариативный ключ не может вернуть шторм;
#   - повтор уже виденного ключа — всегда в очередь;
#   - seen-keys.state, breakthroughs.state и last-sent.state читаются и
#     меняются только под fd 7 (одна критическая секция с append в очередь);
#   - вызывающий без ключа получает legacy:<source-id>
#     (notify_legacy_incident_key), не ключ из текста — старые producer'ы
#     не ломаются и не становятся "всегда новыми";
#   - run_id — отдельное поле записи очереди, в ключ НЕ входит (иначе три
#     параллельных запуска = три "новых" инцидента = обход ограничителя).
# Канонический ключ строит notify_incident_key() ниже — из контролируемого
# словаря, без даты/репо/PID/SHA/label.
# Возвращает 0 (можно слать сейчас) или 1 (поставлено в очередь, вызывающий
# обязан НЕ звать tg_notify напрямую).
NOTIFY_INCIDENT_STATUSES=" ok recovered fail conflict manual_action_required retry unexpected unexpected_after_publish unexpected_after_push_fail unexpected_before_publish "
NOTIFY_INCIDENT_STAGES=" publish drain conflict retry - "

# notify_incident_key <status> <source-id> [stage]: канонический ключ класса
# инцидента "<status>:<source-id>:<stage>". status — алфавит notify_translate
# + "unexpected" (ERR-трапы), иначе схлопывается в "unexpected"; stage — из
# NOTIFY_INCIDENT_STAGES (расширение — только правкой словаря здесь), иначе
# "-" с предупреждением; source-id — ID строки allowlist (поле 3), не
# basename и не человеческая метка: неизвестный ID тоже предупреждает, но
# ключ всё равно строится (fail-open на ключе безопаснее, чем сломать
# отправку). Тест на инвариантность: scripts/tests/notify-admission-
# incident-key-smoke.sh.
notify_incident_key() {
    local status="${1:-unexpected}" source="${2:-}" stage="${3:--}"
    case "$NOTIFY_INCIDENT_STATUSES" in
        *" $status "*) ;;
        *) status="unexpected" ;;
    esac
    case "$NOTIFY_INCIDENT_STAGES" in
        *" $stage "*) ;;
        *) echo "WARN: notify_incident_key: этап '$stage' не в словаре ($NOTIFY_INCIDENT_STAGES) — беру '-'" >&2; stage="-" ;;
    esac
    source="$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//')"
    [ -n "$source" ] || source="unknown"
    if ! telegram_allowlist_line_by_source "$source" >/dev/null; then
        echo "WARN: notify_incident_key: source-id '$source' нет в telegram-transport-allowlist.conf (поле 3) — ключ построен, но источник не зарегистрирован" >&2
    fi
    printf '%s:%s:%s' "$status" "$source" "$stage"
}

# notify_legacy_incident_key: ключ для вызывающих, которые ещё не передают
# --key (переходный режим Ф7) — legacy:<source-id>, где source-id разрешается
# из allowlist по basename вызывающего скрипта (или TELEGRAM_SOURCE_ID, если
# задан). Один ключ на источник, а не один общий legacy на всех — иначе два
# разных старых источника считались бы одним классом (Kimi, раунд 2).
notify_legacy_incident_key() {
    printf 'legacy:%s' "$(telegram_caller_source_id)"
}

# _notify_admission_new_generation <key>: начинает новую генерацию окна —
# last-sent.state = сейчас, seen-keys.state = только этот ключ,
# breakthroughs.state = 0. Не берёт лок сама — оба вызывающих
# (notify_admission_allow в критической секции ниже, notify_admission_mark_sent)
# обязаны держать flock 7 перед вызовом. Один источник правды на формат/путь
# state-файлов (WP-538 Ф8, 08.09, пир-сессия с Kimi).
_notify_admission_new_generation() {
    local key="${1:-}"
    local dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s' "$(date -u +%s)" > "$dir/last-sent.state" 2>/dev/null
    if [ -n "$key" ]; then
        printf '%s\n' "$key" > "$dir/seen-keys.state" 2>/dev/null
    else
        : > "$dir/seen-keys.state" 2>/dev/null
    fi
    printf '0' > "$dir/breakthroughs.state" 2>/dev/null
}

# notify_admission_mark_sent: помечает окно "занято сейчас" БЕЗ прохождения
# через allow/queue-решение — для источников, которые обязаны уйти в Telegram
# немедленно (manual_action_required, WP-538 сессия 18) независимо от гейта,
# но чьё сообщение всё равно должно занимать окно для ВСЕХ ОСТАЛЬНЫХ realtime-
# источников (иначе следующий realtime-триггер проходит бесплатно сразу после
# manual_action_required — найдено 08.09, пир-сессия с Kimi: это один из
# каналов, порождавших 3 Telegram-сообщения подряд на один сбой публикации).
# Самостоятельный лок (свой вход/выход из критической секции) — вызывается
# ВНЕ контекста notify_admission_allow, не может полагаться на то, что fd 7
# уже открыта. Начинает новую генерацию без ключа: manual_action_required
# не участвует в классификации, но обнуляет квоту прорывов.
notify_admission_mark_sent() {
    local dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    local lock_file="$dir/admission.lock"
    mkdir -p "$dir" 2>/dev/null || return 1
    exec 7>"$lock_file" 2>/dev/null || return 1
    flock 7 2>/dev/null || { exec 7>&-; return 1; }
    _notify_admission_new_generation ""
    exec 7>&-
}

notify_admission_allow() {
    local label="$1" text="$2" key="${3:-}" run_id="${4:-}"
    local dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    local window_min="${NOTIFY_ADMISSION_WINDOW_MIN:-15}"
    local new_keys_max="${NOTIFY_ADMISSION_NEW_KEYS_MAX:-3}"
    local state_file="$dir/last-sent.state"
    local seen_file="$dir/seen-keys.state"
    local count_file="$dir/breakthroughs.state"
    local queue_file="$dir/pending.jsonl"
    local lock_file="$dir/admission.lock"
    mkdir -p "$dir" 2>/dev/null \
        || { echo "WARN: notify_admission_allow: не удалось создать $dir — гейт отключён, шлю без ограничения" >&2; return 0; }
    [[ "$new_keys_max" =~ ^[0-9]+$ ]] || new_keys_max=3
    [ -n "$key" ] || key="$(notify_legacy_incident_key)"

    # Тот же fixed-FD приём, что и в notify_dedup_allow (FD 8 там же занята
    # per-key логом — здесь отдельный лок-файл, поэтому та же цифра не
    # конфликтует, но берём соседнюю (7), чтобы не завязываться на то, что
    # вызывающий код не держит 8 открытой одновременно).
    exec 7>"$lock_file" 2>/dev/null || return 0
    flock 7 2>/dev/null || { exec 7>&-; return 0; }

    local now last_sent=0
    now=$(date -u +%s)
    if [ -f "$state_file" ]; then
        last_sent="$(cat "$state_file" 2>/dev/null)"
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
    fi

    # Естественное истечение генерации — обычная отправка открывает новую.
    if [ $(( (now - last_sent) / 60 )) -ge "$window_min" ]; then
        _notify_admission_new_generation "$key"
        exec 7>&-
        return 0
    fi

    # Внутри генерации: новый класс — прорыв в пределах квоты, граница
    # генерации (last-sent.state) не двигается.
    if ! grep -qxF -- "$key" "$seen_file" 2>/dev/null; then
        local breakthroughs
        breakthroughs="$(cat "$count_file" 2>/dev/null)"
        [[ "$breakthroughs" =~ ^[0-9]+$ ]] || breakthroughs=0
        if [ "$breakthroughs" -lt "$new_keys_max" ]; then
            printf '%s\n' "$key" >> "$seen_file" 2>/dev/null
            printf '%s' $(( breakthroughs + 1 )) > "$count_file" 2>/dev/null
            exec 7>&-
            return 0
        fi
    fi

    if ! python3 -c '
import json, sys
ts, label, text, key, run_id = sys.argv[1:]
row = {"ts": ts, "label": label, "text": text, "key": key}
if run_id:
    row["run_id"] = run_id
print(json.dumps(row))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$text" "$key" "$run_id" >> "$queue_file" 2>/dev/null; then
        echo "WARN: notify_admission_allow: не удалось сохранить сообщение в $queue_file" >&2
        exec 7>&-
        return 2
    fi
    exec 7>&-
    return 1
}

# notify_admission_flush: если за время подавления накопились сообщения —
# возвращает их одним готовым текстовым блоком (для склейки с текущим
# realtime-сообщением вызывающим кодом) и очищает очередь. Пусто (код
# возврата 0, вывод пустой) — подавленных сообщений не было, вызывающий
# шлёт как обычно, без склейки. Ф7: записи с одинаковым key схлопываются в
# одну строку со счётчиком "(повторилось ×N)" — пилот видит классы, не
# N одинаковых строк; записи старого формата (без key) остаются по одной.
notify_admission_flush() {
    local dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    local queue_file="$dir/pending.jsonl"
    local lock_file="$dir/admission.lock"
    [ -s "$queue_file" ] || return 0

    # Тот же лок-файл, что notify_admission_allow -- без общего лока append
    # (allow, под flock) и drain (flush, здесь) могли гоняться: flush читает
    # файл, а конкурентный allow дописывает в него СВОЮ строку между чтением
    # и rm -f ниже -- эта строка удаляется невидимой ни разу не попав в
    # склеенный текст (найдено cold-context review, 01.09 -- ровно тот
    # сценарий одновременных источников, ради которого этот механизм и
    # писался). Отдельная критическая секция от allow -- не общая с ней,
    # только гарантия, что ни один append не пересечётся ни с одним drain.
    exec 7>"$lock_file" 2>/dev/null || return 0
    flock 7 2>/dev/null || { exec 7>&-; return 0; }

    local out
    out="$(python3 -c '
import json, sys

def plural(n, one, few, many):
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not (12 <= n % 100 <= 14):
        return few
    return many

lines = [json.loads(l) for l in sys.stdin if l.strip()]
if not lines:
    sys.exit(0)
n = len(lines)
word = plural(n, "сообщение", "сообщения", "сообщений")
print(f"Пока молчал (общий лимит), накопилось ещё {n} {word}:")
groups = []          # [key, first_text, count] in first-seen order
index = {}
for i, l in enumerate(lines):
    key = l.get("key") or f"__nokey__{i}"
    if key in index:
        groups[index[key]][2] += 1
    else:
        index[key] = len(groups)
        groups.append([key, l["text"], 1])
for _, text, count in groups:
    suffix = f" (повторилось ×{count})" if count > 1 else ""
    print(f"— {text}{suffix}")
' < "$queue_file" 2>&1)"
    if [ $? -ne 0 ]; then
        # Не трогаем queue_file на сбое разбора (например, порванная строка
        # от очень редкого не-атомарного append) -- rm -f здесь стёр бы ВСЕ
        # накопленные сообщения без единого шанса на повтор (cold-context
        # review, 01.09): лучше повторить попытку на следующем flush, чем
        # молча потерять факты, которые этот механизм обязан сохранять.
        echo "WARN: notify_admission_flush: python3 упал на $queue_file — очередь оставлена как есть, попробую на следующем разрешённом сообщении: $out" >&2
        exec 7>&-
        return 1
    fi
    printf '%s' "$out"
    rm -f "$queue_file" 2>/dev/null || true
    exec 7>&-
}

# notify_admission_dispatch <label> <msg> [--key <incident_key>] [--run-id <id>]:
# единая точка, которой пользуются ВСЕ producer'ы realtime-сообщений
# (ds-publish.sh notify_route(), ledger-publish.sh fail() — тот путь, что
# исторически шлёт realtime в обход ds-publish.sh целиком, см. комментарий
# в ledger-publish.sh) — без общей точки вызова каждый producer реализовал
# бы гейт по-своему и они снова считали бы "последнее отправленное"
# раздельно, теряя весь смысл ГЛОБАЛЬНОГО лимита. manual_action_required
# сюда не заходит вовсе — вызывающий код сам решает это до вызова (см.
# notify_route()). Именованные флаги, не позиционные $3/$4 (Kimi, раунд 1):
# лишний позиционный аргумент молча стал бы ключом.
# Печатает готовый текст для tg_notify в stdout и возвращает 0, если слать
# можно сейчас (склеен с тем, что скопилось за время подавления, если было).
# Возвращает 1 (ничего не печатает), если сообщение поставлено в очередь —
# вызывающий обязан сам продублировать его в СВОЙ digest (сигнатура
# notify_digest_append у разных вызывающих разная по набору полей, этот
# хелпер её не знает и не должен). Возвращает 2, если общая очередь не смогла
# сохранить сообщение; вызывающий не должен считать такую передачу успешной.
notify_admission_dispatch() {
    local label="$1" msg="$2"
    shift 2 2>/dev/null || shift $#
    local key="" run_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --key) key="${2:-}"; shift 2 ;;
            --run-id) run_id="${2:-}"; shift 2 ;;
            *) echo "WARN: notify_admission_dispatch: неизвестный аргумент '$1' проигнорирован" >&2; shift ;;
        esac
    done
    notify_coverage_mark
    local admission_rc=0
    notify_admission_allow "$label" "$msg" "$key" "$run_id" || admission_rc=$?
    if [ "$admission_rc" -eq 0 ]; then
        local queued
        queued="$(notify_admission_flush)"
        if [ -n "$queued" ]; then
            printf '%s\n\n%s' "$queued" "$msg"
        else
            printf '%s' "$msg"
        fi
        return 0
    fi
    return "$admission_rc"
}

# notify_dedup_clear_prefix <prefix>: как notify_dedup_clear, но снимает ВСЕ
# ключи, начинающиеся с prefix, а не один точный ключ (WP-538, 25.08, пир-сессия
# с Codex) — нужна для composite-ключей вида "drain:<repo-id>:<file>", где
# конкретный конфликтующий файл заранее неизвестен вызывающему в точке успеха
# (drain мог упасть на любом файле очереди в предыдущих прогонах). Prefix
# обязан включать repo-id, не быть глобальным "drain:" — иначе снимет чужой,
# всё ещё активный инцидент другого репозитория на том же дедуп-дереве.
notify_dedup_clear_prefix() {
    local prefix="$1"
    # Пустой prefix превратил бы паттерн ниже в "fail-*.state" -- снял бы
    # ВСЕ активные fail/conflict-состояния всех продюсеров разом, не только
    # свой (cold-context review, 25.08). Сегодняшний единственный вызывающий
    # всегда передаёт непустой repo-id, но это общая библиотечная функция.
    [ -n "$prefix" ] || { echo "WARN: notify_dedup_clear_prefix: пустой prefix, отказ (во избежание снятия чужих состояний)" >&2; return 1; }
    local dedup_dir="${DS_PUBLISH_DEDUP_DIR:-$HOME/IWE/.claude/state/notify-dedup}"
    local had_state=1
    local f
    for f in "$dedup_dir"/fail-"$prefix"*.state "$dedup_dir"/conflict-"$prefix"*.state; do
        [ -f "$f" ] && { rm -f "$f" 2>/dev/null; had_state=0; }
    done
    return "$had_state"
}

# notify_coverage_mark: records that the CALLING SCRIPT (basename "$0",
# stable across sourcing — set once per process, WP-538 Ф3) has actually
# invoked the admission gate. Runtime evidence, not static grep: kimi's
# requirement (design session 2026-09-02) was that a "gated" coverage report
# must reflect an observed call, not merely that a script imports the
# function. Called once per notify_admission_dispatch invocation, so both
# telegram_send_gated() callers and the two direct callers (ds-publish.sh,
# ledger-publish.sh) get tracked uniformly.
notify_coverage_mark() {
    local dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}/coverage"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s' "$(date -u +%s)" > "$dir/$(notify_coverage_key "$0").last-seen" 2>/dev/null || true
}

# notify_coverage_key <script-path>: marker name = directory id + basename.
# The coverage report scans several directories (this repo, the IWE root, its
# hooks); a bare basename would let two same-named scripts share one marker
# (WP-538 Ф4, cold-context review).
notify_coverage_key() {
    local path="$1"
    printf '%s-%s' "$(notify_repo_id "$(dirname -- "$path")")" "$(basename -- "$path")"
}

# --- telegram-transport-allowlist.conf (WP-538 Ф5б/Ф6/Ф7) ----------------
# Row format since Ф7 (11.09, peer-session Kimi+Codex): SIX tab-separated
# fields, two INDEPENDENT axes instead of one overloaded "trusted":
#   <repo> <script-basename> <source-id> <enforced|unenforced> <reviewed|raw> <label-or-dash>
#   source-id  — stable identity used by the gate, the incident key and
#                `iwe-tg --source`; NOT the basename (Ф5 recorded the
#                same-name collision) and NOT the human label.
#   transport  — enforced: the send goes through telegram_send_impl() and
#                this gate actually decides delivery; unenforced: raw curl /
#                python post outside the library — the gate cannot see it,
#                the row is inventory for the commit-time text lint only.
#   text       — reviewed: message text read and human-readable; raw: not.
# Delivery through the library is allowed ONLY for enforced+reviewed. An
# "unenforced" row reaching the library means the row is stale (the script
# was rewired but the row wasn't) — quarantine, fail-closed, so the
# allowlist can never claim less than the truth.

# WP-538 Ф8b (11.09, пир-сессия с Codex): TELEGRAM_TRANSPORT_ALLOWLIST_FILE
# сам по себе не ограничен — любой вызывающий мог бы подменить allowlist на
# файл, где всё enforced+reviewed, и обойти весь deny-by-default гейт одной
# переменной окружения. Hardening от случайной/унаследованной конфигурации
# (не граница безопасности: субъект, способный выставить эту переменную,
# обычно может выставить и разрешающий флаг) — override принимается только
# вместе с явным opt-in, иначе громкая диагностика в stderr и явный отказ
# (exit 1, пустой stdout), а не тихая подмена на канонический файл: опечатка
# в тесте должна падать заметно, не молча тестировать не то, что ожидалось.
telegram_allowlist_file() {
    if [ -n "${TELEGRAM_TRANSPORT_ALLOWLIST_FILE:-}" ]; then
        if [ "${IWE_TEST_ALLOW_TELEGRAM_ALLOWLIST_OVERRIDE:-0}" = "1" ]; then
            printf '%s' "$TELEGRAM_TRANSPORT_ALLOWLIST_FILE"
            return 0
        fi
        echo "[telegram] ERROR: TELEGRAM_TRANSPORT_ALLOWLIST_FILE задан без IWE_TEST_ALLOW_TELEGRAM_ALLOWLIST_OVERRIDE=1 — override отклонён" >&2
        return 1
    fi
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../telegram-transport-allowlist.conf"
}

# _telegram_allowlist_lookup <field-number> <value>: the one place that
# knows the row layout. Exact match on one tab-separated field (awk, not a
# grep for "\tX\t" — with six columns the basename and the source-id are
# adjacent, and a grep would match either). Prints the row (exit 0) or
# nothing (exit 1).
_telegram_allowlist_lookup() {
    local field="$1" value="$2" allowlist_file line
    allowlist_file="$(telegram_allowlist_file)" || return 1
    [ -r "$allowlist_file" ] || return 1
    line="$(awk -F'\t' -v f="$field" -v v="$value" '!/^#/ && $f == v { print; exit }' "$allowlist_file" 2>/dev/null)"
    [ -n "$line" ] || return 1
    printf '%s' "$line"
}

# telegram_allowlist_line <caller-basename>: row by script basename (field 2).
telegram_allowlist_line() {
    _telegram_allowlist_lookup 2 "$1"
}

# telegram_allowlist_line_by_source <source-id>: row by source-id (field 3).
telegram_allowlist_line_by_source() {
    _telegram_allowlist_lookup 3 "$1"
}

# telegram_caller_source_id: the identity the gate and the incident key use.
# Explicit TELEGRAM_SOURCE_ID (set by `iwe-tg --source`) wins; otherwise the
# calling script's basename is resolved to its row's source-id; a script not
# in the allowlist keeps its bare basename (so the audit log names it).
telegram_caller_source_id() {
    if [ -n "${TELEGRAM_SOURCE_ID:-}" ]; then
        printf '%s' "$TELEGRAM_SOURCE_ID"
        return 0
    fi
    local caller line
    caller="$(basename -- "$0")"
    if line="$(telegram_allowlist_line "$caller")"; then
        printf '%s' "$line" | awk -F'\t' '{print $3}'
    else
        printf '%s' "$caller"
    fi
}

# telegram_caller_allowlist_row: the row for the current caller — by
# TELEGRAM_SOURCE_ID when set, else by basename. Exit 1 when unknown.
telegram_caller_allowlist_row() {
    if [ -n "${TELEGRAM_SOURCE_ID:-}" ]; then
        telegram_allowlist_line_by_source "$TELEGRAM_SOURCE_ID"
    else
        telegram_allowlist_line "$(basename -- "$0")"
    fi
}

# telegram_transport_audit: WP-538 Ф5б visibility check. Logs one line per
# UNKNOWN sender (a caller of telegram_send_impl() with no allowlist row)
# — audit only, never blocks the send itself. It can only see callers that
# go through this library at all, not a script making its own raw curl call
# to api.telegram.org (Codex, round-4 design consensus); those rows carry
# transport=unenforced and are covered by the commit-time text lint
# (scripts/tests/telegram-raw-text-lint-smoke.sh) instead. Rate-limited per
# caller (default 24h) so a runaway unknown caller firing every few minutes
# doesn't flood the log with the same fact.
TELEGRAM_TRANSPORT_AUDIT_TTL_H="${TELEGRAM_TRANSPORT_AUDIT_TTL_H:-24}"
case "$TELEGRAM_TRANSPORT_AUDIT_TTL_H" in
    ''|*[!0-9]*) TELEGRAM_TRANSPORT_AUDIT_TTL_H=24 ;;
esac

telegram_transport_audit() {
    local caller dir state_file now last
    caller="$(telegram_caller_source_id)"
    if telegram_caller_allowlist_row >/dev/null; then
        return 0
    fi

    dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}/transport-audit"
    mkdir -p "$dir" 2>/dev/null || return 0
    # Rate-limit marker keyed by the SENDER IDENTITY, not only by $0: through
    # iwe-tg every unregistered --source shares one $0, and a $0-only marker
    # let the second unknown source-id within 24h vanish from the log
    # (cold-context review of Ф7, 11.09).
    state_file="$dir/$(notify_coverage_key "$0")-$(printf '%s' "$caller" | tr -c 'a-zA-Z0-9._-' '-').last-logged"
    now=$(date -u +%s)
    last=$(cat "$state_file" 2>/dev/null)
    case "$last" in
        ''|*[!0-9]*) last=0 ;;
    esac
    if [ $(( (now - last) / 3600 )) -lt "$TELEGRAM_TRANSPORT_AUDIT_TTL_H" ]; then
        return 0
    fi

    printf '%s\n' "$now" > "$state_file" 2>/dev/null || true
    printf '%s\tunknown-sender\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$caller" \
        >> "$dir/log" 2>/dev/null || true
}

# telegram_send_trust_allowed: WP-538 Ф6 — the actual deny-by-default gate,
# Ф7 — two axes. Only transport=enforced AND text=reviewed sends realtime
# unchanged. Everything else — raw text, an unenforced row reaching the
# library (stale row), any other value, a caller missing from the file
# entirely, or the file itself missing — is 1 (deny). This is deliberately
# an allowlist, not a bad-pattern blocklist: an early design tried "catch
# obviously raw text" (ANSI/PASS/FAIL/journalctl signatures) and Codex
# rejected it in peer-session 2026-09-09-04-f6-deny-by-default-telegram —
# a new junk format without a known signature would still get through,
# which is deny-by-known-signatures, not deny-by-default. Unknown must be
# quarantine, never allow, for the guarantee to mean what its name says.
telegram_send_trust_allowed() {
    local line transport text
    line="$(telegram_caller_allowlist_row)" || return 1
    transport="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
    text="$(printf '%s' "$line" | awk -F'\t' '{print $5}')"
    [ "$transport" = "enforced" ] && [ "$text" = "reviewed" ]
}

# --- Channel: live chat vs morning digest (WP-568 Ф10, ArchGate 29.10.2026) ---
# Field 7 of the caller's row decides whether a trusted message may interrupt
# the pilot now. The trust gate above answers "who may send"; this answers
# "may this wake the pilot". Default is the digest: a row without field 7, an
# unknown value or a caller without a row never reaches the live chat, so a
# new script cannot add noise by forgetting to classify itself.
#   live     — always live (calendar reminders, the day plan, the secretary)
#   decision — live only when the caller sets TELEGRAM_NEEDS_DECISION=1 for
#              this send (the pilot's decision is needed now); digest otherwise
#   digest   — never live
#   sink     — the morning digest itself: always live, sent as is (its
#              renderer already scrubs the texts it quotes)
telegram_caller_channel() {
    local line channel
    line="$(telegram_caller_allowlist_row)" || { printf 'digest'; return 0; }
    channel="$(printf '%s' "$line" | awk -F'\t' '{print $7}' | tr -d '[:space:]')"
    case "$channel" in
        live|decision|sink) printf '%s' "$channel" ;;
        *) printf 'digest' ;;
    esac
}

# telegram_digest_drain_alive: 0 when this host's digest was really delivered
# (or found empty) recently enough. "Recently enough" is stated by the drain
# itself in alive_until_ts: its caller knows its cadence (the server timer,
# slots 07/14/21 with a 10h night gap, sets NOTIFY_DIGEST_ALIVE_H=14, a host that drains once a day keeps 36;
# WP-568, 30.10). An older status file without that field falls back to
# last_ok_ts + NOTIFY_DIGEST_ALIVE_H (default 36).
# The digest queue is per host; deferring on a host where nothing drains it
# would turn "later" into "never". Without a live drain the library keeps the
# old behaviour (live chat) — noisy, but nothing is lost.
telegram_digest_drain_alive() {
    local status_file="${DS_PUBLISH_DIGEST_DIR:-$HOME/IWE/.claude/state/notify-digest}/last-drain.json"
    [ -r "$status_file" ] || return 1
    python3 - "$status_file" "${NOTIFY_DIGEST_ALIVE_H:-36}" <<'PY' 2>/dev/null
import json, sys
from datetime import datetime, timedelta, timezone
fmt = "%Y-%m-%dT%H:%M:%SZ"
now = datetime.now(timezone.utc)
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
    until = doc.get("alive_until_ts") or ""
    if until:
        sys.exit(0 if now <= datetime.strptime(until, fmt).replace(tzinfo=timezone.utc) else 1)
    ok = datetime.strptime(doc.get("last_ok_ts") or "", fmt).replace(tzinfo=timezone.utc)
except (ValueError, OSError, AttributeError):
    sys.exit(1)
sys.exit(0 if now - ok <= timedelta(hours=float(sys.argv[2])) else 1)
PY
}

# telegram_live_contract_violation <text>: prints which class of machine detail
# a live text carries (exit 0), or exit 1 when it carries none. Bounds are
# spelled out instead of \b: BSD grep on the Mac does not promise \b in -E.
telegram_live_contract_violation() {
    local text="$1"
    # /var/lib/iwe/ holds system files the pilot acts on; not machine noise.
    if printf '%s' "$text" | sed 's#/var/lib/iwe/##g' | grep -Eq '(^|[[:space:](])/(Users|home|tmp|var|private)/'; then
        printf 'абсолютный путь файла'; return 0
    fi
    if printf '%s' "$text" | grep -Eq '\.(ndjson|jsonl|trace)([^[:alnum:]]|$)'; then
        printf 'служебный файл журнала'; return 0
    fi
    if printf '%s' "$text" | grep -Eq '(^|[^0-9a-f])[0-9a-f]{40}([^0-9a-f]|$)'; then
        printf 'полный хэш коммита'; return 0
    fi
    if printf '%s' "$text" | grep -Eiq '(exit=[0-9]|exit code|см\. stderr|попроси агента)'; then
        printf 'технический код или отсылка «попроси агента»'; return 0
    fi
    return 1
}

# telegram_scrub_text <text>: the same machine detail removed in place (paths
# → file name, full hashes → 8 characters, exit codes dropped), via the one
# scrubber the digest renderer also uses. Falls back to the original text.
telegram_scrub_text() {
    local scrubbed
    scrubbed="$(printf '%s' "$1" | python3 "$(dirname "${BASH_SOURCE[0]}")/notify-text-scrub.py" 2>/dev/null)" \
        && [ -n "$scrubbed" ] && { printf '%s' "$scrubbed"; return 0; }
    printf '%s' "$1"
}

# telegram_channel_route <text>: prints "live", "live-scrub:<reason>" or
# "digest". The only place the live/digest decision is made.
#   live-scrub — a live message carrying machine detail: it still goes out
#                NOW (a reminder or a decision must not wait for the morning),
#                scrubbed, and the digest notes the source so its text gets fixed.
telegram_channel_route() {
    local text="$1" channel reason repeat_out
    channel="$(telegram_caller_channel)"
    case "$channel" in
        sink) printf 'live'; return 0 ;;
        live) ;;
        decision)
            # Urgent = the pilot must act now AND the text says what to do and
            # where (WP-568, pilot decision 30.10). A flagged send without that
            # line is demoted to the digest and counted, so its author fixes it.
            if [ "${TELEGRAM_NEEDS_DECISION:-0}" = "1" ] && [ -n "$(telegram_action_text "$text")" ]; then
                :
            else
                [ "${TELEGRAM_NEEDS_DECISION:-0}" = "1" ] && telegram_note_missing_action
                channel=digest
            fi ;;
    esac
    if [ "$channel" = digest ]; then
        if telegram_digest_drain_alive; then
            printf 'digest'
            return 0
        fi
        # No working digest on this host: fall through to the live path.
    fi
    # A chronic alert is urgent once: the same alert again within the window is
    # a line in the digest unless it got worse. Only where the digest really
    # gets read: a repeat parked in a queue nobody drains would be invisible.
    if telegram_digest_drain_alive \
       && repeat_out="$(telegram_repeat_check "$text")" && [ "${repeat_out%% *}" = repeat ]; then
        printf '%s' "$repeat_out"
        return 0
    fi
    if reason="$(telegram_live_contract_violation "$text")"; then
        printf 'live-scrub:%s' "$reason"
        return 0
    fi
    printf 'live'
}

# telegram_caller_chronic: 0 when the caller's allowlist row has "chronic" in
# field 8 (an alert that repeats on a timer), 1 otherwise.
telegram_caller_chronic() {
    local line flag
    line="$(telegram_caller_allowlist_row)" || return 1
    flag="$(printf '%s' "$line" | awk -F'\t' '{print $8}' | tr -d '[:space:]')"
    [ "$flag" = "chronic" ]
}

# telegram_action_text <text>: the "what to do and where" part of an urgent
# message. TELEGRAM_ACTION wins; otherwise the text after the first marker
# "Что делать:" / "Нужен разбор:" / "Нужно сделать:" / "Действие:" (at least 10
# characters). Prints nothing when the message carries no action.
telegram_action_text() {
    local text="$1" action="${TELEGRAM_ACTION:-}"
    if [ -z "$action" ]; then
        action="$(printf '%s' "$text" | sed -n -E 's/.*(Что делать|Нужен разбор|Нужно сделать|Действие): *(.{10,}).*/\2/p' | head -1)"
    fi
    printf '%s' "$action"
}

# telegram_append_action <text>: the text with "Что делать: <TELEGRAM_ACTION>" as
# its last line, unless TELEGRAM_ACTION is empty or the text already has that line.
telegram_append_action() {
    local text="$1"
    if [ -n "${TELEGRAM_ACTION:-}" ]; then
        case "$text" in
            *"Что делать:"*) ;;
            *) text="${text}"$'\n'"Что делать: ${TELEGRAM_ACTION}" ;;
        esac
    fi
    printf '%s' "$text"
}

# telegram_note_missing_action: an urgent send without an action line was
# demoted to the digest. One TSV row per demotion (time, source) so the
# sender can be fixed; logging never affects the send.
telegram_note_missing_action() {
    local source dir
    source="$(telegram_caller_source_id)"
    echo "[telegram] срочное без текста действия понижено до сводки ($source)" >&2
    dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    mkdir -p "$dir" 2>/dev/null || return 0
    { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$source" >> "$dir/no-action-log.tsv"; } 2>/dev/null || true
}

# telegram_repeat_check <text>: prints "live", or "repeat <hours> <note>" when
# the same alert (source + text with numbers, paths and hashes normalised) was
# already sent live within NOTIFY_REPEAT_WINDOW_H hours (default 24) and did
# not get worse (severity ⚠️ < 🚨 < 🆘). <hours> = time since that live send,
# <note> = 1 when the digest should get a line (at most once per 3 hours per
# alert). Read-only for a live answer: the state records a live send only
# AFTER Telegram confirmed it (telegram_repeat_record), so a failed send never
# turns the next attempt into a "repeat" and the alert is not lost. Any
# failure prints "live": a lost alert is worse than a repeated one.
telegram_repeat_check() {
    telegram_repeat_state check "$1"
}

# telegram_repeat_record <text>: the live send of <text> was confirmed; remember
# it as the alert's last live send. With TELEGRAM_RECOVERED=1 it clears every
# alert of the source instead (the recovery message itself is not an alert).
telegram_repeat_record() {
    telegram_repeat_state record "$1" >/dev/null
}

# telegram_repeat_state check|record <text>: the one place that reads and
# writes the per-host state (JSON under flock, written through rename).
# Only senders marked "chronic" (field 8 of the allowlist row) take part:
# reminders, the day plan and the secretary's dialogue legitimately repeat a
# text and must never wait.
telegram_repeat_state() {
    local mode="$1" text="$2" source dir
    telegram_caller_chronic || { printf 'live'; return 0; }
    source="$(telegram_caller_source_id)"
    dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    mkdir -p "$dir" 2>/dev/null || { printf 'live'; return 0; }
    python3 - "$mode" "$dir" "$source" "$text" "${TELEGRAM_RECOVERED:-0}" \
        "${NOTIFY_REPEAT_WINDOW_H:-24}" "${NOTIFY_REPEAT_NOW_EPOCH:-$(date +%s)}" <<'PY' 2>/dev/null || printf 'live'
import fcntl, hashlib, json, os, re, sys
mode, d, source, text, recovered, window_h, now = sys.argv[1:8]
now = int(now)
window = float(window_h) * 3600
state_path = os.path.join(d, "repeat-state.json")
sev = 3 if "🆘" in text else 2 if "🚨" in text else 1 if "⚠" in text else 0
# A message that starts with the recovery mark is the end of the alert, not a
# new one: it clears the source's keys and goes live.
if text.lstrip().startswith("✅"):
    recovered = "1"
# The key is the whole text with the noise taken out, never truncated: a new
# problem appended to a list of problems must make a new key. Severity marks
# stay out (severity is compared on its own: a worse alert is urgent again),
# dates stay in (a new day is a new alert), counters, hashes and ids are noise.
norm = re.sub("[🆘🚨⚠✅️]", "", text.lower())
date_re = r"\d{4}-\d{2}-\d{2}|\d{1,2}\.\d{1,2}\.\d{2,4}"
dates = ",".join(re.findall(date_re, norm))
norm = re.sub(date_re, "D", norm)
norm = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "u", norm)
norm = re.sub(r"[0-9a-f]{7,}", "h", norm)
norm = re.sub(r"\d+", "n", norm)
norm = re.sub(r"\s+", " ", norm).strip() + "|" + dates
key = source + "|" + hashlib.sha1(norm.encode("utf-8")).hexdigest()[:12]
out = "live"
with open(os.path.join(d, "repeat-state.lock"), "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        state = json.load(open(state_path, encoding="utf-8"))
    except (OSError, ValueError):
        state = {}
    state = {k: v for k, v in state.items() if now - v.get("last_seen", 0) < 7 * 86400}
    e = state.get(key)
    if mode == "record":
        if recovered == "1":
            state = {k: v for k, v in state.items() if not k.startswith(source + "|")}
        else:
            state[key] = {"first_seen": e["first_seen"] if e else now, "last_live": now, "last_seen": now,
                          "last_note": 0, "severity": sev, "count": 1}
    elif recovered != "1" and e and now - e["last_live"] < window and sev <= e["severity"]:
        e["count"] += 1
        e["last_seen"] = now
        note = 1 if now - e.get("last_note", 0) >= 3 * 3600 else 0
        if note:
            e["last_note"] = now
        out = "repeat %d %d" % (int((now - e["last_live"]) // 3600), note)
    tmp = state_path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, state_path)
print(out)
PY
}

# telegram_note_repeat <text> <route>: a chronic alert went to the digest as
# one line "не решено: <source> ×N" instead of the chat. <route> is the
# "repeat <hours> <note>" answer of telegram_repeat_check.
telegram_note_repeat() {
    local text="$1" route="$2" hours note label source dir
    hours="$(printf '%s' "$route" | awk '{print $2}')"
    note="$(printf '%s' "$route" | awk '{print $3}')"
    source="$(telegram_caller_source_id)"
    label="$(telegram_quarantine_label)"
    [ "$label" = "фоновая автоматизация" ] && label="$source"
    echo "[telegram] повтор срочного, уже отправлялось ${hours:-?} ч назад ($source): $text" >&2
    [ "$note" = "1" ] && notify_digest_append_checked deferred "не решено: $label" "$text (не решено, срочно сообщалось ${hours:-?} ч назад)" || true
    dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    mkdir -p "$dir" 2>/dev/null || return 0
    { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$source" >> "$dir/repeat-log.tsv"; } 2>/dev/null || true
}

# telegram_defer_to_digest <text>: what the library does INSTEAD of a live send
# for a trusted caller whose channel is the digest. The text itself is kept
# (status "deferred") so the morning digest can show what each source said.
# The text also goes to stderr (the caller's own log), like a quarantine, so a
# failed digest write still leaves a trace.
telegram_defer_to_digest() {
    local text="$1" source label dir
    source="$(telegram_caller_source_id)"
    label="$(telegram_quarantine_label)"
    [ "$label" = "фоновая автоматизация" ] && label="$source"
    echo "[telegram] в утреннюю сводку ($source): $text" >&2
    if ! notify_digest_append_checked deferred "$label" "$text"; then
        echo "[telegram] WARN: запись в утреннюю сводку не удалась ($source) — текст выше, в журнале вызывающего" >&2
    fi
    # One TSV row per deferral (time, source-id) for the weekly reader-side
    # numbers (notify-weekly-metrics.sh); the digest queue itself is removed
    # after each morning send. Logging never affects the send.
    dir="${DS_PUBLISH_ADMISSION_DIR:-$HOME/IWE/.claude/state/notify-admission}"
    mkdir -p "$dir" 2>/dev/null || return 0
    { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$source" >> "$dir/deferred-log.tsv"; } 2>/dev/null || true
}

# telegram_note_contract_violation <text> <reason>: a live text went out
# scrubbed; leave the original in the digest under ⚠️ so its author fixes it.
telegram_note_contract_violation() {
    local text="$1" reason="$2" label
    label="$(telegram_quarantine_label)"
    [ "$label" = "фоновая автоматизация" ] && label="$(telegram_caller_source_id)"
    notify_digest_append notice "⚠️ ушло в чат с вычищенными техническими деталями ($reason), поправить текст источника: $label" "$text"
}

# telegram_quarantine_label: field 6 of the caller's row, or a generic
# fallback if the caller (or the file) is missing — the digest notice
# (day-close, once/day) shows this, never the raw message text, so a
# missing/placeholder label is still safe, just less specific.
telegram_quarantine_label() {
    local line label
    # A sender without a row is named, not hidden behind a generic label: the
    # digest line "вне реестра: <script> ×N" tells the pilot which script needs
    # a row in the allowlist (its text stays quarantined, never sent).
    line="$(telegram_caller_allowlist_row)" || { printf 'вне реестра: %s' "$(telegram_caller_source_id)"; return 0; }
    label="$(printf '%s' "$line" | awk -F'\t' '{print $6}')"
    [ -n "$label" ] && [ "$label" != "-" ] || label="фоновая автоматизация"
    printf '%s' "$label"
}

# telegram_quarantine_notice <text>: what telegram_send_impl()/
# telegram_send_and_get_id_impl() do INSTEAD of a real send when
# telegram_send_trust_allowed denies the caller. Keeps the existing
# notify_digest_append/day-close-mechanical.sh channel (one aggregated
# "также: <label> ×N" line at day-close) rather than a second mechanism —
# the raw text goes to stderr (caller's own log redirection) and to the
# digest JSONL's "detail" field for an agent to inspect later, never to
# Telegram itself, not even batched.
telegram_quarantine_notice() {
    local text="$1" caller label
    caller="$(telegram_caller_source_id)"
    label="$(telegram_quarantine_label)"
    echo "[telegram] quarantined (не enforced+reviewed в allowlist, $caller): $text" >&2
    notify_digest_append notice "$label" "$text"
}

# notify_join_lines <piece> [<piece> ...]: join non-empty pieces with exactly
# one newline between them. Do not rely on a piece's own trailing newline to
# act as the separator — `$(...)` command substitution always strips
# trailing newlines, so `PREFIX=$(some_func_ending_in_echo_newline)` silently
# loses the separator the caller expected (live incident 16.09,
# night-cycle-verify.sh's repeat_incident_prefix: two sentences ran together
# with no break in the delivered Telegram message). Each piece is stripped of
# its own trailing newlines first, so a piece that still carries one (old
# callers not yet updated) does not produce a doubled blank line.
notify_join_lines() {
    local out="" piece
    for piece in "$@"; do
        piece="${piece%$'\n'}"
        [ -n "$piece" ] || continue
        if [ -n "$out" ]; then
            out+=$'\n'"$piece"
        else
            out="$piece"
        fi
    done
    printf '%s' "$out"
}
