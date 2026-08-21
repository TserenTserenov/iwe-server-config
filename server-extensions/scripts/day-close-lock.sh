#!/bin/bash
# day-close-lock.sh — git-native cross-machine lock against duplicate Day Close runs (WP-484 Ф2).
#
# Инцидент 17.07: сервер (tsekh-1) и пилот вручную закрыли один день независимо друг от друга,
# gap обнаружился только в момент commit+push. Git log сам по себе неатомарен (read-then-act),
# поэтому источник истины — сам факт push: кто раньше запушил "day-close-start:", тот и работает,
# остальные видят чужой свежий маркер (или reject при попытке запушить свой) и останавливаются
# ДО начала работы, а не после.
#
# Маркеры — ПУСТЫЕ коммиты, созданные через commit-tree (не `git commit --allow-empty`, которая
# не гарантирует пустой diff если в индексе есть чужие staged-файлы — реальный риск в репо, где
# параллельно работают несколько агентов). Два независимых пустых коммита с разными сообщениями
# никогда не конфликтуют при rebase — проверено тестом на реальной гонке.
#
# После push-reject проверка идёт по origin/<branch> НАПРЯМУЮ (git fetch, без rebase) — если
# сначала перебазировать свой маркер поверх новых чужих коммитов и только потом проверять лог,
# собственный только что перебазированный маркер (committer-date обновляется rebase'ом на "сейчас")
# становится самым свежим совпадением и маскирует реальную причину reject'а — ревью нашло это
# эмпирически (reject от ПОСТОРОННЕГО коммита давал ложное "кто-то закрывает день" на каждый раз).
#
# TZ закреплён в UTC: сервер и Mac иначе могут разойтись в вычислении "today" у полуночи.
#
# Двухуровневая защита: сначала быстрый локальный барьер (gateway-lock.py, для двух процессов на
# ОДНОЙ машине), затем git-маркер (для гонки МЕЖДУ машинами — ровно инцидент 17.07). Первый уровень
# не обязателен (gateway недоступен → просто пропускается), второй — единственный источник истины.
#
# Usage: day-close-lock.sh acquire
#   exit 0 — лок взят, можно приступать к закрытию дня
#   exit 1 — день уже закрыт сегодня (найден финальный коммит "day-close: YYYY-MM-DD")
#   exit 3 — кто-то уже закрывает день прямо сейчас (свежий "day-close-start:", локально или на другой машине)
#   exit 2 — git/gateway-операция не удалась однозначно (сеть/хук/окружение) — ретраить снаружи, не считать "уже закрыто"

set -euo pipefail
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"
TTL_SECONDS=1800  # та же конвенция, что scripts/session-guard.sh HK_MAX_AGE (30 мин)
GATEWAY_LOCK_PY="$REPO_DIR/scripts/lib/gateway-lock.py"

log() { echo "[day-close-lock] $1"; }

# Единая точка выхода после того, как локальный маркер-коммит уже создан: откатывает его
# и завершает с нужным кодом — вместо повторения "discard + exit" по трём местам (P2).
abort_after_marker() {
  local code="$1" msg="$2"
  log "$msg"
  discard_local_marker
  exit "$code"
}

# Быстрый барьер для двух процессов на ОДНОЙ машине — необязательный, gateway недоступен → просто
# продолжаем и полагаемся на git-проверку ниже (она единственная работает между машинами).
local_barrier() {
  [ -x "$GATEWAY_LOCK_PY" ] || { log "gateway-lock.py не найден — пропускаю локальный барьер"; return 0; }
  local rc=0
  python3 "$GATEWAY_LOCK_PY" acquire "day-close-lock" "$TTL_SECONDS" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    log "Локальный барьер: день уже закрывается на этой машине (gateway lock занят) — выхожу"
    exit 3
  elif [ "$rc" -eq 2 ]; then
    log "gateway недоступен — пропускаю локальный барьер, дальше решает git"
  fi
}

# Возвращает: "closed" | "start:<age_seconds>" | "" (пусто — сегодня ничего не было).
# $1 — git-ref для проверки (по умолчанию HEAD; для пост-reject проверки — origin/<branch>,
# НЕ локальный HEAD после rebase, см. комментарий в заголовке файла).
check_today_history() {
  local ref="${1:-HEAD}"
  local today; today=$(date +%Y-%m-%d)
  local log_lines
  log_lines=$(git log "$ref" --since="${today} 00:00" --format="%ct %s" 2>/dev/null || true)

  if echo "$log_lines" | grep -q "day-close: ${today}"; then
    echo "closed"
    return
  fi

  local start_line
  start_line=$(echo "$log_lines" | grep "day-close-start: ${today}" | head -1 || true)
  if [ -n "$start_line" ]; then
    local ts now
    ts=$(echo "$start_line" | awk '{print $1}')
    now=$(date +%s)
    echo "start:$(( now - ts ))"
    return
  fi

  echo ""
}

# Коммит гарантированно без diff (не зависит от состояния индекса, в отличие от --allow-empty).
create_start_marker() {
  local who="$1" today="$2"
  local parent tree new
  parent=$(git rev-parse HEAD) || return 1
  tree=$(git rev-parse 'HEAD^{tree}') || return 1
  new=$(git commit-tree -p "$parent" -m "day-close-start: ${today} by ${who}" "$tree") || return 1
  git update-ref HEAD "$new" || return 1
}

# Откатывает локальный незапушенный маркер к последнему известному состоянию origin — если мы
# зависли в rebase (для пустых коммитов маловероятно, но не исключено), сначала выходим из него.
discard_local_marker() {
  local git_dir rm_dir ra_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  rm_dir="$git_dir/rebase-merge"; ra_dir="$git_dir/rebase-apply"
  { [ -d "$rm_dir" ] || [ -d "$ra_dir" ]; } && { git rebase --abort >/dev/null 2>&1 || log "git rebase --abort не удался — возможно локальный rebase-стейт остался, проверить вручную"; }
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch" ] && git rev-parse "origin/$branch" >/dev/null 2>&1; then
    git reset --mixed "origin/$branch" >/dev/null 2>&1 \
      || log "не удалось откатить локальный маркер к origin/$branch — проверить вручную (git status)"
  fi
}

# F3 (пир-сессия 2026-08-21-02-day-close-anomaly-classes): собственный
# OID-маркированный стэш вместо встроенного --autostash. Встроенный при
# конфликтном pop оставляет безымянные записи (6 накопилось за сутки 20.08),
# а один из pop'ов вернул старую версию DayPlan поверх закоммиченной. Здесь:
# создание, захват OID, apply и drop сериализованы одним flock на весь
# acquire; запись помечена run_id; drop — только после подтверждённо чистого
# apply и только именно этой записи; чужие стэши не трогаются никогда.
# Untracked в стэш не входят: rebase, падающий на untracked-overwrite, — это
# FAIL с явным списком, решение о таких файлах за оператором, не за скриптом.
STASH_OID=""

own_stash_lock() {
  local git_dir
  # review-04: любая неудача разрешения пути/открытия fd — fail closed, не
  # «продолжить без блокировки».
  git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || { log "git-common-dir не резолвится — отказ (fail closed)"; exit 2; }
  case "$git_dir" in
    /*) : ;;
    *) git_dir="$(git rev-parse --show-toplevel)/$git_dir" ;;
  esac
  exec 9>"$git_dir/day-close-lock.stash.lock" || { log "не удалось открыть lock-файл — отказ (fail closed)"; exit 2; }
  if command -v flock >/dev/null 2>&1; then
    flock 9 || { log "flock на stash-lock не взят — отказ (fail closed)"; exit 2; }
  elif command -v shlock >/dev/null 2>&1; then
    shlock -f "$git_dir/day-close-lock.stash.lock.pid" -p $$ || { log "shlock на stash-lock не взят — отказ (fail closed)"; exit 2; }
    # review-04: путь разворачиваем сейчас — локальная переменная к моменту
    # EXIT уже не существует; trap у этого скрипта один, замена безопасна.
    trap "rm -f '$git_dir/day-close-lock.stash.lock.pid'" EXIT
  elif mkdir "$git_dir/day-close-lock.stash.lock.d" 2>/dev/null; then
    trap "rm -rf '$git_dir/day-close-lock.stash.lock.d'" EXIT
  else
    log "ни flock, ни shlock, ни mkdir-lock недоступны — отказ (fail closed)"
    exit 2
  fi
}

own_stash_push() {
  local before after run_id out
  run_id="$(date +%s)-$$"
  before=$(git rev-parse -q --verify refs/stash 2>/dev/null || echo "")
  out=$(git stash push -m "day-close-lock-$run_id" 2>&1) || { log "git stash push failed: $out"; return 1; }
  after=$(git rev-parse -q --verify refs/stash 2>/dev/null || echo "")
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    STASH_OID="$after"
  else
    # «No local changes to save» — чистое дерево, стэш не нужен.
    STASH_OID=""
  fi
  return 0
}

own_stash_apply() {
  [ -z "$STASH_OID" ] && return 0
  # review-03: apply один раз и сразу с --index — восстанавливаем и staged-
  # состояние, не только worktree.
  if ! git stash apply --index "$STASH_OID" >/dev/null 2>&1; then
    log "КОНФЛИКТ при возврате стэша day-close-lock (OID $STASH_OID) — запись СОХРАНЕНА в stash, разберите вручную: git stash show -p $STASH_OID; git checkout --theirs/--ours по месту; затем git stash drop"
    return 1
  fi
  # review-01 High-5 + review-02/03/04 High: успешный exit apply не доказывает
  # восстановление. Полная сверка (python, NUL-парсинг): M/A — блоб и режим
  # worktree-файла равны записанным в стэше, D — файл отсутствует и в worktree,
  # и в индексе; staged-блоб сверяется с index-коммитом стэша (^2); пустой или
  # неполный список = проверка не состоялась = не удалять. --no-renames: rename
  # для нас — пара delete+add, сверяется по тем же правилам честно.
  if ! python3 - "$STASH_OID" <<'VERIFY_EOF'
import subprocess, sys, os, stat
oid = sys.argv[1]
def git(*args, check=True, **kw):
    r = subprocess.run(["git"]+list(args), capture_output=True, **kw)
    if check and r.returncode != 0:
        raise SystemExit(2)
    return r
raw = git("stash", "show", "--name-status", "--no-renames", "-z", oid).stdout
if not raw:
    print("пустой список файлов стэша — сверка невозможна", file=sys.stderr)
    raise SystemExit(1)
parts = raw.decode("utf-8", "surrogateescape").split("\0")
entries = []
i = 0
while i < len(parts) - 1:
    entries.append((parts[i], parts[i+1]))
    i += 2
fail = None
for st, f in entries:
    st = st.strip()
    if not f:
        continue
    if st == "D":
        # review-05: unstaged-удаление — файла нет в worktree, но он ОБЯЗАН
        # сохраниться в индексе (как в ^2); staged-удаление — нет ни там, ни там.
        if os.path.lexists(f):
            fail = f"{f}: удалён в стэше, но существует в worktree"; break
        stash_idx = git("rev-parse", f"{oid}^2:{f}", check=False)
        stash_idx_blob = stash_idx.stdout.decode().strip() if stash_idx.returncode == 0 else ""
        staged = git("ls-files", "-s", "--", f).stdout.decode().split()
        idx_blob = staged[1] if staged else ""
        if stash_idx_blob:
            if idx_blob != stash_idx_blob:
                fail = f"{f}: unstaged-удаление — индекс обязан держать блоб {stash_idx_blob[:8]} из стэша"; break
        elif idx_blob:
            fail = f"{f}: staged-удаление — файл остался в индексе"; break
        continue
    if not os.path.lexists(f):
        fail = f"{f}: нет в worktree после apply"; break
    wblob = git("hash-object", "--", f).stdout.decode().strip()
    sblob = git("rev-parse", f"{oid}:{f}").stdout.decode().strip()
    if wblob != sblob:
        fail = f"{f}: блоб worktree != блоб стэша"; break
    st_mode = git("ls-tree", oid, "--", f).stdout.decode().split()[0]
    if os.path.islink(f):
        w_mode = "120000"
    elif os.stat(f).st_mode & stat.S_IXUSR:
        w_mode = "100755"
    else:
        w_mode = "100644"
    if st_mode != w_mode:
        fail = f"{f}: режим {w_mode} != {st_mode} в стэше"; break
    staged = git("ls-files", "-s", "--", f).stdout.decode().split()
    idx_blob = staged[1] if staged else ""
    stash_idx = git("rev-parse", f"{oid}^2:{f}", check=False)
    stash_idx_blob = stash_idx.stdout.decode().strip() if stash_idx.returncode == 0 else ""
    if stash_idx_blob and idx_blob != stash_idx_blob:
        fail = f"{f}: staged-блоб != index-коммит стэша"; break
if fail:
    print(fail, file=sys.stderr)
    raise SystemExit(1)
VERIFY_EOF
  then
    log "stash apply прошёл, но полная сверка содержимого не подтвердилась (OID $STASH_OID) — запись СОХРАНЕНА, проверьте вручную: git stash show -p $STASH_OID"
    return 1
  fi
  # apply чист и проверен — удаляем именно нашу запись: индекс ищем по OID
  # внутри той же критической секции, конкурентный stash снаружи сдвинуть его
  # не может.
  local selector
  selector=$(git stash list --format='%H %gd' | awk -v oid="$STASH_OID" '$1==oid {print $2; exit}')
  if [ -n "$selector" ]; then
    git stash drop "$selector" >/dev/null 2>&1 || log "stash drop $selector не удался — запись $STASH_OID осталась, удалите вручную"
  else
    log "запись $STASH_OID не найдена в stash list после apply — уже удалена? проверить git stash list"
  fi
  STASH_OID=""
  return 0
}

acquire() {
  cd "$REPO_DIR" || { log "не удалось перейти в $REPO_DIR — окружение не настроено, эскалирую"; exit 2; }

  local_barrier

  own_stash_lock
  own_stash_push || { log "не удалось спрятать локальные изменения — эскалирую"; exit 2; }
  if ! git pull --rebase; then
    log "git pull failed — не рискуем работать на устаревшей истории"
    [ -n "$STASH_OID" ] && log "локальные изменения остались в stash (OID $STASH_OID): git stash show -p $STASH_OID"
    exit 2
  fi
  own_stash_apply || exit 2

  local state
  state=$(check_today_history)
  if [ "$state" = "closed" ]; then
    local closed_at
    closed_at=$(git log HEAD --since="$(date +%Y-%m-%d) 00:00" --grep="day-close: $(date +%Y-%m-%d)" --format="%cd" --date=format:%H:%M | head -1)
    log "Механическая часть дня уже закрыта (маркер ${closed_at:-неизвестно}) — разговорная часть (рефлексия, приоритеты) отдельно, проверить наличие секции «Итоги дня». Повторный автоматический прогон не нужен."
    exit 1
  fi
  if [[ "$state" == start:* ]]; then
    local age="${state#start:}"
    if [ "$age" -lt "$TTL_SECONDS" ]; then
      log "Кто-то уже закрывает день прямо сейчас (маркер моложе ${TTL_SECONDS}s, возраст ${age}s) — выхожу"
      exit 3
    fi
    log "Найден протухший day-close-start (возраст ${age}s ≥ ${TTL_SECONDS}s) — считаю осиротевшим, продолжаю"
  fi

  local who today branch
  who="${IWE_AGENT:-$(whoami)}@$(hostname -s)"
  today=$(date +%Y-%m-%d)
  branch=$(git rev-parse --abbrev-ref HEAD)
  create_start_marker "$who" "$today" || { log "Не удалось создать маркер-коммит — эскалирую"; exit 2; }

  if git push; then
    log "Lock acquired: day-close-start: ${today} by ${who}"
    return 0
  fi

  # Push отклонён. Проверяем origin/<branch> НАПРЯМУЮ через fetch, БЕЗ rebase: если сначала
  # перебазировать свой маркер, он сам станет "самым свежим" в логе и замаскирует реальную
  # причину reject'а (в т.ч. посторонний, не связанный с day-close коммит) — см. заголовок файла.
  git fetch origin "$branch" || abort_after_marker 2 "git fetch после reject не удался — эскалирую"

  state=$(check_today_history "origin/$branch")
  if [ "$state" = "closed" ] || { [[ "$state" == start:* ]] && [ "${state#start:}" -lt "$TTL_SECONDS" ]; }; then
    abort_after_marker 3 "После reject подтверждено: день уже закрывается/закрыт кем-то другим на origin — выхожу"
  fi

  # На origin нет конкурента — reject был вызван чем-то посторонним. Безопасно перебазировать
  # свой маркер поверх актуального origin и повторить push. Стэш-цикл — под тем же
  # flock (fd 9 открыт в acquire): push/pull/apply сериализованы от начала до конца.
  own_stash_push || abort_after_marker 2 "не удалось спрятать локальные изменения перед rebase — эскалирую"
  if ! git rebase "origin/$branch"; then
    abort_after_marker 2 "rebase после fetch не удался — эскалирую (стэш ${STASH_OID:-нет} сохранён)"
  fi
  own_stash_apply || abort_after_marker 2 "конфликт возврата стэша после rebase — запись сохранена, см. лог выше"
  git push || abort_after_marker 2 "Повторный push не удался — эскалирую"
  log "Lock acquired на втором заходе: day-close-start: ${today} by ${who}"
}

case "${1:-}" in
  acquire) acquire ;;
  *) echo "Usage: $0 acquire" >&2; exit 2 ;;
esac
