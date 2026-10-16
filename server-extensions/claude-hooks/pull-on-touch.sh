#!/bin/bash
# pull-on-touch.sh — PreToolUse hook: ленивая подтяжка git-репо при первом касании за сессию.
#
# Реализует правило Pull-on-Touch (CLAUDE.md §2 п.5) детерминированно, а не "по памяти агента".
# Причина: правило поведенческое → системно пропускается (инцидент 5 мая 2026 и 14 июня 2026 —
# ложный диагноз "Day Open пропущен" из-за чтения устаревшей локальной копии).
#
# Контракт:
#   Триггер: первое за сессию касание пути под ~/IWE/<repo> любым из инструментов
#            Read | Write | Edit | MultiEdit | NotebookEdit | Bash.
#   Вход:    stdin JSON {tool_name, tool_input, session_id}.
#   Действие: scripts/iwe-safe-pull.sh <repo> — одна завершённая проверка на репо за сессию.
#   Отказы:  НИКОГДА не блокирует (exit 0 всегда). Грязное дерево / сеть / отставание
#            → safe-pull ничего не меняет, в additionalContext пометка potentially stale.
#   Состояние: ~/.claude/state/repo-pulled-<session>.txt (завершённые попытки).

set -uo pipefail

[[ "${1:-}" == "--help" ]] && {
    echo "pull-on-touch.sh — lazy safe pull on first repo touch per session (CLAUDE.md §2 п.5)"
    exit 0
}

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"

# Имя сессии для файла состояния.
SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/repo-pulled-${SESSION_ID}.txt"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Извлечь имена репо (первый сегмент под IWE/) из пути (Read/Edit) или команды (Bash).
# Отдельно: `cd <IWE_ROOT> && <сегмент>` (пир-сессия 2026-10-16-23-fix-pull-on-touch,
# Claude+Kimi+Codex, ревью той же сессии добавило кавычки/`~` и множественный `cd`) —
# repo-имя в относительном пути ПОСЛЕ && не содержит подстроки "IWE/<repo>" целиком
# (путь разбит между целью cd и следующим аргументом), основной regex выше его не ловит.
# Команда делится на сегменты по `&&`/`||`/`;`/`|`; для КАЖДОГО сегмента вида `cd X`,
# резолвящегося в IWE_ROOT (с учётом кавычек, `~/`, `$HOME`, `$IWE_ROOT`), разбирается
# только СЛЕДУЮЩИЙ сегмент — не весь хвост команды (codex: `cd A && cd B && ...` не
# должен подхватывать репо из третьего сегмента через первый cd). Известное ограничение
# (не решаем здесь): симлинк IWE_ROOT на другой физический путь не резолвится.
REPOS=$(INPUT="$INPUT" IWE_ROOT="$IWE_ROOT" python3 -c '
import sys, json, re, os
d = json.loads(os.environ["INPUT"])
ti = d.get("tool_input", {}) or {}
blob = (ti.get("file_path") or ti.get("path") or "") + "\n" + (ti.get("command") or "")
command = ti.get("command") or ""
root = os.environ["IWE_ROOT"]
seen, out = set(), []

def consider(name):
    if name in seen:
        return
    seen.add(name)
    marker = os.path.join(root, name, ".git")
    if os.path.isdir(marker) or os.path.isfile(marker):
        out.append(name)

for name in re.findall(r"IWE/([A-Za-z0-9._-]+)", blob):
    consider(name)

home = os.environ.get("HOME", "")
segments = re.split(r"\s*(?:&&|\|\||;|\|)\s*", command)
for i in range(len(segments) - 1):
    cdm = re.match(r"^cd\s+(.+)$", segments[i])
    if not cdm:
        continue
    cd_target = cdm.group(1).strip()
    while cd_target[:1] in (chr(34), chr(39)) and cd_target[-1:] == cd_target[:1]:
        cd_target = cd_target[1:-1]
    if cd_target == "~" or cd_target.startswith("~/"):
        cd_target = home + cd_target[1:]
    cd_target = cd_target.replace("$HOME", home).replace("$IWE_ROOT", root)
    if os.path.normpath(cd_target) != os.path.normpath(root):
        continue
    for token in segments[i + 1].split():
        tm = re.match(r"^IWE/([A-Za-z0-9._-]+)", token)
        if not tm:
            tm = re.match(r"^\./([A-Za-z0-9._-]+)/", token)
        if not tm:
            tm2 = re.match(r"^([A-Za-z0-9._-]+)/", token)
            if tm2 and tm2.group(1) not in (".", ".."):
                tm = tm2
        if tm:
            consider(tm.group(1))

print("\n".join(out))
' 2>/dev/null)

[ -z "$REPOS" ] && exit 0

SAFE_PULL="$IWE_ROOT/scripts/iwe-safe-pull.sh"

run_safe_pull() {
    local repo_dir="$1"
    [ -f "$SAFE_PULL" ] || {
        echo "pull-on-touch: safe-pull not found: $SAFE_PULL" >&2
        return 1
    }

    IWE_ROOT="$IWE_ROOT" bash "$SAFE_PULL" "$repo_dir"
}

warns=""
fresh=""
completed=""
while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    grep -qxF "$repo" "$STATE_FILE" && continue   # уже трогали этот репо в сессии

    dir="$IWE_ROOT/$repo"

    # Stale staged diff sitting in the index предшествует этой сессии (найдено
    # 11.09.2026 живьём: застейдженный откат WP-539/S-63/R23-shadow в
    # iwe-local-config пролежал незамеченным несколько часов, потому что
    # ничто не проверяет index на первом касании репо за сессию — read-only,
    # никогда не блокирует, просто называет репо.
    if ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        warns="${warns}${repo}: в индексе застейджены изменения от прошлой/чужой сессии — проверь 'git diff --cached' перед тем как коммитить что-либо здесь. "
    fi

    # Safe-pull не имеет права менять stash. Снимок OID ловит рост, уменьшение
    # и same-count replacement; конкурентное изменение не приписываем хуку.
    stash_before_ok=true
    stash_before=$(git -C "$dir" stash list --format=%H 2>/dev/null) || stash_before_ok=false

    if run_safe_pull "$dir" >/dev/null 2>&1; then
        fresh="${fresh}${repo} "
    else
        # Shared checkout не меняется автоматически: safe-pull отказывается без cleanup.
        warns="${warns}${repo}: проверка свежести не пройдена, данные potentially stale. "
    fi

    stash_after_ok=true
    stash_after=$(git -C "$dir" stash list --format=%H 2>/dev/null) || stash_after_ok=false
    if [ "$stash_before_ok" != "true" ] || [ "$stash_after_ok" != "true" ]; then
        warns="${warns}${repo}: не удалось проверить инвариант stash, нужен ручной просмотр. "
    elif [ "$stash_after" != "$stash_before" ]; then
        warns="${warns}${repo}: инвариант safe-pull нарушен или stash изменён конкурентно — ничего не применяй автоматически, нужен поштучный разбор. "
    fi
    completed="${completed}${repo}"$'\n'
done <<< "$REPOS"

# Сообщить агенту только если есть что сказать (свежие данные или пометка stale).
msg=""
[ -n "$fresh" ] && msg="🔄 Проверил свежее: ${fresh}"
[ -n "$warns" ] && msg="${msg}⚠️ ${warns}"

if [ -n "$msg" ]; then
    if ! printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps({"additionalContext": sys.stdin.read()}))'; then
        # No visible result means no completed attempt. Fail open for the tool call,
        # but leave state unmarked so the next touch can retry and report honestly.
        exit 0
    fi
fi

# State is the final side effect. If host kills hook/safe-pull before a complete
# result is emitted, the next operation retries instead of silently skipping.
[ -z "$completed" ] || printf '%s' "$completed" >> "$STATE_FILE"

exit 0
