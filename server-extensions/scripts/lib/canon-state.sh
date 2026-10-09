#!/usr/bin/env bash
# routing: utility  deterministic=true
# canon-state.sh — единая классификация "грязного" чекаута.
#
# WP-538/545 (09.10.2026, пир-сессия Claude+Kimi+Codex + анализ Fable): до
# этого файла три места (git-dirty-guard.sh, tsekh1-git-sync.sh, session-
# guard.sh --isolate) независимо считали "сколько файлов не сведено" каждое
# своим способом и печатали голое число без хоста, без разбивки на классы и
# без привязки к известному, уже не раз документированному инциденту. Разные
# сессии на разных хостах видели разные числа в разные моменты и сообщали их
# пилоту как будто это новая, не связанная между собой находка.
#
# canon_state <repo_path> печатает один and тот же паспорт состояния отовсюду,
# откуда его вызовут: хост, инцидент (если застой старше порога
# git-dirty-guard.sh — тот же маркер $GIT_DIR/dirty-guard-chronic-since,
# не новый), и разбивку путей на классы:
#   mirror     — содержимое побайтно равно origin (зеркало/фантом, ничего не
#                потеряется)
#   automation — путь в allowlist известной прямой автоматики
#                (scripts/automation-contract.conf), содержимое отличается от
#                origin, но это не чья-то ручная работа
#   real       — всё остальное: кандидат на настоящую незакоммиченную работу
#
# Это read-only классификация. Она ничего не коммитит, не стейджит и не
# трогает дерево — только печатает отчёт для текста предупреждений.
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]}"; case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR=. ;; esac; case "$SCRIPT_DIR" in /*) ;; *) SCRIPT_DIR="./$SCRIPT_DIR" ;; esac; SCRIPT_DIR=$(cd "$SCRIPT_DIR" >/dev/null 2>&1 && pwd && printf x); SCRIPT_DIR="${SCRIPT_DIR%x}"; SCRIPT_DIR="${SCRIPT_DIR%$'\n'}"

# Известные владельцы хронического инцидента по имени репозитория — не код,
# а справочная подпись к incident_id. Отдельный файл (не хардкод), чтобы
# смена владельца не требовала правки защищённого скрипта (S-33).
OWNERS_CONF="$SCRIPT_DIR/canon-state-owners.conf"

canon_state_owner() {
  local repo="$1"
  [ -r "$OWNERS_CONF" ] || { echo "неизвестен"; return 0; }
  awk -F'\t' -v r="$repo" '$1 == r { print $2; found=1; exit } END { if (!found) print "неизвестен" }' "$OWNERS_CONF"
}

# canon_state_path_class <path> <automation_contract_file> -- "mirror" | "queue" | "automation" | "real"
# Решение в этом порядке: сперва содержимое (мирор побеждает список путей —
# если файл реально равен origin, не важно, кто его туда положил), потом
# известный формат служебной очереди раннера (session-guard.sh, паттерн
# "inbox/agent/tasks/RUN-*.md" — RUN-[A-Za-z0-9._-]+\.md, тот же, что сам
# session-guard.sh уже распознаёт и исключает в изолированных копиях), потом
# allowlist известной автоматики, иначе "real".
canon_state_path_class() {
  local path="$1" remote_ref="$2" contract_file="$3"
  local worktree_blob remote_blob
  if [ -f "$path" ]; then
    worktree_blob=$(git hash-object "$path" 2>/dev/null || echo "")
  else
    worktree_blob=""
  fi
  remote_blob=$(git rev-parse "${remote_ref}:${path}" 2>/dev/null || echo "")
  if [ -n "$worktree_blob" ] && [ -n "$remote_blob" ] && [ "$worktree_blob" = "$remote_blob" ]; then
    echo "mirror"
    return 0
  fi

  case "$path" in
    inbox/agent/tasks/RUN-*.md) echo "queue"; return 0 ;;
  esac

  if [ -r "$contract_file" ]; then
    local globs glob
    while IFS=$'\t' read -r _name _caller globs; do
      case "$globs" in \#*|"") continue ;; esac
      IFS=',' read -r -a _glob_arr <<<"$globs"
      for glob in "${_glob_arr[@]}"; do
        case "$path" in
          $glob) echo "automation"; return 0 ;;
        esac
      done
    done < "$contract_file"
  fi

  echo "real"
}

# canon_state <repo_path> -- печатает паспорт в stdout, построчно (machine-readable,
# "ключ: значение"), плюс одну готовую человекочитаемую строку в конце
# (CANON_STATE_HUMAN) для прямой вставки в текст предупреждений.
canon_state() {
  local repo_path="$1"
  git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "canon_state: $repo_path is not a git repo" >&2
    return 2
  }

  local host repo_name git_dir branch remote_ref
  host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")
  repo_name=$(basename "$(git -C "$repo_path" rev-parse --show-toplevel)")
  git_dir=$(git -C "$repo_path" rev-parse --absolute-git-dir)
  branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  remote_ref="origin/${branch}"

  local chronic_file="$git_dir/dirty-guard-chronic-since"
  local incident_id="none" age_h=0 dirty_since=""
  if dirty_since=$(cat "$chronic_file" 2>/dev/null) && [ -n "$dirty_since" ] && [ "$dirty_since" -eq "$dirty_since" ] 2>/dev/null; then
    local now; now=$(date +%s)
    age_h=$(( (now - dirty_since) / 3600 ))
    incident_id="${host}/${repo_name}/chronic-${dirty_since}"
  fi

  local contract_file="$SCRIPT_DIR/../automation-contract.conf"
  local mirror=0 queue=0 automation=0 real=0 real_paths=()
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$(canon_state_path_class "$path" "$remote_ref" "$contract_file")" in
      mirror) mirror=$((mirror + 1)) ;;
      queue) queue=$((queue + 1)) ;;
      automation) automation=$((automation + 1)) ;;
      real) real=$((real + 1)); real_paths+=("$path") ;;
    esac
  done < <(
    {
      git -C "$repo_path" diff --cached --name-only 2>/dev/null
      git -C "$repo_path" diff --name-only 2>/dev/null
      git -C "$repo_path" ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
  )

  local total=$((mirror + queue + automation + real))
  local owner; owner=$(canon_state_owner "$repo_name")

  cat <<EOF
host: $host
repo: $repo_name
branch: $branch
incident_id: $incident_id
age_h: $age_h
owner: $owner
paths_total: $total
paths_mirror: $mirror
paths_queue: $queue
paths_automation: $automation
paths_real: $real
real_paths: ${real_paths[*]:-}
EOF

  local human
  if [ "$incident_id" = "none" ]; then
    human="${host}/${repo_name}: $total путей, застой не хронический (моложе порога), настоящей незакоммиченной работы похоже $real"
  else
    human="${host}/${repo_name}: известный инцидент ($age_h ч, владелец $owner) — $total путей (из них $mirror зеркал/фантомов, $queue служебных карточек очереди, $automation от других автоматизаций, $real похожи на настоящую работу)"
  fi
  echo "CANON_STATE_HUMAN: $human"
}

CANON_STATE_LIB_READY=1
