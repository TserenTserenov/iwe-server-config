#!/usr/bin/env bash
# session-guard.sh — единый gate open/close/audit для всех агентов (Claude, Kimi, Hermes)
# see WP-398 Ф5, AGENTS.md (WP Gate — CRITICAL), protocol-open.md
#
# Инвариант: любая сессия с изменениями файлов должна пройти open → ORZ → commit → close.
# Mechanical enforcement: git pre-commit hook проверяет наличие активного семафора.
#
# Команды:
#   open --wp WP-N [--task "..."] [--files "a,b"] [--slug "..."] [--agent claude-code|kimi|hermes]
#   close [--wp WP-N] [--slug "..."] [--agent ...]
#   audit [--since YYYY-MM-DD]
#   pre-commit-check
#   note-file <path> [--agent ...]
#
# Exit codes:
#   0 — OK
#   1 — общая ошибка
#   2 — open без wp
#   3 — close без предшествующего open
#   4 — git pre-commit блок (семафор не найден)
#   5 — ORZ не прошёл валидацию
#   6 — scope gate block (staged файл вне активных сессий)

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
OPEN_LOG="$IWE_ROOT/DS-my-strategy/inbox/open-sessions.log"
ORZ_DIR="$IWE_ROOT/DS-my-strategy/sessions"
AGENT_STATUS_SCRIPT="$IWE_ROOT/scripts/agent-status-report.sh"
mkdir -p "$SESSION_DIR" "$(dirname "$OPEN_LOG")" "$ORZ_DIR"

CMD="${1:-}"
shift || true

# --- helpers ---
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_date() { date +"%Y-%m-%d"; }
fail() { echo "session-guard: $1" >&2; exit "${2:-1}"; }
orz_agent_name() {
  case "$1" in
    kimi) echo "kimi-headless" ;;
    *)    echo "$1" ;;
  esac
}

# --- parse args ---
WP=""
TASK=""
FILES=""
SLUG=""
AGENT="${IWE_AGENT:-}"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)     WP="$2"; shift 2 ;;
    --task)   TASK="$2"; shift 2 ;;
    --files)  FILES="$2"; shift 2 ;;
    --slug|--topic) SLUG="$2"; shift 2 ;;
    --agent)  AGENT="$2"; shift 2 ;;
    --since)  SINCE="$2"; shift 2 ;;
    --)       shift; POSITIONAL+=("$@"); break ;;
    -*)       shift ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$AGENT" ] && { [ "$CMD" = "open" ] || [ "$CMD" = "close" ]; }; then
  fail "--agent обязателен для open/close (или переменная IWE_AGENT)" 1
fi

# --- OPEN ---
if [ "$CMD" = "open" ]; then
  [ -z "$WP" ] && fail "--wp обязателен для open" 2

  # Auto-orphan stale semaphore from same agent (TTL 30 min)
  STALE=$(ls -t "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null | head -1 || true)
  if [ -n "$STALE" ] && [ -f "$STALE" ]; then
    STALE_MTIME=$(stat -f %m "$STALE" 2>/dev/null || stat -c %Y "$STALE" 2>/dev/null || echo "")
    if [ -n "$STALE_MTIME" ]; then
      STALE_AGE=$(( $(date +%s) - STALE_MTIME ))
      if [ "$STALE_AGE" -gt 1800 ]; then
        STALE_WP=$(grep "^wp: " "$STALE" | cut -d' ' -f2- || echo "unknown")
        mv "$STALE" "${STALE}.orphaned-${STALE_WP}"
        echo "WARNING: orphaned semaphore ($(basename "$STALE")) переименован (WP: $STALE_WP, возраст ${STALE_AGE}s)" >&2
      fi
    fi
  fi

  SESSION_ID="${IWE_SESSION_ID:-$(date +%s)}"
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
  {
    echo "---"
    echo "agent: $AGENT"
    echo "wp: $WP"
    echo "task: ${TASK:-}"
    echo "slug: ${SLUG:-$WP}"
    echo "opened_at: $(now_iso)"
    echo "session_id: $SESSION_ID"
    echo "---"
    # initial --files CSV → append-log entries (git-root-relative expected from caller)
    if [ -n "${FILES:-}" ]; then
      IFS=',' read -ra INITIAL_FILES <<< "$FILES"
      for init_file in "${INITIAL_FILES[@]}"; do
        init_file="$(echo "$init_file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$init_file" ] && echo "file: $init_file"
      done
    fi
  } > "$SEM_FILE"
  # Pointer to active semaphore for PostToolUse hooks
  PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
  echo "$SEM_FILE" > "$PTR_FILE"
  # ORZ scaffold
  ORZ_BASENAME="$(now_date)-${SLUG:-$WP}.md"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"
  if [ ! -f "$ORZ_FILE" ]; then
    cat > "$ORZ_FILE" <<EOF
---
date: $(now_date)
type: work
wp: ${WP}
duration_h: ~
agent: $(orz_agent_name "$AGENT")
artifacts: []
---

# Сессия $(now_date) — ${TASK:-$WP}

## Главный инсайт

## Контекст

## Достигнуто

| Артефакт | Описание |
|----------|----------|

## Ключевые решения

## Следующий шаг

EOF
    echo "ORZ scaffold создан: $ORZ_FILE"
  fi
  # open-sessions.log
  printf "%s | %s | %s | %s\n" "$(date '+%Y-%m-%d %H:%M')" "$WP" "$AGENT" "${TASK:-standalone}" >> "$OPEN_LOG"
  # agent status (fail-safe)
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" "$AGENT" working "${WP}: ${TASK:-standalone}" "${FILES:-}" 2>/dev/null || true
  fi
  echo "Session OPEN: $SEM_FILE (WP: $WP, agent: $AGENT, slug: ${SLUG:-$WP})"
  exit 0
fi

# --- helpers for ORZ validation ---
validate_orz() {
  local orz="$1"
  local agent="$2"
  local errors=0

  # 1. file exists
  if [ ! -f "$orz" ]; then
    echo "  ❌ ORZ-файл не найден: $orz" >&2
    return 1
  fi

  # 2. frontmatter keys
  local keys=("date:" "type:" "wp:" "duration_h:" "artifacts:" "agent:")
  for key in "${keys[@]}"; do
    if ! grep -qE "^${key}" "$orz"; then
      echo "  ❌ в frontmatter отсутствует ключ '$key'" >&2
      errors=$((errors + 1))
    fi
  done

  # 3. agent value
  local orz_agent
  orz_agent=$(grep -E "^agent:" "$orz" | sed 's/^agent: *//' | head -1 || true)
  if [ -n "$orz_agent" ]; then
    if [ "$orz_agent" != "$agent" ] && \
       ! { [ "$agent" = "kimi" ] && [ "$orz_agent" = "kimi-headless" ]; }; then
      echo "  ❌ agent в ORZ ('$orz_agent') не совпадает с агентом сессии ('$agent')" >&2
      errors=$((errors + 1))
    fi
  fi

  # 4. required sections
  local sections=("## Главный инсайт" "## Контекст" "## Достигнуто" "## Ключевые решения")
  for sec in "${sections[@]}"; do
    if ! grep -qF "$sec" "$orz"; then
      echo "  ❌ отсутствует секция '$sec'" >&2
      errors=$((errors + 1))
    fi
  done

  # 5. git tracked
  local rel="$(basename "$orz")"
  if ! git -C "$ORZ_DIR" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    echo "  ❌ ORZ-файл не добавлен в git index (git add $rel)" >&2
    errors=$((errors + 1))
  fi

  return $errors
}

# --- CLOSE ---
if [ "$CMD" = "close" ]; then
  SEM_FILE=$(ls -t "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null | head -1 || true)
  if [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
    fail "close без open: семафор не найден для $AGENT. Сначала session-guard.sh open --wp WP-N" 3
  fi
  WP_FROM_SEM=$(grep "^wp: " "$SEM_FILE" | cut -d' ' -f2- || true)
  WP="${WP:-$WP_FROM_SEM}"
  SLUG_FROM_SEM=$(grep "^slug: " "$SEM_FILE" | cut -d' ' -f2- || true)
  SLUG="${SLUG:-$SLUG_FROM_SEM}"
  TASK_FROM_SEM=$(grep "^task: " "$SEM_FILE" | cut -d' ' -f2- || true)
  TASK="${TASK:-$TASK_FROM_SEM}"
  SESSION_ID=$(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo "unknown")

  ORZ_BASENAME="$(now_date)-${SLUG:-$WP}.md"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"

  echo "Session CLOSE: проверяю ORZ $ORZ_FILE ..."
  if ! validate_orz "$ORZ_FILE" "$AGENT"; then
    fail "ORZ не прошёл валидацию. Исправь замечания выше и повтори close. Семафор остаётся активным." 5
  fi

  # agent status idle
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" "$AGENT" idle "" "" 2>/dev/null || true
  fi
  mv "$SEM_FILE" "$SEM_FILE.closed" 2>/dev/null || rm -f "$SEM_FILE"
  # Remove agent pointer
  rm -f "$SESSION_DIR/current-${AGENT}.ptr"
  echo "Session CLOSE: $WP → $ORZ_FILE ✅"
  exit 0
fi

# --- NOTE-FILE (manual scope registration for Bash-created/deleted files) ---
if [ "$CMD" = "note-file" ]; then
  FILE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FILE_PATH" ] && fail "note-file: missing path argument" 1
  NOTE_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  PTR_FILE="$SESSION_DIR/current-${NOTE_AGENT}.ptr"
  if [ ! -f "$PTR_FILE" ]; then
    fail "note-file: no active semaphore pointer for agent '$NOTE_AGENT'" 1
  fi
  SEM_FILE=$(cat "$PTR_FILE" 2>/dev/null)
  if [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
    fail "note-file: active semaphore not found" 1
  fi
  # Normalize to git-root-relative (resolve symlinks/macOS /tmp vs /private/tmp)
  if [ -f "$FILE_PATH" ] || [ -d "$FILE_PATH" ]; then
    REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || true)
  else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  fi
  if [ -n "$REPO_ROOT" ]; then
    REL_PATH=$(python3 -c "
import os,sys
f = os.path.realpath(sys.argv[2])
r = os.path.realpath(sys.argv[3])
print(os.path.relpath(f, r))
" -- "$FILE_PATH" "$REPO_ROOT")
  else
    REL_PATH="$FILE_PATH"
  fi
  [ -n "$REL_PATH" ] || fail "note-file: cannot determine relative path for '$FILE_PATH'" 1
  # Avoid duplicate consecutive entries
  LAST=$(tail -1 "$SEM_FILE" 2>/dev/null || true)
  if [ "$LAST" != "file: $REL_PATH" ]; then
    echo "file: $REL_PATH" >> "$SEM_FILE"
  fi
  echo "Noted in scope: $REL_PATH"
  exit 0
fi

# --- AUDIT ---
if [ "$CMD" = "audit" ]; then
  SINCE="${SINCE:-$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)}"
  echo "=== Session Guard Audit (since $SINCE) ==="
  echo

  # 1. Активные семафоры (open без close)
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -n "$ACTIVE" ]; then
    echo "⚠️ Активные сессии без close:"
    for f in $ACTIVE; do
      echo "  $(basename "$f")"
      sed 's/^/    /' "$f"
    done
    echo
  fi

  # 2. Сессии в open-sessions.log без ORZ-файла
  if [ -f "$OPEN_LOG" ]; then
    echo "Сессии в open-sessions.log без ORZ (после $SINCE):"
    awk -v since="$SINCE" '
      $1 >= since {
        wp=$3; gsub(/\|/,"",wp); print $1, wp
      }
    ' "$OPEN_LOG" | sort -u | while read -r dt wp; do
      ORZ=$(ls "$ORZ_DIR/$dt"-*"$wp"*.md 2>/dev/null | head -1 || true)
      if [ -z "$ORZ" ]; then
        echo "  $dt | $wp | ORZ отсутствует"
      fi
    done
    echo
  fi

  # 3. ORZ-файлы с невалидным frontmatter/секциями
  echo "ORZ-файлы с дефектами (после $SINCE):"
  find "$ORZ_DIR" -maxdepth 1 -name '*.md' -type f ! -name '00-index.md' -newermt "$SINCE" 2>/dev/null | while read -r orz; do
    tmp_errors=$(mktemp)
    orz_agent=$(grep -E "^agent:" "$orz" | sed 's/^agent: *//' | head -1 || true)
    if ! validate_orz "$orz" "${orz_agent:-unknown}" >"$tmp_errors" 2>&1 && [ -s "$tmp_errors" ]; then
      echo "  $(basename "$orz"):"
      sed 's/^/    /' "$tmp_errors"
    fi
    rm -f "$tmp_errors"
  done
  echo

  # 4. Untracked ORZ-файлы
  echo "Незакоммиченные ORZ-файлы:"
  git -C "$ORZ_DIR" status --short . 2>/dev/null | grep '^??' || echo "  (нет)"
  echo

  # 5. Stale семафоры старше 7 дней
  echo "Stale-семафоры старше 7 дней:"
  find "$SESSION_DIR" -name "*.open" -type f -mtime +7 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")"
  done

  echo "=== Audit done ==="
  exit 0
fi

# --- GIT PRE-COMMIT CHECK ---
if [ "$CMD" = "pre-commit-check" ]; then
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -z "$ACTIVE" ]; then
    cat >&2 <<'EOF'
🚫 SESSION-GUARD: коммит заблокирован.

Сессия не открыта по протоколу. Перед работой с файлами:
  bash ~/IWE/scripts/session-guard.sh open --wp WP-N --task "..."

Или, если это emergency-фикс без РП:
  GIT_OPTIONAL_LOCKS=0 git commit --no-verify -m "..."
EOF
    exit 4
  fi

  # Scope gate: every staged file must be touched in at least one active session.
  # Existing/new files: mtime > semaphore mtime.
  # Deleted files: path must be listed in at least one semaphore append-log.
  BLOCKED=0
  SEMAPHORE_MTIMES=()
  for sem in $ACTIVE; do
    SEMAPHORE_MTIMES+=("$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$sem")")
  done

  while IFS= read -r f; do
    [ -z "$f" ] && continue

    if [ ! -e "$f" ]; then
      # Deleted file: check append-log across all active semaphores
      FOUND=0
      for sem in $ACTIVE; do
        if grep -qF "file: $f" "$sem"; then
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" -eq 0 ]; then
        echo "🚫 BLOCK: $f удалён, но не числится в scope активных сессий" >&2
        BLOCKED=1
      fi
      continue
    fi

    # Existing or new file: mtime must be greater than at least one active semaphore
    FILE_MTIME=$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$f")
    PASS=0
    for sem_mtime in "${SEMAPHORE_MTIMES[@]}"; do
      if [ "$FILE_MTIME" -gt "$sem_mtime" ]; then
        PASS=1
        break
      fi
    done
    if [ "$PASS" -eq 0 ]; then
      echo "🚫 BLOCK: $f не тронут в активных сессиях (mtime <= всех семафоров)" >&2
      BLOCKED=1
    fi
  done < <(git diff --cached --name-only)

  if [ "$BLOCKED" -ne 0 ]; then
    echo "" >&2
    echo "Scope gate: staged-файлы вне текущих сессий." >&2
    echo "Если файл относится к сессии, добавь его вручную:" >&2
    echo "  bash ~/IWE/scripts/session-guard.sh note-file <path>" >&2
    echo "Или убери из staged:" >&2
    echo "  git restore --staged <file>" >&2
    exit 6
  fi

  exit 0
fi

fail "Unknown command: $CMD (use: open, close, audit, pre-commit-check)"
