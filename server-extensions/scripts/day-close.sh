#!/bin/bash
# routing: helper  skill=day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# day-close.sh — Автоматические шаги Day Close (backup + reindex + linear sync + sessions)
#
# Вызывается Claude из протокола Day Close (protocol-close.md § День, шаг 4).
# Объединяет четыре механических операции в одну команду.
#
# Использование:
#   day-close.sh                # все четыре шага
#   day-close.sh --backup       # только backup
#   day-close.sh --reindex      # только reindex
#   day-close.sh --linear       # только linear sync
#   day-close.sh --sessions     # только консолидация сессий дня (DAP1-B, WP-7)
#
# Конфигурация: Пути заданы через переменные ниже — настроить при установке.

set -euo pipefail

# === КОНФИГУРАЦИЯ (настроить при установке) ===
# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# iwe-env-bootstrap.sh sets its own $SCRIPT_DIR from its own ${BASH_SOURCE[0]} when
# sourced below, silently overwriting this one -- capture our own full path first
# under a name it can't collide with, for the detached reindex re-exec further down.
DAY_CLOSE_SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
DS_STRATEGY="$WORKSPACE_DIR/$GOVERNANCE_REPO"
# Slug derived from WORKSPACE_DIR (not $HOME) so it matches Claude's project key
# regardless of workspace location. Override via IWE_MEMORY_SRC if needed.
WORKSPACE_SLUG=$(echo "$WORKSPACE_DIR" | tr '/_ ' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${WORKSPACE_SLUG}/memory}"
EXOCORTEX_DST="$DS_STRATEGY/exocortex"
# MCP reindex — опциональный компонент (WP-187 iwe-knowledge Gateway заменяет локальный knowledge-mcp).
# Переопределить путь можно через env IWE_SELECTIVE_REINDEX.
# do_reindex() exit code for "some branches indexed, some failed" (see do_reindex).
readonly RC_REINDEX_PARTIAL=3
SELECTIVE_REINDEX="${IWE_SELECTIVE_REINDEX:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh}"
SOURCES_JSON="${IWE_SOURCES_JSON:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/sources.json}"
SOURCES_PERSONAL_JSON="${IWE_SOURCES_PERSONAL_JSON:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/sources-personal.json}"
# issue #463: linear_sync_path и слияние day-rhythm-config.yaml ниже читаются через
# `python3 -c "import yaml..." 2>/dev/null || echo ""` — без pyyaml это не падает,
# а тихо возвращает пустую строку, неотличимую от «поля нет в конфиге». Один явный
# warning здесь вместо голого ModuleNotFoundError на каждом отдельном вызове.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "⚠ pyyaml не найден — linear sync и merge day-rhythm-config.yaml тихо пропустятся. Установите: pip3 install --user pyyaml" >&2
fi
# Linear sync: путь читается из params.yaml (ключ linear_sync_path)
PARAMS_YAML="$WORKSPACE_DIR/params.yaml"
LINEAR_SYNC=""
if [ -f "$PARAMS_YAML" ]; then
  _raw=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('linear_sync_path',''))" "$PARAMS_YAML" 2>/dev/null || echo "")
  if [ -n "$_raw" ]; then
    LINEAR_SYNC="${_raw/#\~/$HOME}"
  fi
fi
LOG_FILE="${IWE_DAY_CLOSE_LOG:-$HOME/logs/day-close.log}"
# === /КОНФИГУРАЦИЯ ===

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[day-close]${NC} $1"; }
warn() { echo -e "${YELLOW}[day-close]${NC} $1"; }
err() { echo -e "${RED}[day-close]${NC} $1" >&2; }

# --- Шаг 1: Backup memory/ + CLAUDE.md → exocortex/ ---
do_backup() {
  log "Шаг 1/3: Backup memory/ → exocortex/"

  if [ ! -d "$MEMORY_SRC" ]; then
    err "Memory source not found: $MEMORY_SRC"
    return 1
  fi

  mkdir -p "$EXOCORTEX_DST"

  # One-time cleanup: legacy nested directory left over from a deprecated recursive-backup prompt.
  if [ -d "$EXOCORTEX_DST/memory" ]; then
    warn "  Removing legacy nested directory: $EXOCORTEX_DST/memory"
    rm -rf "$EXOCORTEX_DST/memory"
  fi

  # Mirror *.md/*.yaml/*.yml from auto-memory; --delete prunes files removed upstream.
  # CLAUDE.md is excluded so the workspace copy below isn't deleted by --delete.
  # -L (copy-links) dereferences symlinks so target content is copied, not the link —
  # prevents a self-referencing ELOOP symlink from recurring here (WP-7 DOC8).
  # day-rhythm-config.yaml is excluded here and handled separately via merge (see below)
  # to preserve user-configured keys (e.g. calendar_ids) from being overwritten by template defaults.
  # issue #343: --include='*/' must come first — without it the trailing --exclude='*'
  # also excludes directories, so rsync never descends into memory/ subfolders and the
  # backup silently misses e.g. memory/reference/agent-core.md while reporting success.
  # -m goes with it: --include='*/' alone recreates the source's ENTIRE directory tree
  # in the backup, including .git/ internals whose files the final --exclude drops —
  # hundreds of empty dirs plus a fake exocortex/.git. -m prunes the empty ones.
  rsync -aLm --delete \
    --exclude='CLAUDE.md' \
    --exclude='day-rhythm-config.yaml' \
    --include='*/' \
    --include='*.md' --include='*.yaml' --include='*.yml' \
    --exclude='*' \
    "$MEMORY_SRC/" "$EXOCORTEX_DST/"

  # Merge day-rhythm-config.yaml: use auto-memory as base, preserve non-empty user values in dst.
  # User-configurable keys protected: day_open.calendar_ids
  # WP-526 (peer-session 2026-08-31-09): destination moved out of exocortex/
  # (git-ignored but per-worktree) into .iwe-runtime/ (git-ignored, but a single
  # root shared by the canonical checkout and every isolated worktree on this
  # machine) so isolated-worktree day-open runs can actually see it.
  local rhythm_src="$MEMORY_SRC/day-rhythm-config.yaml"
  local rhythm_dst="$IWE_ROOT/.iwe-runtime/day-rhythm-config.yaml"
  mkdir -p "$IWE_ROOT/.iwe-runtime"
  if [ -f "$rhythm_src" ]; then
    if [ ! -f "$rhythm_dst" ]; then
      cp "$rhythm_src" "$rhythm_dst"
    else
      python3 - "$rhythm_src" "$rhythm_dst" << 'PYEOF'
import sys, yaml

src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path) as f:
    src_data = yaml.safe_load(f) or {}
with open(dst_path) as f:
    dst_data = yaml.safe_load(f) or {}

merged = dict(src_data)

# Preserve non-empty user values from dst (L4 config, user-editable keys)
USER_KEYS = [("day_open", "calendar_ids")]
for section, key in USER_KEYS:
    dst_val = dst_data.get(section, {}).get(key)
    if dst_val:  # preserve non-empty dst value over template default
        merged.setdefault(section, {})[key] = dst_val

with open(dst_path, "w") as f:
    yaml.dump(merged, f, default_flow_style=False, allow_unicode=True)
PYEOF
    fi
  fi

  # Cross-machine delivery to tsekh-1 (WP-526 "Осталось" 31.08): .iwe-runtime/ вне git
  # по дизайну (см. комментарий выше), поэтому git-доставка невозможна — пушим
  # файл напрямую по SSH. Best-effort и атомарно: недоступность tsekh-1 или обрыв
  # связи не роняет Day Close и не оставляет там частично записанный файл.
  # Направление всегда Мак -> tsekh-1 (hostname-гвард не даёт tsekh-1 пушить самому
  # себе, если Day Close когда-нибудь выполнится там же).
  #
  # Собственность (закрыто 31.08, РП-526): Мак — единственный источник истины для
  # этого файла. Проверено: на tsekh-1 do_backup() (и вся эта функция) НИКОГДА не
  # запускается сама по себе — там стоит только сторож-таймер
  # iwe-day-close-watchdog.timer, который лишь ПРОВЕРЯЕТ, что Day Close прошёл на
  # Маке (dead man's switch, тревога при отсутствии), не запускает его локально.
  # Значит tsekh-1 физически не может независимо изменить свою копию —
  # hostname-гвард ниже уже достаточная защита, конфликта версий не бывает.
  if [ -f "$rhythm_dst" ] && [ "$(hostname -s)" != "tsekh-1" ]; then
    if python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$rhythm_dst" 2>/dev/null; then
      local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
      local this_host
      this_host="$(hostname -s)"
      local remote_tmp=".iwe-runtime/.day-rhythm-config.yaml.tmp.${this_host}.$$"
      if ssh "${ssh_opts[@]}" tsekh-1 "mkdir -p ~/IWE/.iwe-runtime" >/dev/null 2>&1 \
        && scp -q "${ssh_opts[@]}" "$rhythm_dst" "tsekh-1:~/IWE/$remote_tmp" 2>/dev/null \
        && ssh "${ssh_opts[@]}" tsekh-1 "test -s ~/IWE/$remote_tmp && mv -f ~/IWE/$remote_tmp ~/IWE/.iwe-runtime/day-rhythm-config.yaml"; then
        log "  day-rhythm-config.yaml доставлен на tsekh-1"
      else
        warn "  доставка day-rhythm-config.yaml на tsekh-1 не удалась (не блокирует Day Close)"
        ssh "${ssh_opts[@]}" tsekh-1 "rm -f ~/IWE/$remote_tmp" >/dev/null 2>&1 || true
      fi
    else
      warn "  day-rhythm-config.yaml не прошёл YAML-валидацию — доставка на tsekh-1 пропущена"
    fi
  fi

  # issue #217: обратная подстановка $HOME -> {{HOME_DIR}} делает бэкап ОС-агностичным
  # (симметрично прямой подстановке в setup.sh и restore-from-exocortex.sh).
  if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    sed "s|$HOME|{{HOME_DIR}}|g" "$WORKSPACE_DIR/CLAUDE.md" > "$EXOCORTEX_DST/CLAUDE.md"
  fi

  if [ -f "$WORKSPACE_DIR/AGENTS.md" ]; then
    sed "s|$HOME|{{HOME_DIR}}|g" "$WORKSPACE_DIR/AGENTS.md" > "$EXOCORTEX_DST/AGENTS.md"
  fi

  local count
  count=$(find "$EXOCORTEX_DST" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) | wc -l | tr -d ' ')
  log "  Синхронизировано: $count файлов → $EXOCORTEX_DST/"
}

# iwe_repo_dirs — печатает поддиректории с .git, дедуплицированные по реальному
# физическому пути (repo-symlink алиас иначе считается отдельным репозиторием
# наравне с оригиналом — двойной reindex одного источника, найдено 2026-07-17).
iwe_repo_dirs() {
  local repo real seen=""
  for repo in "$@"; do
    [ -d "$repo/.git" ] || continue
    real=$(cd -P "$repo" 2>/dev/null && pwd) || continue
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$repo"
  done
}

# --- Шаг 2: Knowledge-MCP reindex ---
do_reindex() {
  log "Шаг 2/3: Knowledge-MCP reindex"

  if [ ! -x "$SELECTIVE_REINDEX" ]; then
    warn "  selective-reindex.sh не найден: $SELECTIVE_REINDEX — пропуск"
    return 0
  fi

  # Маппинг dir→source+config из L2 (sources.json) и L4 (sources-personal.json)
  # Python резолвит path→git-root, чтобы связать dirname репо с source-именем.
  local dir_map
  dir_map=$(python3 - "$SOURCES_JSON" "$SOURCES_PERSONAL_JSON" << 'PYEOF'
import sys, json, os
for config_path in sys.argv[1:]:
    if not os.path.exists(config_path):
        continue
    for s in json.load(open(config_path)):
        resolved = os.path.expanduser(s["path"])
        while not os.path.isdir(os.path.join(resolved, ".git")) and resolved != "/":
            resolved = os.path.dirname(resolved)
        if resolved == "/":
            continue
        print(f"{os.path.basename(resolved)}\t{s['source']}\t{config_path}")
PYEOF
  ) || { warn "  Mapping build failed — пропуск reindex"; return 0; }

  # Определяем, какие Pack/DS были изменены сегодня
  local l2_sources="" l4_sources=""
  while IFS= read -r repo; do
    local repo_name
    repo_name=$(basename "$repo")
    local today_commits
    today_commits=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    if [ "$today_commits" -gt 0 ]; then
      local match
      match=$(echo "$dir_map" | awk -F'\t' -v d="$repo_name" '$1==d {print $2"\t"$3; exit}')
      if [ -n "$match" ]; then
        local src cfg
        src=$(echo "$match" | cut -f1)
        cfg=$(echo "$match" | cut -f2)
        if [ "$cfg" = "$SOURCES_JSON" ]; then
          l2_sources="$l2_sources $src"
        else
          l4_sources="$l4_sources $src"
        fi
      else
        log "  ⚠ $repo_name: не в sources — пропуск"
      fi
    fi
  done < <(iwe_repo_dirs "$WORKSPACE_DIR"/PACK-* "$WORKSPACE_DIR"/DS-*)

  if [ -z "$l2_sources" ] && [ -z "$l4_sources" ]; then
    log "  Нет изменений в индексируемых источниках — пропуск reindex"
    return 0
  fi

  # WP-484 30.07 (peer-session with Codex, Ф27-2): selective-reindex.sh used to
  # always exit 0 even when every source failed (silently `continue`d past
  # ingest.ts errors) — under this script's `set -e`, a real non-zero exit from
  # either call below would now abort do_reindex() before Шаг 3 (Linear sync)
  # ever runs, turning one failed source into a fully skipped Day Close instead
  # of the honest "this step degraded, the rest still ran" CONCEPT §5 pattern
  # the rest of the pipeline follows. `|| reindex_had_failures=true` catches it
  # without stopping the script; the caller (protocol-close.md) already reads
  # do_reindex()'s own return value via $reindex_status further down.
  # Count branches so a partial outage stays distinguishable from a total one:
  # day-close-run.sh:32 blocks the whole Day Close on `reindex=fail`, which is why
  # 31.07 and 01.08 stalled on a failed L4 while L2 had already indexed 3078/2116 docs.
  local l2_rc=0 l4_rc=0 ran=0 failed=0

  # Вызов 1: L2 источники (sources.json — дефолт selective-reindex)
  if [ -n "$l2_sources" ]; then
    log "  L2 источники:$l2_sources"
    ran=$((ran + 1))
    # shellcheck disable=SC2086
    "$SELECTIVE_REINDEX" $l2_sources || l2_rc=$?
    if [ "$l2_rc" -ne 0 ]; then
      failed=$((failed + 1))
      warn "  L2 reindex отказал (код $l2_rc)"
    fi
  fi

  # Вызов 2: L4 источники (sources-personal.json через SOURCES_CONFIG)
  if [ -n "$l4_sources" ]; then
    log "  L4 источники:$l4_sources"
    ran=$((ran + 1))
    # shellcheck disable=SC2086
    SOURCES_CONFIG="$SOURCES_PERSONAL_JSON" "$SELECTIVE_REINDEX" $l4_sources || l4_rc=$?
    if [ "$l4_rc" -ne 0 ]; then
      failed=$((failed + 1))
      warn "  L4 reindex отказал (код $l4_rc)"
    fi
  fi

  if [ "$failed" -eq 0 ]; then
    return 0
  elif [ "$failed" -lt "$ran" ]; then
    warn "  reindex: отказала часть веток ($failed из $ran) — Day Close продолжается"
    return "$RC_REINDEX_PARTIAL"
  else
    return 1
  fi
}

# --- Шаг 3: Linear sync ---
do_linear() {
  log "Шаг 3/3: Linear sync"

  if [ ! -x "$LINEAR_SYNC" ]; then
    warn "  linear-sync.sh не найден: $LINEAR_SYNC — пропуск"
    return 0
  fi

  "$LINEAR_SYNC"
}

# --- Шаг 4: Консолидация сессий дня (DAP1-B, WP-7) ---
do_session_consolidation() {
  log "Шаг 4/4: Консолидация сессий дня"

  local today
  today=$(date +%Y-%m-%d)
  local month_dir
  month_dir=$(date +%Y-%m)
  local sessions_root="${IWE_SESSIONS_ROOT:-$WORKSPACE_DIR/MC-sessions}/$month_dir"  # WP-526 Ф2
  local output_file="$DS_STRATEGY/current/sessions-today.md"

  if [ ! -d "$sessions_root" ]; then
    warn "  Папка sessions/$month_dir не найдена — пропуск"
    return 0
  fi

  # Сканируем meta.yaml для сессий сегодняшнего дня
  local entries=()
  while IFS= read -r meta; do
    local session_dir
    session_dir=$(dirname "$meta")
    local session_id
    session_id=$(basename "$session_dir")

    # Читаем task_id и task_description из meta.yaml (python для YAML)
    local task_id task_desc start_time
    task_id=$(python3 -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
print(d.get('task_id', '') or '')
" 2>/dev/null || echo "")
    task_desc=$(python3 -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
desc = d.get('task_description', '') or ''
print(desc[:80] + ('...' if len(desc) > 80 else ''))
" 2>/dev/null || echo "")
    start_time=$(python3 -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
t = str(d.get('start_time', '') or '')
print(t[11:16] if len(t) >= 16 else '')
" 2>/dev/null || echo "")

    # Только если task_id не пустой — WP-явная сессия
    if [ -n "$task_id" ]; then
      entries+=("| $start_time | $task_id | $task_desc |")
    fi
  done < <(find "$sessions_root" -maxdepth 3 -name "meta.yaml" 2>/dev/null \
    | while IFS= read -r f; do
        # Проверяем дату в meta.yaml
        date_val=$(python3 -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
print(str(d.get('date','') or ''))
" 2>/dev/null || echo "")
        if [ "$date_val" = "$today" ]; then
          echo "$f"
        fi
      done | sort)

  mkdir -p "$(dirname "$output_file")"

  if [ ${#entries[@]} -eq 0 ]; then
    log "  Нет WP-сессий за $today — sessions-today.md не записан"
    return 0
  fi

  {
    echo "<!-- sessions-today: $today — auto-generated by day-close.sh -->"
    echo "## Сессии дня $today"
    echo ""
    echo "| Время | РП | Задача |"
    echo "|-------|----|--------|"
    for e in "${entries[@]}"; do
      echo "$e"
    done
    echo ""
  } > "$output_file"

  log "  Записано ${#entries[@]} сессий → $(basename "$output_file")"
}

# --- Лог ---
# Тайминги по шагам (WP-484 Ф2, тема 2) — сбор данных перед решением о staging-архитектуре
# для ускорения Day Close: нужны реальные числа за несколько дней, не оценка на глаз.
write_log() {
  local date_str
  date_str=$(date "+%Y-%m-%d %H:%M")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$date_str | day-close | backup=$1(${5}s) reindex=$2(${6}s) linear=$3(${7}s) sessions=$4(${8}s)" >> "$LOG_FILE"
}

# --- Main ---
main() {
  local do_all=true
  local run_backup=false
  local run_reindex=false
  local run_linear=false
  local run_sessions=false

  for arg in "$@"; do
    case "$arg" in
      --backup)   run_backup=true; do_all=false ;;
      --reindex)  run_reindex=true; do_all=false ;;
      --linear)   run_linear=true; do_all=false ;;
      --sessions) run_sessions=true; do_all=false ;;
      --help|-h)
        echo "Использование: day-close.sh [--backup] [--reindex] [--linear] [--sessions]"
        echo "  Без аргументов — все четыре шага"
        exit 0
        ;;
      *)
        err "Неизвестный аргумент: $arg"
        exit 1
        ;;
    esac
  done

  if $do_all; then
    run_backup=true
    run_reindex=true
    run_linear=true
    run_sessions=true
  fi

  log "=== Day Close (автоматические шаги) ==="

  local backup_status="skip" reindex_status="skip" linear_status="skip" sessions_status="skip"
  local backup_dur=0 reindex_dur=0 linear_dur=0 sessions_dur=0

  if $run_backup; then
    SECONDS=0
    if do_backup; then backup_status="ok"; else backup_status="fail"; fi
    backup_dur=$SECONDS
  fi

  if $run_reindex && $do_all; then
    # process-runner.py bounds this whole script and kills its process GROUP on
    # timeout (killpg) -- reindex cost scales with how many sources had commits
    # today, so on a busy day it drags backup/linear/sessions down with it even
    # though do_reindex() itself is already best-effort. os.setsid() (no `setsid`
    # binary on macOS) puts the re-exec in its own group, outside that killpg.
    # `--reindex` alone (tests, manual runs) is unaffected -- stays synchronous.
    local reindex_log
    reindex_log="$HOME/logs/day-close-reindex-$(date +%Y-%m-%d).log"
    mkdir -p "$(dirname "$reindex_log")"
    log "  Шаг 2/3: Knowledge-MCP reindex — detached, log: $reindex_log"
    python3 -c '
import os, subprocess, sys
os.setsid()
with open(sys.argv[1], "a") as log:
    subprocess.Popen(["bash", sys.argv[2], "--reindex"], stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
' "$reindex_log" "$DAY_CLOSE_SELF"
    reindex_status="backgrounded"
    reindex_dur=0
  elif $run_reindex; then
    SECONDS=0
    local reindex_rc=0
    do_reindex || reindex_rc=$?
    case "$reindex_rc" in
      0)                     reindex_status="ok" ;;
      "$RC_REINDEX_PARTIAL") reindex_status="partial" ;;
      *)                     reindex_status="fail" ;;
    esac
    reindex_dur=$SECONDS
  fi

  if $run_linear; then
    SECONDS=0
    if do_linear; then linear_status="ok"; else linear_status="fail"; fi
    linear_dur=$SECONDS
  fi

  if $run_sessions; then
    SECONDS=0
    if do_session_consolidation; then sessions_status="ok"; else sessions_status="fail"; fi
    sessions_dur=$SECONDS
  fi

  write_log "$backup_status" "$reindex_status" "$linear_status" "$sessions_status" \
    "$backup_dur" "$reindex_dur" "$linear_dur" "$sessions_dur"

  log "=== Готово ==="
  log "  backup=$backup_status(${backup_dur}s)  reindex=$reindex_status(${reindex_dur}s)  linear=$linear_status(${linear_dur}s)  sessions=$sessions_status(${sessions_dur}s)"
}

main "$@"
