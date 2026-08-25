#!/usr/bin/env bash
# session-guard.sh — единый gate open/close/audit для всех агентов (Claude, Kimi, Hermes)
# see WP-398 Ф5, AGENTS.md (WP Gate — CRITICAL), protocol-open.md
#
# Инвариант: любая сессия с изменениями файлов должна пройти open → ORZ → commit → close.
# Mechanical enforcement: git pre-commit hook проверяет наличие активного семафора.
#
# Команды:
#   open --wp WP-N [--task "..."] [--files "a,b"] [--slug "..."] [--agent claude-code|kimi|hermes] [--personality <unassigned|UUID>] [--owner-pid PID]
#   open --housekeeping <reason> [--agent ...] [--owner-pid PID]
#   close [--wp WP-N] [--slug "..."] [--agent ...]
#   close ... --force-no-reflection "<причина>"       # закрыть без ответа на рефлексию —
#                                                      # только если раннер стоит именно на
#                                                      # blocked-witness-unavailable И push уже
#                                                      # подтверждён (all_pushed: true)
#   close --housekeeping <reason> [--agent ...]       # закрыть housekeeping-сессию
#   audit [--since YYYY-MM-DD] [--cleanup-orphans]
#   renew [--wp WP-N] [--slug "..."] [--agent ...]    # продлить право на коммит
#   pre-commit-check
#   note-file <path> [--agent ...]
#   freeze-canonical <path> [--force]                 # physical OS-level lock (chflags -R uchg
#                                                      # on Darwin), prototype for WP-520 ADR —
#                                                      # refuses if any semaphore for the target
#                                                      # path is still open, unless --force.
#                                                      # NOT yet applied to the live canonical
#                                                      # checkout (~/IWE/DS-my-strategy) — that's
#                                                      # a separate step, gated on: `list_candidates
#                                                      # claude-code` (and the kimi/codex/hermes
#                                                      # equivalents) returning empty for that path,
#                                                      # i.e. all sessions open against it today
#                                                      # have closed. Command tested in isolation
#                                                      # only (peer-session 2026-08-14-09).
#   unfreeze-canonical <path>                          # fail-closed alias, does NOT run chflags
#                                                      # (peer-session 2026-08-14-13-wp520-two-layer-
#                                                      # closing-arch): agent gets only the manual
#                                                      # command to run in their own terminal. Use
#                                                      # request-unfreeze-canonical to log the request.
#   request-unfreeze-canonical <path> --reason "..."   # logs a request with a nonce, never touches
#                                                      # chflags itself -- unfreezing stays a manual
#                                                      # pilot action outside any agent CLI.
#   lock-hot-file <path> [--agent ...]    # WP-7 SessionGitRaceIsolation: короткий
#   unlock-hot-file <path>                # mkdir-замок на файл, который часто
#                                          # коллизирует между параллельными сессиями
#                                          # (DayPlan, активная карточка РП, hypotheses-log,
#                                          # MEMORY.md) — не на всё рабочее дерево
#
# Аренда (WP-484 Ф49): существование сессии и её право разрешать коммит — разные
# вещи. Возраст отзывает только право (по умолчанию 4h, `IWE_SESSION_LEASE_SEC`);
# существование снимает лишь close или доказанная смерть процесса-владельца.
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
# issue #266: hardcoded "DS-my-strategy" broke every template user whose
# governance repo is named "DS-strategy" (the shipped default — see create-wp.sh).
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
# OPEN_LOG stays a stable local path -- 8+ readers across session-guard.sh's
# own repo AND two foreign ones (DS-ai-systems/synchronizer, DS-MCP/
# digital-twin-mcp) still read this exact path; nothing migrates. It is an
# ignored, replaceable projection (inbox/open-sessions.log has been in
# .gitignore since 04.05.2026, commit 01ff6fae3a -- predating this file by
# ~2.5 months; found live 2026-08-18 preparing a since-abandoned migration
# marker, WP-484 peer-session with Codex), not a git-tracked archive with its
# own history to preserve. OPEN_LOG_RUNTIME is the ACTUAL write target and
# sole SSOT for every `open` (including --isolate) from here on -- a plain
# append to $OPEN_LOG dirtied the canonical checkout on every call,
# live-reproduced blocking neighboring `--isolate open`s the same way the
# pre-fix ORZ scaffold did (peer-sessions 2026-08-15-14-isolate-aware-orz-dir
# smoke test, 2026-08-15-17-open-log-runtime-registry design, Codex+Kimi).
# open-log-snapshot.sh (separate script) periodically rebuilds OPEN_LOG as a
# full, atomically-renamed materialization of OPEN_LOG_RUNTIME -- no commit,
# no push, no semaphore; readers are unaffected until/unless they choose to
# migrate off the path.
OPEN_LOG="$IWE_ROOT/$GOV_REPO/inbox/open-sessions.log"
OPEN_LOG_RUNTIME="$IWE_ROOT/.iwe-runtime/open-sessions.log"
ORZ_DIR="$IWE_ROOT/$GOV_REPO/sessions"
AGENT_STATUS_SCRIPT="$IWE_ROOT/scripts/agent-status-report.sh"
# WP-520 находка 28+enforcement (14.08): freeze on the canonical DS-my-strategy
# checkout — new sessions must use an isolated worktree, not open there
# directly. Default-on: unset means the freeze covers $IWE_ROOT/$GOV_REPO.
# `${VAR:-default}` can't tell "unset" from "set to empty string" (peer-session
# 2026-08-14-07-wp520-freeze-enforce, Codex review) — that distinction is the
# only way to offer an explicit one-command unfreeze later
# (IWE_FROZEN_CANONICAL_PATH="") without it silently falling back to the
# default. `${VAR+x}` is the standard bash idiom for "is this var set at all".
#
# WP-484 Ф104 (peer-session 2026-08-16-08-wp484-isolate-push-cherry-pick,
# ArchGate 2026-08-16, DRR-f104-root-freeze-extension.md): the tool THAT
# ENFORCES this freeze lives in $IWE_ROOT itself, which was outside its own
# protection -- live incident: two parallel sessions committed to
# session-guard.sh in the same window, one commit swallowed the other's
# uncommitted work (mis-attribution). $IWE_ROOT joins $IWE_ROOT/$GOV_REPO as
# a second frozen path via the SAME check below (git worktree add still
# reads, never writes, the frozen checkout -- freeze never blocked that,
# see the --isolate carve-out further down). Array, not a second scalar: a
# third platform-shared repo can join the same way later without a new
# check block. IWE_FROZEN_CANONICAL_PATH (singular, existing break-glass)
# still overrides the WHOLE list with exactly what it's set to -- setting
# it to "" still fully unfreezes, same as before this change.
if [ -z "${IWE_FROZEN_CANONICAL_PATH+x}" ]; then
  FROZEN_CANONICAL_PATHS=("$IWE_ROOT/$GOV_REPO" "$IWE_ROOT")
elif [ -n "$IWE_FROZEN_CANONICAL_PATH" ]; then
  FROZEN_CANONICAL_PATHS=("$IWE_FROZEN_CANONICAL_PATH")
else
  FROZEN_CANONICAL_PATHS=()
fi
mkdir -p "$SESSION_DIR" "$(dirname "$OPEN_LOG")" "$(dirname "$OPEN_LOG_RUNTIME")" "$ORZ_DIR"

CMD="${1:-}"
shift || true

# --- helpers ---
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_date() { date +"%Y-%m-%d"; }
now_month() { date +"%Y-%m"; }
fail() { echo "session-guard: $1" >&2; exit "${2:-1}"; }

# normalize_remote_url <url> -- same normalization as commit-push.sh
# (2026-08-12, peer-session close-pipeline-consolidation) so
# SSH form ("git@host:org/repo.git") and HTTPS-with-inline-credentials form
# compare equal regardless of which protocol either checkout was cloned with.
normalize_remote_url() {
  sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]*@##; s#:#/#; s#\.git$##' <<<"$1"
}

# gov_repo_dir -- where `open` should actually write the ORZ scaffold: the
# git worktree this invocation is running from, if it's identifiably the same
# repo as $GOV_REPO (matched by origin remote, or basename for a remote-less
# checkout). Same bug class as commit-push.sh's old $IWE_ROOT/$repo (2026-08-12,
# same peer-session): `open` always wrote ORZ files into the canonical
# $IWE_ROOT/$GOV_REPO checkout even when invoked from a different worktree,
# so a file created there was invisible to that worktree's own `git status`.
#
# NOT an end-run around the freeze check below: this resolves WHERE the
# already-permitted ORZ scaffold write lands, it never decides WHETHER `open`
# is allowed to run. The freeze block runs after this and independently
# blocks/passes regardless of which path gov_repo_dir() returned
# (peer-session 2026-08-14-07-wp520-freeze-enforce, consensus with Codex —
# called out explicitly so a future edit doesn't mistake this resolver for
# a freeze bypass).
# Fail closed onto the canonical path only when identity can't be confirmed,
# not on every worktree caller -- worktree stays the common case here.
gov_repo_dir() {
  local canonical="$IWE_ROOT/$GOV_REPO" candidate candidate_rc=0
  candidate=$(git rev-parse --show-toplevel 2>/dev/null) || candidate_rc=$?
  [ "$candidate_rc" -eq 0 ] && [ -n "$candidate" ] || { echo "$canonical"; return; }
  local candidate_remote candidate_remote_rc=0
  candidate_remote=$(git -C "$candidate" remote get-url origin 2>/dev/null) || candidate_remote_rc=$?
  if [ "$candidate_remote_rc" -eq 0 ] && [ -n "$candidate_remote" ]; then
    local canonical_remote
    canonical_remote=$(git -C "$canonical" remote get-url origin 2>/dev/null || true)
    if [ -n "$canonical_remote" ] \
       && [ "$(normalize_remote_url "$candidate_remote")" = "$(normalize_remote_url "$canonical_remote")" ]; then
      echo "$candidate"
      return
    fi
  elif [ "$candidate_remote_rc" -eq 2 ] && [ "$(basename "$candidate")" = "$GOV_REPO" ]; then
    # rc 2 = git's own "No such remote 'origin'" -- a repo without one by
    # construction. Any other nonzero (corrupt config, permission denied)
    # falls through to canonical instead of trusting basename on a read we
    # couldn't actually make.
    echo "$candidate"
    return
  fi
  echo "$canonical"
}

semaphore_epoch() {
  local semaphore="$1" timestamp=""
  timestamp=$(grep -E '^(opened_at|created_at): ' "$semaphore" | head -1 | cut -d' ' -f2- || true)
  [ -n "$timestamp" ] || return 1
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null \
    || date -u -d "$timestamp" +%s 2>/dev/null
}

# --- Isolation: open --isolate (WP-520 DRR two-layer-closing-arch, peer-session
# 2026-08-14-13, consensus after 5 rounds with Codex) ---
#
# ArchGate 09.08 rejected worktree-per-session for the DayPlan/hypotheses-log
# collision class: measured cost (several seconds on this 20000+-file repo,
# confirmed live again in this same peer-session at 2.47s) was too high for a
# problem confined to ~4 known files, so `lock-hot-file` (point locks, no new
# working tree) won instead. This is a DIFFERENT problem: the canonical
# checkout diverges from origin/main because concurrent sessions write
# ANYWHERE in the tree, not to a small predictable set — you cannot point-
# lock a file you don't know will collide. The same 2.5s cost that lost at
# per-edit frequency (lock-hot-file fires on every edit) is paid once, at
# `open`, not on every write, which is why the same ArchGate reasoning
# doesn't rule this out too (Codex, same peer-session, turn 9).
ISOLATE_LOCK_DIR="$IWE_ROOT/.iwe-runtime/isolate-locks"
ISOLATE_LOCK_TTL_SEC="${IWE_ISOLATE_LOCK_TTL_SEC:-120}"  # generous over the ~2.5s worktree add itself; a crashed holder shouldn't block re-entry for long

# with_isolate_lock <session_id> <callback...> -- single critical-section
# primitive (Codex, turn 3: "не копируем новый примитив в команды... единый
# внутренний with_session_lock, используемый и open, и cleanup"). Reuses the
# mkdir-is-atomic pattern already proven by lock-hot-file above, scoped per
# session_id instead of per hot-file path, so two concurrent re-entries for
# the SAME session_id can't both decide "worktree absent, create one".
with_isolate_lock() {
  local session_id="$1"; shift
  mkdir -p "$ISOLATE_LOCK_DIR"
  local lock_path="$ISOLATE_LOCK_DIR/${session_id}.lockdir"
  local attempt=0
  while ! mkdir "$lock_path" 2>/dev/null; do
    # cold-context review (2026-08-14, this same session): TTL-only reclaim
    # here had a real race -- a stale holder's `rm -rf` right before a THIRD
    # process wins a concurrent `mkdir` in that same window deletes the
    # third process's freshly-taken lock out from under it, leaving two
    # processes both convinced they hold the lock for one session_id
    # (exactly the invariant this primitive exists to prevent). Same fix
    # already proven for session semaphores (sweep_orphaned_semaphores()
    # above): PID liveness first, TTL only as fallback when no PID is
    # recorded -- age alone never triggers a deletion by itself anymore.
    if [ -f "$lock_path/pid" ]; then
      local held_pid
      held_pid=$(cat "$lock_path/pid" 2>/dev/null || echo "")
      if [[ "$held_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$held_pid" 2>/dev/null; then
        rm -rf "$lock_path"
        continue
      fi
    elif [ -f "$lock_path/locked_at" ]; then
      local held_at held_epoch age
      held_at=$(cat "$lock_path/locked_at" 2>/dev/null || echo "")
      held_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$held_at" +%s 2>/dev/null \
        || date -u -d "$held_at" +%s 2>/dev/null || echo 0)
      age=$(( $(date +%s) - held_epoch ))
      if [ "$age" -gt "$ISOLATE_LOCK_TTL_SEC" ]; then
        rm -rf "$lock_path"
        continue
      fi
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 30 ]; then
      fail "with_isolate_lock: сессия '$session_id' заблокирована другим параллельным open --isolate >30с — повтори позже" 1
    fi
    sleep 1
  done
  now_iso > "$lock_path/locked_at"
  echo $$ > "$lock_path/pid"
  "$@"
  local rc=$?
  rm -rf "$lock_path"
  return $rc
}

# validate_isolate_slug <slug> -- reject before it reaches a path or branch
# name, not sanitize silently. Codex turn 3: silent substitution can collapse
# two distinct slugs into the same path; explicit rejection cannot.
validate_isolate_slug() {
  local slug="$1"
  [[ "$slug" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || fail "--isolate: slug '$slug' содержит недопустимые символы (разрешены: буквы, цифры, точка, подчёркивание, дефис) — не может использоваться в пути worktree или имени ветки" 1
}

# isolate_entropy_suffix -- 4 hex chars appended to the `date +%s` second so
# two ISOLATE_SESSION_IDs generated in the same second don't collide. Not
# `date +%s%N` (nanosecond resolution): %N is a GNU date extension, not
# available on every date implementation this script might run under.
# /dev/urandom first (real entropy, no seed-collision risk between two
# processes started close together); $RANDOM as fallback for environments
# where /dev/urandom is unreadable (some sandboxes/containers) -- always
# available inside a bash process, just weaker (WP-530 peer-session
# 2026-08-15-10, Kimi turn 2).
isolate_entropy_suffix() {
  # `... && return` on a zero-exit-but-empty-output pipe (e.g. xxd installed
  # but the read returns nothing) would return an EMPTY suffix here -- the
  # exact collision this function exists to prevent, only silent instead of
  # loud (cold-context review, WP-530 peer-session 2026-08-15-10). Capture
  # and check for non-empty output explicitly instead of trusting exit code.
  local suffix
  if [ -r /dev/urandom ]; then
    suffix=$(head -c 2 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null)
    if [ -n "$suffix" ]; then
      printf '%s' "$suffix"
      return
    fi
  fi
  printf '%04x' "$RANDOM"
}

# --- Lease: право семафора разрешать коммит (WP-484 Ф49, 04.08, пир-сессия с Codex) ---
#
# Семафор несёт две РАЗНЫЕ функции, которые до сих пор были склеены в одном
# состоянии `.open`:
#   А — «сессия существует, не трогай её»;
#   Б — «файлы этой сессии разрешены к коммиту» (scope gate ниже).
# WP-507 (30.07) — брошенный семафор 4.5h раздавал функцию Б чужим файлам.
# Лечили это авто-карантином по возрасту в `open`, но он отнимает функцию А:
# любая сессия старше TTL уезжала в `.orphaned-*`, как только тот же агент
# открывал вторую, и после этого не могла завершить Quick Close (`close`
# выбирает только `*.open`). На диске 155 таких файлов против 293 закрытых
# штатно. Разделение функций снимает конфликт: возраст отзывает только Б.
#
# Аренда живёт в ОТДЕЛЬНОМ файле `<semaphore>.lease`, а не строкой в семафоре:
#   1. append в семафор двигает его mtime, а scope gate сравнивает mtime файлов
#      с mtime семафора — продление аренды молча отзывало бы право у файлов,
#      отредактированных до продления;
#   2. повторные append дают неоднозначность «первая или последняя запись»
#      (sweep_orphaned_semaphores выше читает `head -1`);
#   3. имя файла аренды производно от имени семафора — привязка к конкретной
#      сессии структурная, продлить чужую аренду «заодно» нельзя.
LEASE_SEC="${IWE_SESSION_LEASE_SEC:-14400}"  # 4h; продление — `renew`

lease_deadline_epoch() {
  local semaphore="$1" base_epoch renewed_at renewed_epoch=""
  base_epoch=$(semaphore_epoch "$semaphore") || return 1
  if [ -f "${semaphore}.lease" ]; then
    renewed_at=$(grep '^renewed_at: ' "${semaphore}.lease" | tail -1 | cut -d' ' -f2- || true)
    if [ -n "$renewed_at" ]; then
      renewed_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$renewed_at" +%s 2>/dev/null \
        || date -u -d "$renewed_at" +%s 2>/dev/null || echo "")
    fi
  fi
  if [ -n "$renewed_epoch" ] && [ "$renewed_epoch" -gt "$base_epoch" ]; then
    base_epoch="$renewed_epoch"
  fi
  echo $(( base_epoch + LEASE_SEC ))
}

# Семафор без разбираемой метки времени (до-WP-484 или битый) НЕ получает
# полномочий: именно этот случай независимое ревью 01.08 пометило как риск
# ослабления scope gate, а авто-карантин его не покрывает by design.
lease_valid() {
  local semaphore="$1" deadline
  deadline=$(lease_deadline_epoch "$semaphore") || return 1
  [ "$(date +%s)" -lt "$deadline" ]
}

# WP-484 (2026-08-18-02-wp484-witness-implementation, ArchGate + peer-session
# with Codex): zombie-semaphore registry, separate from card-audit-findings.jsonl
# -- those are externally-actionable findings on FOREIGN cards requiring a
# pilot decision (accept/reject/defer); these are automatic internal state
# transitions of session-guard's own semaphores, with no such decision to make.
ZOMBIE_REGISTRY="$IWE_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
IWE_ZOMBIE_ESCALATE_SEC="${IWE_ZOMBIE_ESCALATE_SEC:-14400}"
IWE_ZOMBIE_CLEANUP_SEC="${IWE_ZOMBIE_CLEANUP_SEC:-86400}"

zombie_registry_has_action() {
  # Idempotency key is the semaphore PATH, not a session identity within it.
  # Safe because the path already embeds session_id, which is
  # epoch-timestamp + entropy suffix (isolate_entropy_suffix) -- practically
  # never reused, so a stale entry from a torn-down old session being
  # reattributed to a brand-new one at the same path is not a realistic
  # collision here (raised in code review, not fixed: the existing
  # anti-collision guarantee already covers this).
  local semaphore="$1" action="$2"
  [[ -f "$ZOMBIE_REGISTRY" ]] || return 1

  python3 - "$ZOMBIE_REGISTRY" "$semaphore" "$action" <<'PY'
import json, sys
path, semaphore, action = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, start=1):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                # Not silently skipped (P4): a corrupt line here is a symptom
                # worth surfacing, but this function's only job is "has this
                # one (semaphore, action) pair been recorded" -- one bad line
                # (e.g. a write torn by a crash) shouldn't make every OTHER
                # semaphore's sweep decision fail closed over it.
                print(
                    f"WARNING: zombie registry line {line_number} is not "
                    "valid JSON, skipping: "
                    f"{path}",
                    file=sys.stderr,
                )
                continue
            if event.get("semaphore") == semaphore and event.get("action") == action:
                raise SystemExit(0)
except FileNotFoundError:
    pass
raise SystemExit(1)
PY
}

append_zombie_event() {
  local reason="$1" semaphore="$2" opened_epoch="$3" age_seconds="$4" action="$5"
  mkdir -p "$(dirname "$ZOMBIE_REGISTRY")"

  # The enclosing orphan-sweep lock makes check-then-append idempotent.
  python3 - "$ZOMBIE_REGISTRY" "$reason" "$semaphore" \
    "$opened_epoch" "$age_seconds" "$action" <<'PY'
import datetime as dt
import json
import sys

path, reason, semaphore, opened_epoch, age_seconds, action = sys.argv[1:]
event = {
    "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "reason": reason,
    "source": "session-guard.sh audit --cleanup-orphans",
    "semaphore": semaphore,
    "opened_epoch": int(opened_epoch),
    "age_seconds": int(age_seconds),
    "action": action,
}
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

notify_zombie_escalation() {
  local semaphore="$1" age_seconds="$2"
  local msg="IWE zombie semaphore: ${semaphore}; owner PID missing/invalid; age=${age_seconds}s"

  # Same fallback pattern as check-wp353-trigger.sh: never let a missing/failing
  # notifier block the quarantine decision itself.
  if command -v iwe-tg >/dev/null 2>&1; then
    iwe-tg "$msg" || echo "WARN: iwe-tg failed, zombie alert only in log: $semaphore" >&2
  else
    echo "INFO: iwe-tg unavailable, zombie alert only in log: $semaphore" >&2
  fi
}

# WP-484 (session-close-hygiene peer-session, 2026-08-20, consensus Claude+
# Codex+Kimi): a semaphore's own quarantine (below) already proves its owner
# is gone -- but the `isolated_worktree:` path it recorded at open time was
# never checked afterward. `close` (see the CLOSING_WORKTREE block further
# down) only removes an isolated worktree after `isolate-push.sh` confirms
# the push -- if that never runs at all (process died, terminal killed, no
# close), the copy sits on disk forever with no second chance. Live-confirmed
# same session: a worktree from a 2-day-old dead-pid-quarantined semaphore
# was still present on disk, unpushed status unknown. This reuses the exact
# same isolate-push.sh path `close` already trusts, not a new deletion
# criterion -- a push failure here leaves the worktree untouched, same as in
# `close`.
_reap_orphaned_worktree() {
  local quarantined_semaphore="$1"
  local worktree_path
  worktree_path=$(grep '^isolated_worktree: ' "$quarantined_semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [ -n "$worktree_path" ] || return 0
  [ -d "$worktree_path" ] || return 0

  local isolate_push_script="$IWE_ROOT/$GOV_REPO/scripts/isolate-push.sh"
  if [ ! -x "$isolate_push_script" ]; then
    echo "WARNING: orphaned worktree $worktree_path — isolate-push.sh not found at $isolate_push_script, left on disk" >&2
    return 0
  fi
  if "$isolate_push_script" "$worktree_path" main; then
    if git -C "$worktree_path" worktree remove "$worktree_path" 2>/dev/null; then
      echo "WARNING: orphaned worktree $worktree_path pushed and removed (owner semaphore quarantined)" >&2
    else
      echo "WARNING: orphaned worktree $worktree_path pushed but removal failed (uncommitted state?) — manual: git worktree remove $worktree_path" >&2
    fi
  else
    echo "WARNING: orphaned worktree $worktree_path push failed (exit $?) — left on disk, same as a live close would" >&2
  fi
}

# A missing PID plus age proves only that the semaphore is stale enough to
# quarantine.  It does not prove that the session finished its delivery
# protocol.  In particular, isolate-push.sh transfers every clean commit in the
# worktree and the caller removes that worktree on success; doing either after an
# age-only decision can publish a partial session and destroy its only local
# recovery copy.  Reuse the same narrow terminal Quick Close outcomes accepted
# by close() below.  An explicit close-obligation cancellation is intentionally
# not enough: it authorizes ending the obligation, not publishing or deleting
# whatever happens to be in the abandoned worktree.
_orphaned_worktree_terminal_outcome_proven() {
  local quarantined_semaphore="$1"
  local worktree_path slug harness_session_id card_dir card card_owner
  worktree_path=$(grep '^isolated_worktree: ' "$quarantined_semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  slug=$(grep '^slug: ' "$quarantined_semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  harness_session_id=$(grep '^harness_session_id: ' "$quarantined_semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [ -n "$worktree_path" ] && [ -d "$worktree_path" ] || return 1
  [[ "$slug" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1

  for card_dir in \
    "$worktree_path/inbox/agent/tasks" \
    "$IWE_ROOT/$GOV_REPO/inbox/agent/tasks"; do
    [ -d "$card_dir" ] || continue
    for card in "$card_dir"/RUN-quick-close-"$slug"*.md; do
      [ -f "$card" ] || continue
      grep -q '^process_id: quick-close$' "$card" || continue
      if [ -n "$harness_session_id" ]; then
        card_owner=$(grep '^owner_session_id: ' "$card" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
        [ "$card_owner" = "$harness_session_id" ] || continue
      elif [ "$card_dir" != "$worktree_path/inbox/agent/tasks" ]; then
        # Without a cross-file session id, a same-slug card from the canonical
        # checkout could belong to a later run.  Only the abandoned worktree's
        # own card is admissible in that legacy/no-owner case.
        continue
      fi
      if grep -q '^status: completed$' "$card"; then
        return 0
      fi
      if grep -q '^status: cancelled$' "$card" \
         && grep -q '^current_step: wp-archive-run$' "$card" \
         && grep -qE '^[[:space:]]*(all_pushed: true|commit_needed: false)$' "$card"; then
        return 0
      fi
    done
  done
  return 1
}

# Verify sub-agent (2026-08-20, post-implementation): the sibling
# sweep_stale_open_log_entries() got with_isolate_lock against concurrent
# `audit --cleanup-orphans` runs (real trigger: kimi-wp-run-scheduled.sh:86,
# unconditional, no collision guard) -- this function, which reaps orphaned
# isolated worktrees via the same trigger, didn't. Confirmed by live test
# (not just code reading): two concurrent isolate-push.sh calls on the same
# worktree don't corrupt data (its own retry logic self-heals: attempt 2
# correctly sees "nothing to push" once attempt 1's push already landed),
# but the SEPARATE `git worktree remove` step right after it does not --
# once one call removes the worktree, the other's retry loop tries to fetch
# from a directory that no longer exists and dies with an ugly
# "Unable to read current working directory" instead of the clean
# "nothing to push" exit. No data loss in either case, but an avoidable
# crash exactly where the sibling function already proved the fix pattern.
sweep_orphaned_semaphores() {
  with_isolate_lock "orphan-semaphore-sweep" _sweep_orphaned_semaphores_body
}

_sweep_orphaned_semaphores_body() {
  local semaphore pid epoch quarantined=0 ambiguous=0
  local zombies_escalated=0 zombies_quarantined=0
  while IFS= read -r semaphore; do
    [ -f "$semaphore" ] || continue
    pid=$(grep '^pid: ' "$semaphore" | head -1 | cut -d' ' -f2- || true)
    # WP-484 code review (2026-08-18, Codex): `pid: 0` matches ^[0-9]+$, and
    # `kill -0 0` sends signal 0 to this shell's own process GROUP, which
    # always succeeds -- a stray "0" in the semaphore (e.g. an unset
    # variable that got written as the literal string) would read as "owner
    # alive" forever and never quarantine. PID 0 is not a valid process ID
    # to check liveness against; require a leading nonzero digit.
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      if ! kill -0 "$pid" 2>/dev/null; then
        mv "$semaphore" "${semaphore}.orphaned-dead-pid"
        echo "WARNING: orphaned semaphore $(basename "$semaphore") quarantined: pid $pid is dead" >&2
        _reap_orphaned_worktree "${semaphore}.orphaned-dead-pid"
        quarantined=$((quarantined + 1))
      fi
      continue
    fi

    # Missing/invalid PID (all Kimi headless semaphores, by construction) is a
    # zombie candidate, never an immediate delete: unlike a dead numeric PID,
    # there is no proof of death here, only absence of proof of life.
    epoch=$(semaphore_epoch "$semaphore" || true)
    [ -n "$epoch" ] || {
      echo "WARNING: semaphore $(basename "$semaphore") has no live pid or parseable timestamp; manual review required" >&2
      ambiguous=$((ambiguous + 1))
      continue
    }
    age=$(( $(date +%s) - epoch ))

    if [ "$age" -ge "$IWE_ZOMBIE_CLEANUP_SEC" ]; then
      if ! zombie_registry_has_action "$semaphore" "quarantined"; then
        append_zombie_event "missing_or_invalid_owner_pid" "$semaphore" \
          "$epoch" "$age" "quarantined"
      fi
      mv "$semaphore" "${semaphore}.orphaned-zombie-no-pid"
      echo "WARNING: quarantined zombie semaphore (missing/invalid owner PID): $(basename "$semaphore")" >&2
      if _orphaned_worktree_terminal_outcome_proven "${semaphore}.orphaned-zombie-no-pid"; then
        _reap_orphaned_worktree "${semaphore}.orphaned-zombie-no-pid"
      else
        echo "WARNING: age-only no-PID quarantine has no proven terminal outcome; isolated worktree left on disk for recover-orphaned/manual review: $(grep '^isolated_worktree: ' "${semaphore}.orphaned-zombie-no-pid" 2>/dev/null | head -1 | cut -d' ' -f2- || echo unknown)" >&2
      fi
      zombies_quarantined=$((zombies_quarantined + 1))
      continue
    fi

    if [ "$age" -ge "$IWE_ZOMBIE_ESCALATE_SEC" ] \
       && ! zombie_registry_has_action "$semaphore" "escalated"; then
      append_zombie_event "missing_or_invalid_owner_pid" "$semaphore" \
        "$epoch" "$age" "escalated"
      notify_zombie_escalation "$semaphore" "$age"
      zombies_escalated=$((zombies_escalated + 1))
    fi

    if [ "$age" -gt 1800 ]; then
      echo "WARNING: semaphore $(basename "$semaphore") is ${age}s old without pid proof; kept for manual review" >&2
      ambiguous=$((ambiguous + 1))
    fi
  done < <(find "$SESSION_DIR" -name '*.open' -type f 2>/dev/null)
  echo "Semaphore sweep: quarantined=$quarantined ambiguous=$ambiguous zombies_escalated=$zombies_escalated zombies_quarantined=$zombies_quarantined"
  # Automatic 24h cleanup requires a periodic external invocation of
  # `session-guard.sh audit --cleanup-orphans`; scheduler configuration is
  # intentionally outside this file.
}

# WP-484 (session-close-hygiene peer-session, 2026-08-20): every `open`
# appends one line to OPEN_LOG_RUNTIME (above), nothing ever removes one --
# `close` never touches this file at all. Unlike a semaphore, a log line
# carries no session_id (format is "date | WP | agent | task", see the
# `open` append site) -- no reliable key exists to delete a SPECIFIC line at
# close time without risking a wrong match against another line sharing the
# same date/WP/agent. Same "zombie candidate, never proven dead" situation
# sweep_orphaned_semaphores() already handles for PID-less semaphores above,
# so this reuses that TTL rather than inventing a second one: age alone
# (IWE_ZOMBIE_CLEANUP_SEC) decides what is dropped when this rebuild runs.
# Code review (2026-08-20) + live tests, two rounds. Round 1: the first
# version wrapped the body below in with_isolate_lock, believing that closed
# the TOCTOU window where `open` appends a line between this function's
# `while read` finishing and its `mv -f`. It didn't -- `open`'s own append
# site (above) never takes that lock, so serializing sweep against ITSELF
# does nothing against a concurrent, unlocked appender. Reproduced live
# (signal-file synced harness): a line appended in the exact read-done ->
# mv window was silently dropped even with the lock in place. Fixed by
# offset-capture instead (below): record the file's byte size before
# reading, tail-append anything the ORIGINAL file grew past that offset
# onto the filtered result before the atomic replace -- needs no lock, works
# whether or not the appender takes one. Round 2: offset-capture alone still
# leaves sweep racing ITSELF -- two concurrent `audit --cleanup-orphans`
# calls (real trigger: kimi-wp-run-scheduled.sh:86 fires this unconditionally
# on every queued WP start, no collision guard around it) can both finish
# their read+filter pass, and whichever's `mv` lands second unconditionally
# overwrites the first's result, silently reviving lines the first sweep
# correctly dropped and losing anything the first sweep's own offset-capture
# had appended. with_isolate_lock IS the right tool for this -- sweep vs
# sweep is exactly the same-operation serialization it exists for; round 1
# only misapplied it to the wrong race (sweep vs append).
sweep_stale_open_log_entries() {
  with_isolate_lock "open-log-sweep" _sweep_stale_open_log_entries_body
}

_sweep_stale_open_log_entries_body() {
  [ -f "$OPEN_LOG_RUNTIME" ] || return 0
  local now_epoch dropped=0 kept=0 orig_size_before orig_size_after
  now_epoch=$(date +%s)
  orig_size_before=$(wc -c < "$OPEN_LOG_RUNTIME" | tr -d ' ')
  local tmp_log
  tmp_log=$(mktemp "${OPEN_LOG_RUNTIME}.tmp.XXXXXX")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local entry_date entry_epoch age
    entry_date=$(echo "$line" | cut -d'|' -f1 | xargs)
    # Live-caught bug (2026-08-20, own multi-process race test): the append
    # site (`date '+%Y-%m-%d %H:%M'`, no -u) writes LOCAL time. Parsing that
    # same string with `-u` here read it as UTC instead -- on a machine
    # ahead of UTC this makes every entry look OLDER than it is (wrong
    # direction: risks dropping fresh sessions), on one behind it makes
    # everything look YOUNGER (risks never cleaning up). No -u here, to
    # match the writer.
    entry_epoch=$(date -j -f "%Y-%m-%d %H:%M" "$entry_date" +%s 2>/dev/null \
      || date -d "$entry_date" +%s 2>/dev/null || echo "")
    if [ -z "$entry_epoch" ]; then
      # Unparseable date: keep, same fail-closed choice as semaphore sweep's
      # "no proof of death" branch -- an unreadable entry is not a proven zombie.
      echo "$line" >> "$tmp_log"
      kept=$((kept + 1))
      continue
    fi
    age=$(( now_epoch - entry_epoch ))
    if [ "$age" -ge "$IWE_ZOMBIE_CLEANUP_SEC" ]; then
      dropped=$((dropped + 1))
    else
      echo "$line" >> "$tmp_log"
      kept=$((kept + 1))
    fi
  done < "$OPEN_LOG_RUNTIME"
  # This is the actual race fix (see the comment above the function) --
  # capture whatever a concurrent, unlocked `open` appended to the ORIGINAL
  # file past the byte offset recorded before we started reading, and
  # reattach it verbatim before the atomic replace.
  orig_size_after=$(wc -c < "$OPEN_LOG_RUNTIME" | tr -d ' ')
  if [ "$orig_size_after" -gt "$orig_size_before" ]; then
    tail -c "+$((orig_size_before + 1))" "$OPEN_LOG_RUNTIME" >> "$tmp_log"
  fi
  mv -f "$tmp_log" "$OPEN_LOG_RUNTIME"
  echo "open-sessions.log sweep: kept=$kept dropped=$dropped (age >= ${IWE_ZOMBIE_CLEANUP_SEC}s)"
}
orz_agent_name() {
  case "$1" in
    kimi) echo "kimi-headless" ;;
    *)    echo "$1" ;;
  esac
}

# WP-464: pick the semaphore matching --wp/--slug among an agent's open
# semaphores. Ambiguous only when 2+ are open and none match — fails loudly
# with the candidate list instead of guessing "newest" (bug-2026-06-23,
# bug-2026-07-03-close-ignores-wp-arg, bug-2026-07-04-ptr-collision).
#
# Return codes (caller must check — this function never calls `exit`: inside
# a `$(...)` substitution `exit` only kills the subshell, not the script,
# code review a8fe9ded caught this):
#   0 — printed the selected semaphore path to stdout
#   1 — no open semaphore at all for this agent
#   2 — ambiguous or requested --wp/--slug matched nothing; candidate list
#       already printed to stderr, caller should just propagate a failure
list_candidates() { # list_candidates <agent> — one path per line, newest first
  ls -t "$SESSION_DIR/${1}"-*.open 2>/dev/null || true
}

print_candidates() { # print_candidates <candidates> — human-readable list to stderr
  local cand
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    echo "  $(basename "$cand")  wp=$(grep "^wp: " "$cand" | cut -d' ' -f2-)  slug=$(grep "^slug: " "$cand" | cut -d' ' -f2-)" >&2
  done <<< "$1"
}

select_semaphore() {
  local agent="$1" want_wp="$2" want_slug="$3"
  local candidates cand cand_wp cand_slug count
  local matches=()

  candidates=$(list_candidates "$agent")
  [ -z "$candidates" ] && return 1

  if [ -n "$want_wp" ] || [ -n "$want_slug" ]; then
    while IFS= read -r cand; do
      [ -z "$cand" ] && continue
      cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
      cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
      # With both selectors, this must be an intersection.  A work product is
      # shared by several sessions, so matching it alone can select a stale or
      # concurrent session even when the caller supplied the exact slug.
      if { [ -n "$want_wp" ] && [ -n "$want_slug" ] &&
           [ "$cand_wp" = "$want_wp" ] && [ "$cand_slug" = "$want_slug" ]; } || \
         { [ -z "$want_slug" ] && [ -n "$want_wp" ] && [ "$cand_wp" = "$want_wp" ]; } || \
         { [ -z "$want_wp" ] && [ -n "$want_slug" ] && [ "$cand_slug" = "$want_slug" ]; }; then
        matches+=("$cand")
      fi
    done <<< "$candidates"

    if [ "${#matches[@]}" -eq 1 ]; then
      echo "${matches[0]}"
      return 0
    fi

    # WP-484 Ф49 (04.08, Codex): раньше здесь стоял `break` на первом совпадении,
    # то есть при двух открытых сессиях одного РП выбиралась просто новейшая по
    # mtime — и `close` закрывал не ту сессию, а `note-file` отдавал право на
    # коммит чужой работе. Совпало несколько — это отказ, а не догадка: уточни
    # --slug или --session-id.
    if [ "${#matches[@]}" -gt 1 ]; then
      echo "session-guard: под wp='$want_wp' slug='$want_slug' подходит несколько сессий агента '$agent' — уточни:" >&2
      print_candidates "$(printf '%s\n' "${matches[@]}")"
      return 2
    fi

    # Explicit --wp/--slug was given and matched nothing — never silently
    # fall back to "the only open one", even when there's exactly one.
    # Falling back here would close/note-file the WRONG session under the
    # operator's own explicit (but mistyped/stale) --wp, defeating the
    # entire point of this fix.
    echo "session-guard: ни один открытый семафор агента '$agent' не совпал с wp='$want_wp' slug='$want_slug':" >&2
    print_candidates "$candidates"
    return 2
  fi

  count=$(echo "$candidates" | grep -c . || true)
  if [ "$count" -eq 1 ]; then
    echo "$candidates"
    return 0
  fi

  echo "session-guard: несколько открытых семафоров для агента '$agent' — укажи --wp/--slug:" >&2
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
    cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
    echo "  $(basename "$cand")  wp=$cand_wp  slug=$cand_slug" >&2
  done <<< "$candidates"
  return 2
}

# WP-537 (19.08, пир-сессия с Codex + /verify code, находка P2): общая точка
# резолва семафора по --session-id для close/note-file -- то же имя файла,
# что уже резолвит `renew` напрямую (${agent}-${session_id}.open), но с
# добавленной конфликт-проверкой против явно переданных --wp/--slug. Третье
# почти идентичное вхождение этой логики (после renew и первой версии close/
# note-file) -- вынесено сюда, а не повторено ещё раз. Печатает путь семафора
# в stdout и возвращает 0 при успехе; при отказе печатает причину в stderr
# (та же конвенция, что select_semaphore выше) и возвращает 1 -- caller сам
# решает, каким fail()/exit-кодом это обернуть, здесь exit не вызывается,
# чтобы вызов через "$(...)" не терял код возврата в подshell'е.
resolve_semaphore_by_session_id() {  # <agent> <session-id> [wp] [slug]
  local agent="$1" sid="$2" want_wp="${3:-}" want_slug="${4:-}"
  local sem="$SESSION_DIR/${agent}-${sid}.open"
  if [ ! -f "$sem" ]; then
    echo "нет открытой сессии ${agent}-${sid}" >&2
    return 1
  fi
  if [ -n "$want_wp" ]; then
    local sem_wp
    sem_wp=$(grep "^wp: " "$sem" | cut -d' ' -f2- || true)
    if [ "$sem_wp" != "$want_wp" ]; then
      echo "--session-id $sid указывает на wp='$sem_wp', а передан --wp='$want_wp' -- конфликт селекторов" >&2
      return 1
    fi
  fi
  if [ -n "$want_slug" ]; then
    local sem_slug
    sem_slug=$(grep "^slug: " "$sem" | cut -d' ' -f2- || true)
    if [ "$sem_slug" != "$want_slug" ]; then
      echo "--session-id $sid указывает на slug='$sem_slug', а передан --slug='$want_slug' -- конфликт селекторов" >&2
      return 1
    fi
  fi
  echo "$sem"
  return 0
}

# --- parse args ---
WP=""
TASK=""
FILES=""
SLUG=""
AGENT="${IWE_AGENT:-}"
HOUSEKEEPING=""
PERSONALITY=""
# WP-484 Ф118 (19.08, пир-сессия с Codex): declared close protocol for this
# session — quick-close|day-close|peer-session|pipeline|none. Written into the
# semaphore so close-runner-gate.sh/close-gate-reminder.sh can stop guessing
# which closing procedure applies from session_id shape alone. Empty stays
# "unknown" (legacy callers that don't pass it), which keeps today's behavior.
CLOSE_PATH=""
# WP-484 (session-close-hygiene peer-session, 2026-08-20, Ф118 backlog item):
# same pattern as CLOSE_PATH above — optional, written into the semaphore,
# defaults to "не указано" so callers that don't pass it keep today's
# behavior. Lets the NEXT `open` for this WP read back what actually
# happened (Background Gate in protocol-open.md already reads session_closed
# ledger records for this; RESULT_ARG/DEFER_ARG give it a second, direct
# source straight from the semaphore itself, not only the ledger).
RESULT_ARG=""
DEFER_ARG=""
OWNER_PID=""
SESSION_ID_ARG=""
CLEANUP_ORPHANS=0
FORCE_NO_REFLECTION=""
CANONICAL_OWNER=""
FORCE_FLAG=0
UNFREEZE_REASON=""
ISOLATE_FLAG=0
EXPECTED_HASH=""
EXPECTED_ABSENT=0
BASE_SHA=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)     WP="$2"; shift 2 ;;
    --task)   TASK="$2"; shift 2 ;;
    --files)  FILES="$2"; shift 2 ;;
    --slug|--topic) SLUG="$2"; shift 2 ;;
    --agent)  AGENT="$2"; shift 2 ;;
    --close-path) CLOSE_PATH="$2"; shift 2 ;;
    --result) RESULT_ARG="$2"; shift 2 ;;
    --defer)  DEFER_ARG="$2"; shift 2 ;;
    --housekeeping) HOUSEKEEPING="$2"; shift 2 ;;
    # WP-484 Ф72 доводка (review r7, Codex): маркер standalone-доверия для
    # witness-скипа quick-close пишется ТОЛЬКО по явному флагу лаунчера
    # (launchd/scheduler-скрипты, запускающие Kimi headless). Без флага open
    # маркер не пишет никогда: имя агента не доказывает headless-запуск —
    # интерактивная Kimi-сессия с пилотом в чате иначе получала бы право
    # молча пропустить рефлексию.
    --standalone-launch) STANDALONE_LAUNCH=1; shift ;;
    # WP-520 freeze-enforce (peer-session 2026-08-14-07): the only sanctioned
    # bypass, for launchd/cron runners that own the canonical checkout by
    # schedule rather than compete for it. Value is diagnostic only (shows up
    # in `audit`), not checked against a fixed set -- the freeze-block below
    # only tests non-empty.
    --canonical-owner) CANONICAL_OWNER="$2"; shift 2 ;;
    --reason)
      # Same class of bug as --force-no-reflection below (WP-520 sixteenth
      # live finding, session-guard.sh:310 at the time): a value-bearing
      # flag passed last with nothing after it makes `$2` a read past the
      # argv end under `set -u`, killing the script mid-parse instead of
      # failing with a readable message.
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--reason требует непустое значение (причина запроса на разморозку)" 1
      fi
      UNFREEZE_REASON="$2"; shift 2 ;;
    --personality) PERSONALITY="$2"; shift 2 ;;
    --owner-pid) OWNER_PID="$2"; shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --expected-hash)
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--expected-hash требует непустое значение (sha256 файла, который читал вызывающий)" 1
      fi
      EXPECTED_HASH="$2"; shift 2 ;;
    # WP-530 (2026-08-20, peer-session с Codex): --expected-hash не покрывает
    # "файла ещё не было" -- sha256 пустых байтов смешал бы "нет файла" с
    # "файл есть, но пустой", два разных состояния. Флаг без значения, не
    # альтернативный --expected-hash со спецзначением: caller должен явно
    # выбрать одну из двух семантик, а не угадывать по строке-заглушке.
    --expected-absent) EXPECTED_ABSENT=1; shift ;;
    --base-sha)
      # WP-503 Ф12 (пир-сессия 2026-08-18): позволяет вызывающему зафиксировать
      # SHA ДО вызова open --isolate (например, под capacity-lock, чтобы
      # закрыть окно между "увидел базу" и "создал от неё worktree" — см.
      # nightly-worktree-isolation.sh:pin_base_sha) и создать worktree именно
      # от этого коммита, а не от origin/main в момент вызова этой функции
      # (который может успеть уйти вперёд между двумя независимыми fetch).
      # Применяется ТОЛЬКО с --isolate — без него флаг не имеет смысла
      # (canonical-owner режим не создаёт worktree вовсе).
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--base-sha требует непустое значение (SHA, зафиксированный вызывающим до open)" 1
      fi
      BASE_SHA="$2"; shift 2 ;;
    --since)  SINCE="$2"; shift 2 ;;
    --cleanup-orphans) CLEANUP_ORPHANS=1; shift ;;
    --force)  FORCE_FLAG=1; shift ;;
    --isolate) ISOLATE_FLAG=1; shift ;;
    --force-no-reflection)
      # The reason is a required part of this flag's semantics (WP-484,
      # 08.08 -- FORCE_NO_REFLECTION is used downstream as a documented
      # bypass reason, not a boolean). Passed last with no value after it
      # (WP-520 sixteenth live finding), $2 doesn't exist under `set -u` and
      # the whole script dies mid-close -- fail with a readable message
      # instead, still requiring the reason (empty string carries no
      # meaning here either).
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--force-no-reflection требует непустую причину как значение (например: --force-no-reflection \"work already pushed, commit_needed=false\")" 1
      fi
      FORCE_NO_REFLECTION="$2"; shift 2 ;;
    --)       shift; POSITIONAL+=("$@"); break ;;
    -*)       shift ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$AGENT" ] && { [ "$CMD" = "open" ] || [ "$CMD" = "close" ]; }; then
  fail "--agent обязателен для open/close (или переменная IWE_AGENT)" 1
fi

# --isolate and --canonical-owner are two different classes of session
# (interactive-writer-gets-its-own-copy vs. scheduled-job-owns-the-canonical-
# checkout-by-schedule) -- combining them silently would leave it ambiguous
# which one wins. Peer-session 2026-08-14-13-wp520-two-layer-closing-arch,
# consensus turn 3 (Codex): reject both together explicitly.
if [ "$ISOLATE_FLAG" = "1" ] && [ -n "$CANONICAL_OWNER" ]; then
  fail "--isolate и --canonical-owner взаимоисключающие: планировщик владеет каноническим чекаутом по расписанию (--canonical-owner), интерактивная сессия получает свою изолированную копию (--isolate) -- не оба сразу" 1
fi

# --base-sha без --isolate не имеет смысла (canonical-owner режим не создаёт
# worktree вовсе, обычный open тоже) -- явный отказ вместо молчаливого игнора
# значения (WP-503 Ф12, тот же принцип, что уже применён к межвендорским
# флагам peer-адаптеров: молчаливый игнор создаёт ложное ощущение применённого
# режима).
if [ -n "$BASE_SHA" ] && [ "$ISOLATE_FLAG" != "1" ]; then
  fail "--base-sha требует --isolate (SHA-pin имеет смысл только для изолированного worktree)" 1
fi

# Owner PID is evidence that the caller, not this short-lived guard process,
# remains responsible for the session.  Do not infer it from $$: the guard
# exits immediately after open and would make a live session look orphaned.
if [ -n "$OWNER_PID" ] && ! [[ "$OWNER_PID" =~ ^[0-9]+$ ]]; then
  fail "--owner-pid должен быть числовым PID процесса-владельца" 1
fi

# --- OPEN ---
if [ "$CMD" = "open" ]; then
  # WP-510 Патч 4: personality — маршрутизирующая метка "какая ИИ-личность вела
  # сессию", не допуск к памяти (PIPE-14 решает перенос отдельно). Пустой флаг =
  # unassigned — тот же итог, что и явный `--personality unassigned`, разница
  # explicit/default не хранится (consensus 2026-08-04-11-codex-wp510-patch4-proposed).
  PERSONALITY="${PERSONALITY:-unassigned}"
  if [ "$PERSONALITY" != "unassigned" ] && ! [[ "$PERSONALITY" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    fail "--personality: ожидается 'unassigned' либо UUID вида 8-4-4-4-12 (получено: '$PERSONALITY')" 1
  fi

  if [ -n "$HOUSEKEEPING" ]; then
    # Housekeeping session: no ORZ, no WP, one semaphore per (agent, reason).
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    HK_MAX_AGE=1800  # 30 minutes default TTL for housekeeping semaphores
    NOW_EPOCH=$(date +%s)
    if [ -f "$HK_FILE" ]; then
      HK_CREATED=$(grep "^created_at: " "$HK_FILE" | cut -d' ' -f2- || echo "")
      if [ -n "$HK_CREATED" ]; then
        HK_CREATED_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$HK_CREATED" +%s 2>/dev/null || date -d "$HK_CREATED" +%s 2>/dev/null || echo "")
        if [ -n "$HK_CREATED_EPOCH" ]; then
          HK_AGE=$(( NOW_EPOCH - HK_CREATED_EPOCH ))
          if [ "$HK_AGE" -gt "$HK_MAX_AGE" ]; then
            mv "$HK_FILE" "${HK_FILE}.stale"
            rm -f "${HK_FILE}.lease"
            echo "WARNING: housekeeping semaphore '${HOUSEKEEPING}' stale (${HK_AGE}s), renamed to .stale" >&2
          else
            fail "open --housekeeping: уже есть активная housekeeping-сессия '${HOUSEKEEPING}' (возраст ${HK_AGE}s). Закрой её или дождись TTL ${HK_MAX_AGE}s" 1
          fi
        fi
      fi
    fi
    {
      echo "---"
      echo "agent: $AGENT"
      echo "personality: $PERSONALITY"
      echo "housekeeping: $HOUSEKEEPING"
      # bug-2026-07-10 (Day Close): select_semaphore() only matches on `wp:`/`slug:`
      # lines. Without this, 2+ open housekeeping semaphores are permanently
      # ambiguous for note-file/close — --slug has nothing to match against.
      echo "slug: $HOUSEKEEPING"
      echo "created_at: $(now_iso)"
      # A PID belongs only to the long-lived owner supplied by the caller (or
      # Claude Code's stable runtime PID), never to this transient guard.
      # Without reliable evidence, omit it so audit keeps the session as
      # ambiguous instead of falsely quarantining it.
      [ -n "${OWNER_PID:-${CLAUDE_PID:-}}" ] && echo "pid: ${OWNER_PID:-$CLAUDE_PID}"
      # WP-484 Ф72 доводка (review r7): session_id внутри frontmatter, не в
      # хвосте — весь читающий код ищет поля семафора в шапке.
      if [ "${STANDALONE_LAUNCH:-0}" = "1" ] && [ "$AGENT" = "kimi" ]; then
        HK_SID="$(date +%s)-hk"
        echo "session_id: $HK_SID"
      fi
      echo "---"
    } > "$HK_FILE"
    # Маркер standalone-доверия — по тому же id, что попал в семафор.
    if [ -n "${HK_SID:-}" ]; then
      : > "$IWE_ROOT/.iwe-runtime/kimi-standalone-${HK_SID}.marker" 2>/dev/null || true
    fi
    echo "Housekeeping OPEN: $HK_FILE (reason: $HOUSEKEEPING)"
    exit 0
  fi

  [ -z "$WP" ] && fail "--wp обязателен для open" 2

  # Warn (never block) when another ACTIVE semaphore for the same WP already
  # exists in a DIFFERENT checkout of the same upstream repo — the class of
  # incident that produced 12 worktrees across 3 distinct `.git` dirs for
  # DS-my-strategy (peer-session 2026-08-14-02-git-worktree-chaos, consensus
  # with Codex). `git worktree list` only sees worktrees registered against
  # ONE `.git`; a plain `git clone` (the actually harmful pattern — worktrees
  # of a worktree, dashboard-clone style) is invisible to it. Reuses
  # normalize_remote_url() and the same origin-remote comparison gov_repo_dir()
  # already does above, rather than adding a second identity mechanism.
  # Scoped across ALL agents (not just $AGENT, unlike the stale-semaphore loop
  # below) because the incident is inherently cross-agent: Claude, Codex and
  # Kimi each opening their own checkout of the same WP is exactly the failure
  # mode this warns about.
  CURRENT_REPO_DIR="$(gov_repo_dir)"
  CURRENT_REMOTE="$(git -C "$CURRENT_REPO_DIR" remote get-url origin 2>/dev/null || true)"
  if [ -n "$CURRENT_REMOTE" ]; then
    while IFS= read -r OTHER_SEM; do
      [ -z "$OTHER_SEM" ] && continue
      [ -f "$OTHER_SEM" ] || continue
      OTHER_WP=$(grep "^wp: " "$OTHER_SEM" | cut -d' ' -f2- || true)
      [ "$OTHER_WP" = "$WP" ] || continue
      OTHER_REPO_DIR=$(grep "^orz_sessions_dir: " "$OTHER_SEM" | cut -d' ' -f2- | sed 's#/sessions$##' || true)
      [ -n "$OTHER_REPO_DIR" ] || continue
      [ "$OTHER_REPO_DIR" = "$CURRENT_REPO_DIR" ] && continue  # same checkout, not a duplicate
      OTHER_REMOTE=$(git -C "$OTHER_REPO_DIR" remote get-url origin 2>/dev/null || true)
      [ -n "$OTHER_REMOTE" ] || continue
      if [ "$(normalize_remote_url "$CURRENT_REMOTE")" = "$(normalize_remote_url "$OTHER_REMOTE")" ]; then
        OTHER_AGENT=$(grep "^agent: " "$OTHER_SEM" | cut -d' ' -f2- || echo "unknown")
        echo "WARNING: WP $WP уже открыт в ДРУГОЙ копии этого репозитория — $(basename "$OTHER_SEM") (agent: $OTHER_AGENT, checkout: $OTHER_REPO_DIR). Текущий checkout: $CURRENT_REPO_DIR. Переиспользуй существующую копию (git worktree add от канонического чекаута), не плоди новый git clone." >&2
      fi
    done < <(find "$SESSION_DIR" -name '*.open' -type f 2>/dev/null)
  fi

  # Block `open` running directly against a checkout under freeze (WP-520,
  # peer-session 2026-08-14-07-wp520-freeze-enforce — the found-28 warning
  # never fired live in three days of use because the arming env var was
  # never actually exported anywhere; the default-on change above finally
  # makes this reachable, so the warning becomes a real block here). Compares
  # realpath, not the raw string, so a symlink or alternate mount to the same
  # physical directory still triggers it (peer-session 2026-08-14-06, Codex
  # review caught this before the first version shipped).
  #
  # Three carve-outs, narrowed from an earlier draft by cold-context review +
  # follow-up rounds with Codex across two peer-sessions:
  #
  # 1. --canonical-owner (unconditional). launchd/cron runners
  #    (kimi-wp-run-scheduled.sh, wp-run-scheduled-tsekh1.sh) own the
  #    canonical checkout by schedule, not by contest -- freeze targets NEW
  #    interactive writers piling onto a contested checkout, not the single
  #    scheduled job that already has exclusive standing. Not agent-scoped
  #    (an earlier draft special-cased --agent kimi; rejected because
  #    interactive Kimi sessions exist too and agent-name is not a stable
  #    policy key).
  #
  # 2. Exact-slug re-entry. NOT "any live semaphore for this WP+agent" (that
  #    first draft let an unrelated new `open` ride an unrelated agent's live
  #    lease and open a second semaphore for the same WP -- exactly the
  #    collision freeze exists to prevent). Re-entry is allowed only when the
  #    caller's own --slug matches the slug already recorded on a live
  #    semaphore for this WP+agent: same slug from the same agent is the same
  #    logical session resuming (e.g. after a crash), not a second writer. No
  #    --slug given -> no exception, freeze blocks unconditionally.
  #
  # 3. --isolate (peer-session 2026-08-14-13-wp520-two-layer-closing-arch,
  #    DRR two-layer-closing-arch). This is the case freeze was ultimately
  #    FOR, not an exception to weaken it: a session that gets its own
  #    worktree instead of writing to the canonical checkout directly is
  #    exactly what the freeze block's own error message already recommends
  #    ("Используй изолированный worktree... 'git worktree add'"). Without
  #    this carve-out `--isolate` could never fire against the one checkout
  #    it exists to protect, which is where it matters most -- a bug found
  #    live in this same session testing against a sandbox repo before this
  #    fix (freeze fired first, unconditionally, before the isolate block
  #    below ever got the chance to run).
  if [ "${#FROZEN_CANONICAL_PATHS[@]}" -gt 0 ] && [ -z "$CANONICAL_OWNER" ] && [ "$ISOLATE_FLAG" != "1" ]; then
    # WP-484 Ф104 smoke test (2026-08-16) caught this reusing $CURRENT_REPO_DIR
    # (= gov_repo_dir(), set above for a DIFFERENT question -- "where should
    # the ORZ scaffold land," which deliberately falls back to the canonical
    # $GOV_REPO path whenever the caller's cwd doesn't remote/basename-match
    # $GOV_REPO, per gov_repo_dir()'s own comment). That fallback made a
    # second frozen path structurally unreachable: any cwd that isn't
    # $GOV_REPO always resolved to $GOV_REPO here regardless of where it
    # actually was, so $IWE_ROOT could never be recognized as the caller's
    # own checkout. Freeze needs "what checkout is the caller actually
    # sitting in," a different question with its own answer -- the real cwd
    # of THIS invocation, not the target of a write $open hasn't been cleared
    # to make yet.
    ACTUAL_CWD_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    CURRENT_CWD_REAL=$(realpath "$ACTUAL_CWD_TOPLEVEL" 2>/dev/null || echo "$ACTUAL_CWD_TOPLEVEL")
    for FROZEN_PATH in "${FROZEN_CANONICAL_PATHS[@]}"; do
      FROZEN_REAL=$(realpath "$FROZEN_PATH" 2>/dev/null || echo "$FROZEN_PATH")
      if [ "$CURRENT_CWD_REAL" = "$FROZEN_REAL" ]; then
        REENTRY_OK=false
        if [ -n "$SLUG" ]; then
          while IFS= read -r EXISTING_SEM; do
            [ -z "$EXISTING_SEM" ] && continue
            [ -f "$EXISTING_SEM" ] || continue
            [ "$(grep "^wp: " "$EXISTING_SEM" | cut -d' ' -f2-)" = "$WP" ] || continue
            [ "$(grep "^slug: " "$EXISTING_SEM" | cut -d' ' -f2-)" = "$SLUG" ] || continue
            lease_valid "$EXISTING_SEM" || continue
            REENTRY_OK=true
            break
          done < <(find "$SESSION_DIR" -name "${AGENT}-*.open" -type f 2>/dev/null)
        fi
        if ! $REENTRY_OK; then
          fail "этот checkout ($ACTUAL_CWD_TOPLEVEL) под freeze (WP-520/WP-484 Ф104) — прямая запись не разрешена до отдельного решения. Используй изолированный worktree: EnterWorktree или 'git worktree add' от свежего origin/main. Плановому раннеру: добавь --canonical-owner <reason>." 1
        fi
        break
      fi
    done
  fi

  # --isolate: session-owned git worktree, created here so the caller never
  # has to remember `git worktree add` by hand (что происходило вручную
  # десятки раз 13-14.08 согласно карточке WP-520). Reached both when the
  # freeze block above didn't fire at all (a non-canonical checkout, or
  # freeze disarmed) AND via its own carve-out #3 when it did (isolate is
  # what freeze recommends doing instead of a direct write) -- a session
  # opening WITHOUT --isolate against the frozen canonical path still hits
  # that block unchanged, this flag is the only thing that routes around it.
  ISOLATED_WORKTREE_PATH=""
  ISOLATED_WORKTREE_BRANCH=""
  ORZ_ISOLATE_OVERRIDE=""
  if [ "$ISOLATE_FLAG" = "1" ]; then
    [ -n "$SLUG" ] && validate_isolate_slug "$SLUG"

    # Codex turn 9: молчаливое исчезновение незакоммиченных/untracked файлов
    # исходного каталога — риск потери контекста, не защита. `git worktree
    # add` берёт только tracked HEAD; explicit refuse instead of guessing
    # whether the caller meant to bring that state along.
    #
    # WP-484 Ф104 (2026-08-16, found live while deploying this very phase):
    # was `gov_repo_dir()` here, same root cause as the freeze bug this phase
    # already fixed above -- gov_repo_dir() resolves "where should the ORZ
    # write," which falls back to the canonical $GOV_REPO path whenever cwd
    # doesn't remote/basename-match it, so `open --isolate` invoked from
    # $IWE_ROOT itself silently created its worktree from $GOV_REPO instead
    # (live-caught: an isolate session opened from ~/IWE came back branched
    # off DS-my-strategy's remote, not iwe-local-config's). The caller's
    # actual cwd -- what --isolate is supposed to snapshot -- has to be
    # resolved directly, the same fix as the freeze block, not derived from
    # a resolver built to answer an unrelated question.
    ISOLATE_BASE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || gov_repo_dir)"

    # Peer-session 2026-08-14-13-wp520-two-layer-closing-arch (turns 12-16,
    # 3 rounds with Codex after 2 live-tested failed attempts). A re-entry of
    # the SAME session_id sees `open`'s own side effects (ORZ scaffold,
    # OPEN_LOG append) from the first `open` as "dirty" -- final design
    # (Codex, turn 15): every dirty path on re-entry must be a `file:` path
    # ALREADY registered on this session's OWN semaphore, checked EVERY time
    # (not skipped), not a name-based exemption list that breaks the moment
    # `open` gains a third side effect. Full five conditions from turn 15:
    #   1. verify session_id/isolated_worktree/branch against the semaphore
    #      before granting re-entry (below, before the worktree lock);
    #   2. an existing worktree with no matching semaphore is a refusal, not
    #      "treat as first entry" (below, inside the lock);
    #   3. side-effect paths (OPEN_LOG) are registered under the SAME lock
    #      the semaphore write itself uses, before their own append can run
    #      (done above, inside the semaphore heredoc);
    #   4. exact normalized-path comparison, not prefix matching;
    #   5. OPEN_LOG is registered explicitly, not assumed "usually there".
    # date +%s alone collides deterministically: two interactive callers
    # (neither sets IWE_SESSION_ID) landing in the same wall-clock second get
    # the identical id, which the lock below then serializes into a refusal
    # for the loser -- correct, but avoidable. Entropy suffix instead of
    # nanosecond resolution (`date +%s%N`) because %N is a GNU date
    # extension, unavailable on some non-Linux/non-GNU environments this
    # script might run under; /dev/urandom -> $RANDOM fallback keeps this
    # id generator working even where /dev/urandom is unreadable (some
    # sandboxes/containers) (WP-530 peer-session 2026-08-15-10, Kimi turn 2).
    ISOLATE_SESSION_ID="${IWE_SESSION_ID:-$(date +%s)-$(isolate_entropy_suffix)}"
    ISOLATE_EXISTING_SEM="$SESSION_DIR/${AGENT}-${ISOLATE_SESSION_ID}.open"

    # cold-context review (2026-08-14, this same session): plain
    # `--porcelain` (no `-z`) quotes any path with non-ASCII bytes in
    # C-style octal escapes (\NNN, no leading zero) -- `printf '%b'` decodes
    # the DIFFERENT \0NNN form, so a naive unquote silently fails on real
    # git output and never matches. Live-confirmed against this same
    # checkout, which has actual Cyrillic paths (Lifework/, etc.). `-z`
    # (NUL-separated) has no C-quoting to get wrong, so both the "is
    # anything dirty" check and the allowlist compare below read from the
    # SAME single `-z` invocation instead of two differently-quoted calls
    # that could disagree on a non-ASCII path.
    ISOLATE_DIRTY_ENTRIES=()
    while IFS= read -r -d '' isolate_status_entry; do
      [ -n "$isolate_status_entry" ] || continue
      ISOLATE_DIRTY_ENTRIES+=("$isolate_status_entry")
    done < <(git -C "$ISOLATE_BASE_DIR" status --porcelain -z --untracked-files=all 2>/dev/null)
    if [ "${#ISOLATE_DIRTY_ENTRIES[@]}" -gt 0 ]; then
      if [ ! -f "$ISOLATE_EXISTING_SEM" ]; then
        # No semaphore for this session_id yet -- first entry. Under the
        # WP-520 freeze (every new session goes through --isolate), the
        # canonical checkout is near-guaranteed to carry SOMEONE ELSE's
        # legitimate in-flight work at any given moment -- a hard fail here
        # doesn't protect that work (git worktree add never touches it,
        # tracked-HEAD only), it just makes --isolate itself unusable at the
        # concurrency freeze exists to support (live-reproduced WP-530
        # peer-session 2026-08-16-01, writer's own session opening tripped
        # this exact fail against WP-524/WP-389/WP-532/WP-167's dirt).
        #
        # Bypass only on the canonical path itself, not an already-isolated
        # worktree calling --isolate again (that dirt is far more likely to
        # be the caller's own forgotten edit, not a peer's -- still refuse
        # there, same as before). Codex turn 3 (2026-08-16-01): the risk
        # isn't losing the foreign work (it stays on disk, untouched, HEAD
        # only) -- it's two agents making the bypass decision blind to each
        # other and later reconciling a canonical checkout neither fully
        # understood. Mitigation: a fingerprinted marker that the NEXT
        # bypasser hitting the SAME dirty state reads back, so it's told who
        # already decided it rather than deciding blind.
        #
        # Two simultaneous bypassers BOTH proceeding is the correct outcome
        # here -- each wants its own worktree, neither touches the other's
        # files -- so this is a notification problem, not a mutual-exclusion
        # one, and doesn't need a lock. Codex turn 5 (2026-08-16-01): a
        # shared log file with "read it, then append if no match" is its own
        # race (two agents can both read "no match" and both append,
        # correctly, but neither learns about the other) -- advisory-only
        # is an honest label for that, but a strictly better fix costs the
        # same: one `mkdir` per fingerprint, the same atomic-directory idiom
        # already proven twice in this file (with_isolate_lock above,
        # lock-hot-file elsewhere). Whoever's `mkdir` wins recorded first;
        # every later bypasser for the identical fingerprint gets a real,
        # not best-effort, "already seen" answer -- no window where two
        # first-recorders both think they're first.
        # WP-484 (2026-08-18-02-wp484-witness-implementation): bypass used to
        # compare against $IWE_ROOT/$GOV_REPO alone -- correct before Ф104
        # extended the freeze to $IWE_ROOT itself (FROZEN_CANONICAL_PATHS,
        # line 105), stale after. A single-path check left every OTHER frozen
        # path (currently just $IWE_ROOT) with no bypass at all: --isolate
        # from $IWE_ROOT hit the "already-isolated worktree" hard-fail branch
        # unconditionally, even right after a clean `git stash` -- live-caught
        # trying to fix session-guard.sh itself, this file's own frozen path.
        # Loop over the whole frozen-paths list instead of one scalar so any
        # future addition to that array (the comment above it already expects
        # one) gets bypass coverage automatically, not another one-off patch.
        ISOLATE_BASE_REAL="$(realpath "$ISOLATE_BASE_DIR" 2>/dev/null || echo "$ISOLATE_BASE_DIR")"
        ISOLATE_ON_FROZEN_PATH=0
        for isolate_frozen_path in "${FROZEN_CANONICAL_PATHS[@]}"; do
          if [ "$ISOLATE_BASE_REAL" = "$(realpath "$isolate_frozen_path" 2>/dev/null || echo "$isolate_frozen_path")" ]; then
            ISOLATE_ON_FROZEN_PATH=1
            break
          fi
        done
        if [ "$ISOLATE_ON_FROZEN_PATH" -eq 0 ]; then
          fail "--isolate: в текущем каталоге ($ISOLATE_BASE_DIR) есть незакоммиченные или untracked изменения -- новый worktree их не унаследует. Это уже изолированная копия, не общий канонический чекаут, так что эта грязь с большей вероятностью твоя собственная. Закоммить, застэшь (git stash) или яви явное решение, прежде чем открывать вложенную изолированную копию." 1
        fi
        # `|| true` on BOTH the pipeline and the assignment: under `set -o
        # pipefail` a missing `shasum` (a perl script -- absent in minimal
        # containers, present here) makes the whole assignment exit 127, and
        # `set -e` then kills the script BEFORE any fallback line can run --
        # a silent death with no worktree and no message. Cold review of
        # this patch caught it empirically (WP-530 peer-session
        # 2026-08-16-01); the fingerprint is a diagnostic, never a reason to
        # refuse to open.
        ISOLATE_DIRTY_HASH=$(printf '%s\0' "${ISOLATE_DIRTY_ENTRIES[@]}" \
          | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || true; } \
          | cut -d' ' -f1 || true)
        [ -n "$ISOLATE_DIRTY_HASH" ] || ISOLATE_DIRTY_HASH="unavailable"
        ISOLATE_BYPASS_DIR="$IWE_ROOT/.iwe-runtime/canonical-dirty-bypass"
        ISOLATE_BYPASS_LOG="$ISOLATE_BYPASS_DIR/history.log"
        mkdir -p "$ISOLATE_BYPASS_DIR" 2>/dev/null || true
        # Full history for humans (best-effort, append-only -- never the
        # correctness path). "already seen" for the NEXT bypasser is the
        # mkdir below, not a read of this file.
        printf '%s agent=%s session_id=%s base_dir=%s dirty_hash=%s dirty_count=%s\n' \
          "$(now_iso)" "$AGENT" "$ISOLATE_SESSION_ID" "$ISOLATE_BASE_DIR" \
          "$ISOLATE_DIRTY_HASH" "${#ISOLATE_DIRTY_ENTRIES[@]}" >> "$ISOLATE_BYPASS_LOG" 2>/dev/null || true
        ISOLATE_PRIOR_BYPASS=""
        if [ "$ISOLATE_DIRTY_HASH" != "unavailable" ]; then
          ISOLATE_BYPASS_MARKER="$ISOLATE_BYPASS_DIR/$ISOLATE_DIRTY_HASH"
          if mkdir "$ISOLATE_BYPASS_MARKER" 2>/dev/null; then
            printf 'agent=%s\nsession_id=%s\nbase_dir=%s\nat=%s\n' \
              "$AGENT" "$ISOLATE_SESSION_ID" "$ISOLATE_BASE_DIR" "$(now_iso)" \
              > "$ISOLATE_BYPASS_MARKER/first" 2>/dev/null || true
          else
            ISOLATE_PRIOR_BYPASS=$(tr '\n' ' ' < "$ISOLATE_BYPASS_MARKER/first" 2>/dev/null || true)
          fi
        fi
        echo "⚠️  --isolate: канонический чекаут ($ISOLATE_BASE_DIR) грязный от чужой работы (${#ISOLATE_DIRTY_ENTRIES[@]} путей, fingerprint $ISOLATE_DIRTY_HASH) -- new worktree её не унаследует (ожидаемо, HEAD-only), она остаётся на диске нетронутой. История в $ISOLATE_BYPASS_LOG." >&2
        [ -n "$ISOLATE_PRIOR_BYPASS" ] \
          && echo "   ↳ ту же грязь уже обошёл: $ISOLATE_PRIOR_BYPASS" >&2 || true
      else
        # Re-entry: build the exact allowlist from THIS session's own
        # semaphore, not a hardcoded filename list. Codex turn 15 point 4 --
        # compare full normalized relative paths, not a substring/prefix grep
        # (grep -vF on a raw path segment can under- or over-match ambiguous
        # filenames).
        ISOLATE_ALLOWLIST=$(grep '^file: ' "$ISOLATE_EXISTING_SEM" | sed 's/^file: //' | sort -u)
        ISOLATE_UNEXPECTED_DIRTY=""
        for isolate_status_entry in "${ISOLATE_DIRTY_ENTRIES[@]}"; do
          isolate_status_code="${isolate_status_entry:0:2}"
          isolate_status_path="${isolate_status_entry:3}"
          if ! grep -qxF "$isolate_status_path" <<< "$ISOLATE_ALLOWLIST"; then
            ISOLATE_UNEXPECTED_DIRTY="$ISOLATE_UNEXPECTED_DIRTY
$isolate_status_code $isolate_status_path"
          fi
        done
        if [ -n "$ISOLATE_UNEXPECTED_DIRTY" ]; then
          fail "--isolate: re-entry сессии $ISOLATE_SESSION_ID нашёл грязные пути вне зарегистрированного allowlist этой же сессии -- вероятно чужая работа, не собственный побочный эффект. Закоммить, застэшь или разбери вручную:$ISOLATE_UNEXPECTED_DIRTY" 1
        fi
      fi
    fi

    # Codex turn 3: явный fetch, не молчаливый устаревший tracking ref.
    # WP-503 Ф12: пропускается, если вызывающий уже передал --base-sha --
    # тот SHA был зафиксирован ЕГО СОБСТВЕННЫМ fetch до входа сюда (например,
    # под capacity-lock в nightly-worktree-isolation.sh); повторный fetch
    # здесь не укрепляет консистентность, а создаёт ровно то окно гонки
    # (fetch #1 -> [push может влезть] -> fetch #2), которое --base-sha
    # существует, чтобы закрыть.
    if [ -z "$BASE_SHA" ]; then
      if ! git -C "$ISOLATE_BASE_DIR" fetch origin main --quiet 2>&1; then
        fail "--isolate: git fetch origin main не прошёл -- не создаю worktree от потенциально устаревшего origin/main. Проверь сеть и повтори." 1
      fi
    fi

    ISOLATE_STORE_DIR="$IWE_ROOT/.iwe-runtime/isolated-worktrees"
    mkdir -p "$ISOLATE_STORE_DIR"
    ISOLATE_STORE_DIR_REAL="$(realpath "$ISOLATE_STORE_DIR")"
    ISOLATED_WORKTREE_PATH="$ISOLATE_STORE_DIR/${AGENT}-${ISOLATE_SESSION_ID}"
    ISOLATED_WORKTREE_BRANCH="session-isolate/${AGENT}-${ISOLATE_SESSION_ID}"

    [ -f "$ISOLATE_EXISTING_SEM" ] && ISOLATE_SEM_EXISTS=1 || ISOLATE_SEM_EXISTS=0
    with_isolate_lock "$ISOLATE_SESSION_ID" bash -c '
      set -euo pipefail
      base_dir="$1" wt_path="$2" wt_branch="$3" store_real="$4" want_slug="$5" agent="$6" sem_exists="$7" base_sha="$8"

      # Re-entry: same session_id already has a worktree — reuse it, verify
      # identity via git worktree list, never blind-create a duplicate.
      # Codex turn 3: "если путь уже существует, проверяем через
      # git worktree list --porcelain, что он привязан ровно к ожидаемой
      # ветке и session-id... не совпадает — fail closed, без удаления и без
      # нового worktree." Codex turn 15 point 2: a worktree with NO matching
      # semaphore at all is a refusal, not "treat as first entry" -- the
      # semaphore having been lost/removed independently of the worktree is
      # exactly the kind of state this whole design distrusts by default.
      if [ -d "$wt_path" ]; then
        if [ "$sem_exists" != "1" ]; then
          # COLLISION_RETRY: this is the branch a losing concurrent `open`
          # hits when its ISOLATE_SESSION_ID collided with a winner that
          # already created $wt_path but has not written its semaphore yet
          # (session-guard.sh open writes the worktree inside the lock,
          # then the semaphore after -- WP-530 peer-session 2026-08-15-09,
          # scenario (i)). Retry-safe ONLY because ISOLATE_SESSION_ID now
          # carries an entropy suffix (isolate_entropy_suffix) -- a caller
          # that regenerates its id and retries gets a fresh, non-colliding
          # path. This same branch can also fire for a genuinely foreign,
          # unrelated worktree at this exact path with no semaphore ever
          # written for it; the two causes are indistinguishable from here,
          # so the marker is advisory (blind retry is safe either way: a
          # fresh id either avoids the real collision or simply lands on an
          # unused path) (WP-530 peer-session 2026-08-15-10, Kimi turn 2).
          echo "COLLISION_RETRY: session-guard: --isolate: worktree $wt_path существует, но семафор сессии не найден -- fail closed (это не первый вход, но и не доверенный re-entry); повтори с новым ISOLATE_SESSION_ID" >&2
          exit 1
        fi
        # realpath both sides before comparing: `git worktree list
        # --porcelain` resolves symlinks in its own output (e.g. macOS
        # /var -> /private/var), a byte-for-byte compare against the raw
        # assembled path silently never matches on this platform -- found
        # live in this same session testing scenario 1 (clean re-entry).
        wt_path_real=$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")
        registered_branch=$(git -C "$base_dir" worktree list --porcelain \
          | awk -v p="$wt_path_real" '\''$1=="worktree" && $2==p {found=1} found && /^branch / {print $2; exit}'\'')
        registered_branch="${registered_branch#refs/heads/}"
        if [ "$registered_branch" != "$wt_branch" ]; then
          echo "session-guard: --isolate: путь $wt_path существует, но привязан к ветке '\''$registered_branch'\'', ожидалась '\''$wt_branch'\'' -- fail closed, не трогаю чужой worktree" >&2
          exit 1
        fi
        exit 0
      fi

      # WP-503 Ф12: пустой base_sha -- прежнее поведение (символическая ссылка
      # origin/main в момент этого вызова). Непустой -- worktree строится
      # ровно от зафиксированного коммита, не от того, что origin/main успел
      # стать к этому моменту (окно между внешним fetch вызывающего и этой
      # точкой уже могло сдвинуть ветку -- pinning существует именно для
      # этого случая).
      if [ -n "$base_sha" ]; then
        git -C "$base_dir" worktree add "$wt_path" -b "$wt_branch" "$base_sha" --quiet
      else
        git -C "$base_dir" worktree add "$wt_path" -b "$wt_branch" origin/main --quiet
      fi

      # realpath after creation, not the assembled string: containment must
      # hold against what actually landed on disk, including any symlink in
      # the store directory itself (Codex turn 3, К2a review precedent).
      if ! { real=$(realpath "$wt_path" 2>/dev/null) && case "$real" in "$store_real"/*) true ;; *) false ;; esac; }; then
        git -C "$base_dir" worktree remove "$wt_path" --force 2>/dev/null || true
        echo "session-guard: --isolate: созданный worktree вышел за пределы ожидаемого каталога хранения (containment check failed) -- удалён" >&2
        exit 1
      fi
    ' -- "$ISOLATE_BASE_DIR" "$ISOLATED_WORKTREE_PATH" "$ISOLATED_WORKTREE_BRANCH" "$ISOLATE_STORE_DIR_REAL" "${SLUG:-}" "$AGENT" "$ISOLATE_SEM_EXISTS" "$BASE_SHA" \
      || fail "--isolate: не удалось создать или переиспользовать worktree (см. сообщение выше)" 1

    # ORZ scaffold и OPEN_LOG must land inside this session's own worktree,
    # not the shared canonical checkout -- otherwise a foreign untracked ORZ
    # file blocks every OTHER concurrent `--isolate open` (live-reproduced
    # 2026-08-15, 4-agent run: agent A's own ORZ scaffold made agents B/C/D's
    # untracked-check fail with "не унаследует", peer-session
    # 2026-08-15-14-isolate-aware-orz-dir, consensus with Codex). Only ORZ is
    # covered here -- OPEN_LOG append can independently dirty the canonical
    # checkout and block a neighbor the same way; that race is a known,
    # deliberately deferred gap (pilot decision, same session), tracked in
    # WP-530 for its own phase, not folded into this fix.
    ORZ_ISOLATE_OVERRIDE="$ISOLATED_WORKTREE_PATH/sessions"

    echo "{\"worktree_path\": \"$ISOLATED_WORKTREE_PATH\", \"branch\": \"$ISOLATED_WORKTREE_BRANCH\", \"session_id\": \"$ISOLATE_SESSION_ID\"}"
    echo "⚠️  cd \"$ISOLATED_WORKTREE_PATH\" перед следующим действием -- рабочий каталог не переключается автоматически, это отдельный процесс bash." >&2
  fi

  # Report stale semaphores of the same agent — WITHOUT quarantining them.
  #
  # WP-484 Ф49 (04.08): this loop used to `mv` every semaphore older than the
  # TTL into `.orphaned-*`. Age alone proves nothing about liveness, so it kept
  # killing sessions that were actively working — live case that triggered the
  # fix: a WP-7 session whose semaphore had been written to one minute earlier
  # was quarantined because `opened_at` was 43 minutes old. Once renamed, the
  # session can no longer close (`close` only selects `*.open`) — that is the
  # mechanism behind Ф49's "delivered work, no formal Quick Close".
  # Liveness is now decided where it matters (scope gate, via `lease_valid`),
  # and quarantine stays only where a real death signal exists: a dead pid in
  # `sweep_orphaned_semaphores` above.
  # WP-464: check EVERY open semaphore of this agent, not only the newest —
  # `head -1` used to leave older-but-still-stale siblings undetected whenever
  # a younger one existed for the same agent_id.
  while IFS= read -r STALE; do
    [ -z "$STALE" ] && continue
    [ -f "$STALE" ] || continue
    # Age by `opened_at:` (when the session actually started), not mtime —
    # WP-484 Нить1 (peer-session 2026-07-31-14-wp484-session-close-discipline):
    # any unrelated append (note-file, a stray write into the wrong semaphore)
    # bumps mtime and resets the TTL clock, which is exactly how a truly
    # abandoned semaphore (WP-507, 30.07) survived auto-orphan for 4.5h while
    # collecting other sessions' files. Falls back to created_at, then to a
    # loud WARN (no more silent mtime fallback — see WP-484 Ф31 below).
    STALE_OPENED_AT=$(grep "^opened_at: " "$STALE" | cut -d' ' -f2- || true)
    STALE_EPOCH=""
    if [ -n "$STALE_OPENED_AT" ]; then
      STALE_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STALE_OPENED_AT" +%s 2>/dev/null \
        || date -u -d "$STALE_OPENED_AT" +%s 2>/dev/null || echo "")
    fi
    # Fallback to mtime is REMOVED to prevent WP-507-style orphan resurrection
    # (append-operations updating mtime restart the TTL clock).
    # If opened_at failed, try created_at (immutable backup added in WP-484 Ф31).
    if [ -z "$STALE_EPOCH" ]; then
      STALE_CREATED_AT=$(grep "^created_at: " "$STALE" | cut -d' ' -f2- || true)
      if [ -n "$STALE_CREATED_AT" ]; then
        STALE_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STALE_CREATED_AT" +%s 2>/dev/null \
          || date -u -d "$STALE_CREATED_AT" +%s 2>/dev/null || echo "")
      fi
    fi
    # Neither timestamp present/parseable (pre-WP-484 semaphore, or corrupt
    # file): this semaphore can NEVER be auto-orphaned now that mtime fallback
    # is gone. Independent code review (01.08) flagged the silent version of
    # this as a scope-gate weakening risk — loud WARN so it surfaces in `audit`
    # and in whatever log captures open's stderr, instead of vanishing.
    if [ -z "$STALE_EPOCH" ]; then
      echo "WARNING: semaphore ($(basename "$STALE")) has no opened_at/created_at — cannot auto-orphan, needs manual cleanup or 'audit' review" >&2
      continue
    fi
    STALE_AGE=$(( $(date +%s) - STALE_EPOCH ))
    if [ "$STALE_AGE" -gt 1800 ]; then
      STALE_WP=$(grep "^wp: " "$STALE" | cut -d' ' -f2- || echo "unknown")
      if lease_valid "$STALE"; then
        echo "NOTE: у агента открыта долгая сессия $(basename "$STALE") (WP: $STALE_WP, возраст ${STALE_AGE}s) — права на коммит действуют, не трогаю" >&2
      else
        echo "WARNING: сессия $(basename "$STALE") (WP: $STALE_WP, возраст ${STALE_AGE}s) потеряла права на коммит." >&2
        echo "         Закрой её (close --wp $STALE_WP) или продли: renew --wp $STALE_WP" >&2
      fi
    fi
  done < <(ls -t "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null || true)

  # Reuse the same id the isolation block above already computed and used to
  # name the worktree/branch -- recomputing "${IWE_SESSION_ID:-$(date +%s)}"
  # here independently could pick a different second and desync the
  # semaphore's session_id from the worktree path already on disk.
  SESSION_ID="${ISOLATE_SESSION_ID:-${IWE_SESSION_ID:-$(date +%s)}}"
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
  # WP-484 (31.07, data-pipeline-audit-2026-07-30.md §3.3): a caller-supplied slug
  # sometimes already carries today's date (Kimi free-text `--slug`, human habit) —
  # confirmed live on real files, e.g. sessions/2026-07/2026-07-31-2026-07-31-wp510-*.md.
  # This is the ONE place that assembles the path, so it's the one place that can
  # enforce "date appears exactly once" regardless of what any caller passes.
  CLEAN_SLUG="${SLUG:-$WP}"
  CLEAN_SLUG="${CLEAN_SLUG#"$(now_date)"-}"
  ORZ_BASENAME="$(now_month)/$(now_date)-${CLEAN_SLUG}.md"
  # gov_repo_dir() (2026-08-12, peer-session close-pipeline-consolidation) --
  # write the ORZ scaffold into the worktree open was actually invoked from,
  # not the global $ORZ_DIR. Deliberately local to this one assembly point,
  # not a reassignment of $ORZ_DIR itself: `close`'s scope-gate check further
  # down still needs $ORZ_DIR at its original canonical value.
  #
  # ORZ_SESSIONS_DIR recorded into the semaphore below (found in code review
  # of this same fix): `close` runs as a separate invocation, possibly from a
  # different cwd/process than `open` (e.g. process-runner.py's
  # session-guard-release.sh handler) -- recomputing gov_repo_dir() there
  # would silently resolve to a DIFFERENT worktree than the one `open` wrote
  # into, and `close` would look for the ORZ file in the wrong place. The
  # semaphore already carries session identity; it's the one place `close`
  # can read back the resolved directory instead of re-deriving it.
  #
  # ORZ_ISOLATE_OVERRIDE (set above, inside the --isolate block, once
  # $ISOLATED_WORKTREE_PATH exists on disk): gov_repo_dir() alone can't see
  # it here, because it resolves the CALLER's cwd, and `--isolate` never cd's
  # this same process into the worktree it just created (that's the caller's
  # own next step, printed as the "⚠️ cd ..." hint above) -- empty outside
  # --isolate, so the fallback below is unchanged for the non-isolate and
  # canonical-owner paths.
  ORZ_SESSIONS_DIR="${ORZ_ISOLATE_OVERRIDE:-$(gov_repo_dir)/sessions}"
  ORZ_FILE="$ORZ_SESSIONS_DIR/$ORZ_BASENAME"
  mkdir -p "$(dirname "$ORZ_FILE")"
  {
    echo "---"
    echo "agent: $AGENT"
    echo "personality: $PERSONALITY"
    echo "wp: $WP"
    echo "task: ${TASK:-}"
    echo "slug: ${SLUG:-$WP}"
    echo "opened_at: $(now_iso)"
    echo "created_at: $(now_iso)"
    echo "session_id: $SESSION_ID"
    # WP-484 Ф101 Находка 1: PostToolUse hooks (post-tool-use-scope-track.sh)
    # only see this env var, never WP/slug -- those are known only to the
    # code calling `open`, not to a hook firing on every later Write/Edit.
    # Recording it here lets the hook match its own semaphore by session
    # instead of a singleton current-<agent>.ptr that gets clobbered by a
    # second concurrent `open` of the same agent.
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && echo "harness_session_id: $CLAUDE_CODE_SESSION_ID"
    # WP-484 Ф118: read by close-runner-gate.sh/close-gate-reminder.sh to pick
    # the enforcement path instead of assuming quick-close for every session.
    echo "close_path: ${CLOSE_PATH:-unknown}"
    # Recorded here so `close` (a separate invocation, possibly a different
    # process/cwd) can read the resolved worktree back instead of
    # recomputing it -- same pattern already used for orz_sessions_dir above.
    [ -n "$ISOLATED_WORKTREE_PATH" ] && echo "isolated_worktree: $ISOLATED_WORKTREE_PATH"
    [ -n "$ISOLATED_WORKTREE_BRANCH" ] && echo "isolated_branch: $ISOLATED_WORKTREE_BRANCH"
    echo "orz_file: $ORZ_BASENAME"
    echo "orz_sessions_dir: $ORZ_SESSIONS_DIR"
    # WP-484 (08.08, Kimi diagnosis + pilot report): regular sessions never
    # recorded a pid at all, so sweep_orphaned_semaphores()'s dead-pid check —
    # the only auto-detection left since age-based quarantine was retired
    # 04.08 — had nothing to grab onto; abandoned semaphores just hung open
    # forever (48 found live 08.08). A caller that knows its long-lived owner
    # passes --owner-pid; Claude Code keeps its stable $CLAUDE_PID fallback.
    # Never substitute this script's $$: it dies immediately after open and
    # would falsely quarantine a still-live session.
    [ -n "${OWNER_PID:-${CLAUDE_PID:-}}" ] && echo "pid: ${OWNER_PID:-$CLAUDE_PID}"
    echo "---"
    # initial --files CSV → append-log entries (git-root-relative expected from caller)
    if [ -n "${FILES:-}" ]; then
      IFS=',' read -ra INITIAL_FILES <<< "$FILES"
      for init_file in "${INITIAL_FILES[@]}"; do
        init_file="$(echo "$init_file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$init_file" ] && echo "file: $init_file"
      done
    fi
    # Ф32 п.5 (WP-484, 31.07): `open` creates the ORZ scaffold itself below — its
    # first commit is a brand-new git path (status A), which the scope gate never
    # mtime-bypasses. Without this line every session's OWN report needed a
    # separate `note-file` call just to survive the gate it forgot about — live-
    # reproduced (mktemp sandbox: open → edit ORZ → git add → pre-commit-check
    # → BLOCK) and matches orphaned untracked ORZ files found sitting in this
    # session's own `git status` from a prior, unrelated WP. Path is relative to
    # $ORZ_DIR's PARENT (governance-repo root — sessions/<...>), same convention
    # every other `file:` line already uses.
    echo "file: $(basename "$ORZ_DIR")/$ORZ_BASENAME"
    # Same class of gap as the ORZ line above (Ф32 п.5), found for --isolate
    # re-entry (peer-session 2026-08-14-13, turn 15, Codex): OPEN_LOG's own
    # append below is a real, expected, this-session side effect --
    # registering it here means the isolate re-entry check (below in this
    # same script) can trust the `file:` allowlist instead of guessing this
    # specific filename by name.
    echo "file: $(basename "$(dirname "$OPEN_LOG")")/$(basename "$OPEN_LOG")"
  # WP-484 Ф72 доводка (живой кейс 21.08, сессия 2026-08-21-02; review r7):
  # маркер пишется ДО публикации семафора — маркер без семафора инертен
  # (resolver требует оба), обратный порядок оставлял бы семафор без маркера.
  if [ "${STANDALONE_LAUNCH:-0}" = "1" ] && [ "$AGENT" = "kimi" ] && [ -n "$SESSION_ID" ]; then
    : > "$IWE_ROOT/.iwe-runtime/kimi-standalone-${SESSION_ID}.marker" 2>/dev/null || true
  fi
  } > "$SEM_FILE"
  # Pointer to active semaphore for PostToolUse hooks
  PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
  echo "$SEM_FILE" > "$PTR_FILE"
  # ORZ scaffold (paths already computed above for the semaphore)
  if [ ! -f "$ORZ_FILE" ]; then
    cat > "$ORZ_FILE" <<EOF
---
date: $(now_date)
type: work
wp: ${WP}
duration_h: ~
agent: $(orz_agent_name "$AGENT")
personality: ${PERSONALITY}
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
  # open-sessions.log — runtime target, not the git-tracked $OPEN_LOG (see
  # OPEN_LOG_RUNTIME declaration above); open-log-snapshot.sh folds this back
  # into $OPEN_LOG periodically.
  printf "%s | %s | %s | %s\n" "$(date '+%Y-%m-%d %H:%M')" "$WP" "$AGENT" "${TASK:-standalone}" >> "$OPEN_LOG_RUNTIME"
  # agent status (fail-safe)
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality "$PERSONALITY" \
      "$AGENT" working "${WP}: ${TASK:-standalone}" "${FILES:-}" 2>/dev/null || true
  fi
  # WP-484 Ф103: audit_runner_cards() at close no longer blocks a session
  # over a FOREIGN card's lifecycle problem -- it records it durably instead
  # (card-audit-findings.jsonl) so it doesn't just vanish unseen. This is the
  # other half of that trade: surface the registry here, non-blocking, so an
  # agent opening a new session notices it exists (Day/Week Close is where
  # someone is expected to actually triage it, per peer-session
  # 2026-08-16-08-wp484-isolate-push-cherry-pick consensus).
  FINDINGS_REGISTRY="$IWE_ROOT/.iwe-runtime/card-audit-findings.jsonl"
  if [ -s "$FINDINGS_REGISTRY" ]; then
    FINDINGS_COUNT=$(wc -l < "$FINDINGS_REGISTRY" | tr -d ' ')
    echo "ℹ️  $FINDINGS_COUNT запись(ей) в findings registry чужих RUN-карточек ($FINDINGS_REGISTRY) — разбор на Day/Week Close, не блокирует эту сессию" >&2
  fi
  echo "Session OPEN: $SEM_FILE (WP: $WP, agent: $AGENT, slug: ${SLUG:-$WP})"
  # version-handshake (WP-484 Ф124/Ф125 план Этапа 0, линия 1, wiring 3а):
  # best-effort, never blocks open -- iwe-version.sh itself degrades to
  # "unknown" on a Mac host (no iwe-release.json there by design, see its
  # own header comment), this is just surfacing that line where an agent
  # will actually see it.
  IWE_VERSION_SCRIPT="$IWE_ROOT/scripts/iwe-version.sh"
  [ -x "$IWE_VERSION_SCRIPT" ] && "$IWE_VERSION_SCRIPT" 2>/dev/null || true
  exit 0
fi

# --- helpers for ORZ validation ---
validate_orz() { # <orz-path> <agent> [orz-base-dir, default $ORZ_DIR]
  local orz="$1"
  local agent="$2"
  # WP-520 (14.08, found live closing a worktree session): the git-tracked
  # check below used to hardcode $ORZ_DIR (canonical) even when the caller's
  # ORZ file lives in an isolated worktree -- close() already resolves the
  # correct worktree path into $ORZ_SESSIONS_DIR (open() wrote it into the
  # semaphore), this function just wasn't told about it, so relpath computed
  # garbage like "../../other-worktree/sessions/...". The audit() call site
  # has no worktree concept (scans the whole canonical tree), so it keeps
  # relying on the default.
  local orz_base_dir="${3:-$ORZ_DIR}"
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
  local rel
  rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[3]))" -- "$orz" "$orz_base_dir")"
  if ! git -C "$orz_base_dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    # WP-520 case 8 (11.08, peer session with Kimi): a session whose commit went
    # to main through an isolated worktree cannot stage the file in the live
    # checkout (busy on a foreign branch) -- session-guard-release inside the
    # runner hit exactly this refusal (release log 17:08Z, WP-523 run). A file
    # present in ANY published remote-tracking ref is a strictly stronger proof
    # than a staged-only file: accept it as the index-equivalent. The ":./"
    # prefix keeps the path relative to orz_base_dir, matching how rel was built.
    local published_ref=""
    local remote_ref
    while IFS= read -r remote_ref; do
      [ -z "$remote_ref" ] && continue
      # Content must match too (review-01 Medium): path-only acceptance would
      # let a locally edited copy pass on legacy semaphores that have no
      # registered `file:` line for the scope gate's cmp to catch.
      if git -C "$orz_base_dir" cat-file -e "$remote_ref:./$rel" 2>/dev/null &&
         git -C "$orz_base_dir" cat-file blob "$remote_ref:./$rel" 2>/dev/null | cmp -s - "$orz"; then
        published_ref="$remote_ref"
        break
      fi
    done <<< "$(git -C "$orz_base_dir" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)"
    if [ -n "$published_ref" ]; then
      echo "  ✓ ORZ-файл не в git index, но побайтно совпадает с опубликованным blob в '$published_ref' — принят как эквивалент" >&2
    else
      echo "  ❌ ORZ-файл не добавлен в git index (git add $rel) и не совпадает ни с одним blob в refs/remotes/*" >&2
      errors=$((errors + 1))
    fi
  fi

  return $errors
}

# Closing a session is safe only after its own registered scope is clean.  The
# Quick Close card proves that the process reached a terminal step, but it does
# not prove that all files written by the session made it into a commit.  In a
# shared checkout, removing the semaphore first lets the sync timer rebase over
# that residue or turn it into a chronic dirty-tree alert.
# WP-520 case 8 (11.08, peer session with Kimi): the isolated-worktree flow
# commits session files to main while the live checkout sits on a foreign
# branch -- an identical untracked copy stays behind and used to block close as
# "uncommitted work". Content-identical to a published remote blob means the
# work is already safe; any difference stays a blocker (fail-closed).
_untracked_matches_published() { # <repo> <root-relative path> — 0 if an identical blob exists in refs/remotes/*
  local repo="$1" rel="$2" ref
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if git -C "$repo" cat-file -e "$ref:$rel" 2>/dev/null &&
       git -C "$repo" cat-file blob "$ref:$rel" 2>/dev/null | cmp -s - "$repo/$rel"; then
      return 0
    fi
  done <<< "$(git -C "$repo" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)"
  return 1
}

# ArchGate 2026-08-18 (WP-484 "case Б-1"): both refs/remotes readers above
# compare against whatever was cached at the LAST fetch, which can predate a
# push made seconds ago -- a false "not yet published" block. review_date:
# 2026-11-18 (revisit whether this is still the right tradeoff once close
# frequency or origin latency changes materially).
# timeout, not fail-closed like open --isolate's fetch (line ~1067): close
# already runs many times a day across parallel agents on one origin, so a
# slow/offline network must degrade to today's cache-only behaviour, not
# block every close on it.
REMOTE_REFS_REFRESHED_FOR_CLOSE=0
_refresh_remote_refs_for_close() { # <repo> — best-effort fetch, once per close, before any refs/remotes read
  local repo="$1"
  [ "$REMOTE_REFS_REFRESHED_FOR_CLOSE" = "1" ] && return 0
  REMOTE_REFS_REFRESHED_FOR_CLOSE=1
  if ! timeout 3 git -C "$repo" fetch origin --quiet 2>/dev/null; then
    echo "  ⚠️  git fetch перед сверкой с опубликованным не удался/не уложился в 3с -- сверяю по кэшу refs/remotes (может быть устаревшим)" >&2
  fi
}

# WP-520 Ф8: session-index.md is append-only (each session adds one row above
# the table), so concurrent writers resolve as a plain git add/add merge --
# unlike the exclusive files a single session owns. Scoped to this one file,
# not every shared file: umbrella WP-N.md takes point-edits to a phase, not a
# pure append, so it keeps the strict check.
APPEND_SAFE_PATHS="$(basename "$ORZ_DIR")/00-index.md"

session_scope_dirty_paths() { # <semaphore> — prints only dirty registered paths
  local semaphore="$1" registered_path status scope_repo_dir runner_card
  # The ORZ snapshot names the worktree that owns this session.  Checking the
  # canonical checkout here makes unrelated current work look like this
  # session's dirt and permanently blocks a clean isolated close.
  scope_repo_dir="$(dirname "$ORZ_SESSIONS_DIR")"
  if [ ! -d "$scope_repo_dir/.git" ] && [ ! -f "$scope_repo_dir/.git" ]; then
    scope_repo_dir="$(dirname "$ORZ_DIR")"
  fi
  while IFS= read -r registered_path; do
    registered_path="${registered_path#file: }"
    [ -n "$registered_path" ] || continue
    case " $APPEND_SAFE_PATHS " in *" $registered_path "*) continue ;; esac
    # The runner writes its terminal state after the last commit/push.  That
    # self-update is the proof close reads below, so treating the completed
    # card as ordinary dirty work creates a release deadlock.  Non-terminal
    # cards remain in the strict path and still block the session.
    case "$registered_path" in
      inbox/agent/tasks/RUN-quick-close-*.md)
        runner_card="$scope_repo_dir/$registered_path"
        if [ -f "$runner_card" ] \
           && grep -q '^process_id: quick-close$' "$runner_card" \
           && grep -q '^status: completed$' "$runner_card"; then
          continue
        fi
        ;;
    esac
    # -c core.quotePath=false (WP-484 Ф96 class-sweep, 15.08): plain --porcelain
    # C-quotes non-ASCII paths, so ${status_line:3} below fed a quoted form to
    # _untracked_matches_published which then never matched the published blob --
    # a worktree-delivered session with Cyrillic filenames (every sessions/*.md
    # here) falsely blocked at close. Likely the root of the 13.08 "close gate
    # cannot recognize worktree delivery" recurrences.
    status=$(git -c core.quotePath=false -C "$scope_repo_dir" status --porcelain --untracked-files=all -- "$registered_path" 2>/dev/null || true)
    [ -z "$status" ] && continue
    while IFS= read -r status_line; do
      [ -n "$status_line" ] || continue
      case "$status_line" in
        # ' M' (tracked, modified vs the parked foreign branch's HEAD) joins
        # '??' for the same reason: a shared checkout parked on another agent's
        # branch legitimately carries main's newer version of shared scripts.
        "?? "*|" M "*)
          _untracked_matches_published "$scope_repo_dir" "${status_line:3}" && continue
          ;;
      esac
      printf '  %s: %s\n' "$registered_path" "$status_line"
    done <<< "$status"
  done < <(grep '^file: ' "$semaphore" | sort -u)
}


audit_runner_cards() {
  # WP-7 Ф76: a RUN-card may be an untracked, worktree-local queue artifact.
  # Closing a session must not silently pass after an external remover made a
  # previously journalled card disappear. The runner owns the audit format, so
  # this gate delegates both the scan and its fail-closed decision to it.
  #
  # WP-484 Ф103 (peer-session 2026-08-16-08-wp484-isolate-push-cherry-pick,
  # live case: a healthy close blocked by five unrelated stuck cards from
  # OTHER sessions, 2026-08-16): the scan still covers every card in the
  # repo, but the fail-closed verdict is scoped to this session's own cards
  # by SLUG. A foreign session's broken card is a real problem -- it still
  # gets recorded durably by the runner (card-audit-findings.jsonl) -- but it
  # is not this session's problem to be blocked by; `open` surfaces the
  # registry so it doesn't just accumulate unseen.
  # WP-484 Ф119/Ф125 (2026-08-21): process-runner.py now resolves its ROOT via
  # `git rev-parse --show-toplevel` from cwd (fail-loud on mismatch), not from
  # its own file location -- every call site here that invoked it without a
  # cd into $GOV_REPO first (this one and the three below) relied on the old
  # resolver's cwd-independence, silently. Live-caught closing THIS session's
  # own semaphore, run from $IWE_ROOT (the documented cwd for session-guard.sh
  # itself, protocol-close.md).
  local audit_output
  if audit_output=$(cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" audit-cards --session-slug "${SLUG:-}" 2>&1); then
    if printf '%s' "$audit_output" | grep -q '"foreign_findings_recorded": [1-9]'; then
      echo "⚠️  найдены чужие RUN-карточки, не прошедшие проверку жизненного цикла -- close этой сессии НЕ блокирую, записал в findings registry для разбора" >&2
    fi
    return 0
  fi
  printf '%s\n' "$audit_output" >&2
  fail "RUN-карточки этой сессии не прошли проверку жизненного цикла; close остановлен до снятия семафора." 7
}

# --- CLOSE ---
if [ "$CMD" = "close" ]; then
  if [ -n "$HOUSEKEEPING" ]; then
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    if [ ! -f "$HK_FILE" ]; then
      fail "close --housekeeping: нет активной housekeeping-сессии '${HOUSEKEEPING}' для $AGENT" 3
    fi
    mv "$HK_FILE" "${HK_FILE}.closed" 2>/dev/null || rm -f "$HK_FILE"
    rm -f "${HK_FILE}.lease"
    echo "Housekeeping CLOSE: ${HOUSEKEEPING} ✅"
    exit 0
  fi

  # WP-537 (19.08, пир-сессия с Codex): --session-id обходит select_semaphore()
  # напрямую, по тому же формату имени файла, что уже использует `renew`
  # (см. resolve_semaphore_by_session_id выше, найдено /verify как P2) --
  # при двух открытых сессиях одного РП это единственный селектор,
  # гарантированно указывающий на одну карточку. Конфликт с явно переданными
  # --wp/--slug -- отказ, не молчаливый игнор (тот же принцип, что уже
  # применён к паре --wp+--slug внутри select_semaphore, комментарий WP-484
  # Ф49): совпало неоднозначно -- откажи, не угадывай.
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") \
      || fail "close: --session-id $SESSION_ID_ARG не резолвится (см. диагностику выше)" 3
  else
    SEM_FILE=$(select_semaphore "$AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 3
    if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
      fail "close без open: семафор не найден для $AGENT. Сначала session-guard.sh open --wp WP-N" 3
    fi
  fi
  WP_FROM_SEM=$(grep "^wp: " "$SEM_FILE" | cut -d' ' -f2- || true)
  WP="${WP:-$WP_FROM_SEM}"
  SLUG_FROM_SEM=$(grep "^slug: " "$SEM_FILE" | cut -d' ' -f2- || true)
  SLUG="${SLUG:-$SLUG_FROM_SEM}"
  TASK_FROM_SEM=$(grep "^task: " "$SEM_FILE" | cut -d' ' -f2- || true)
  TASK="${TASK:-$TASK_FROM_SEM}"
  SESSION_ID=$(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo "unknown")
  PERSONALITY_FROM_SEM=$(grep "^personality: " "$SEM_FILE" | cut -d' ' -f2- || true)
  PERSONALITY_FROM_SEM="${PERSONALITY_FROM_SEM:-unassigned}"

  ORZ_BASENAME=$(grep "^orz_file: " "$SEM_FILE" | cut -d' ' -f2- || true)
  if [ -z "$ORZ_BASENAME" ]; then
    # Fallback для старых семафоров без поля orz_file
    OPENED_DATE=$(grep "^opened_at: " "$SEM_FILE" | cut -d' ' -f2- | cut -dT -f1 || true)
    OPENED_DATE="${OPENED_DATE:-$(now_date)}"
    ORZ_BASENAME="${OPENED_DATE:0:7}/${OPENED_DATE}-${SLUG:-$WP}.md"
  fi
  # Read back the directory `open` actually resolved via gov_repo_dir() (found
  # in code review 2026-08-12, same peer-session as the open-side fix): re-
  # deriving gov_repo_dir() here would resolve against THIS invocation's cwd,
  # which can differ from open's (a separate process, e.g. process-runner.py's
  # session-guard-release.sh handler) and silently point at the wrong
  # worktree. Semaphores written before this fix have no such field --
  # canonical $ORZ_DIR is the correct fallback for them, since that's where
  # open put the file at the time.
  ORZ_SESSIONS_DIR=$(grep "^orz_sessions_dir: " "$SEM_FILE" | cut -d' ' -f2- || true)
  ORZ_SESSIONS_DIR="${ORZ_SESSIONS_DIR:-$ORZ_DIR}"
  ORZ_FILE="$ORZ_SESSIONS_DIR/$ORZ_BASENAME"

  # WP-484 Ф99 (2026-08-15, peer session with Kimi; live case: РП524, three
  # semaphores left stuck after the agent removed their worktrees by hand):
  # ORZ_SESSIONS_DIR is a snapshot of where `open` resolved the worktree at
  # session start. The runner's own delivery step (session-guard-release)
  # copies the ORZ file into the canonical repo on push -- by the time close
  # runs, the worktree that produced it may be long gone, but the file is not
  # lost, it moved. Falling back to the canonical path only when the snapshot
  # path is genuinely absent (not a broader "prefer canonical" change) keeps
  # every other worktree-close path -- including the concurrent-session
  # blocking that isolate mode exists for -- exactly as it was.
  if [ ! -f "$ORZ_FILE" ] && [ "$ORZ_SESSIONS_DIR" != "$ORZ_DIR" ]; then
    CANONICAL_ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"
    if [ -f "$CANONICAL_ORZ_FILE" ]; then
      echo "  ⚠️  ORZ не найден по snapshot-пути ($ORZ_FILE, worktree убран) — использую канонический: $CANONICAL_ORZ_FILE" >&2
      ORZ_SESSIONS_DIR="$ORZ_DIR"
      ORZ_FILE="$CANONICAL_ORZ_FILE"
    fi
  fi

  _refresh_remote_refs_for_close "$ORZ_SESSIONS_DIR"

  echo "Session CLOSE: проверяю ORZ $ORZ_FILE ..."
  if ! validate_orz "$ORZ_FILE" "$AGENT" "$ORZ_SESSIONS_DIR"; then
    fail "ORZ не прошёл валидацию. Исправь замечания выше и повтори close. Семафор остаётся активным." 5
  fi

  SCOPE_DIRTY=$(session_scope_dirty_paths "$SEM_FILE")
  if [ -n "$SCOPE_DIRTY" ]; then
    echo "Session CLOSE: в зарегистрированной области остались незакоммиченные файлы:" >&2
    printf '%s\n' "$SCOPE_DIRTY" >&2
    fail "Сначала зафиксируй и отправь перечисленные файлы. Семафор остаётся активным." 7
  fi

  # Quick Close — не текстовая декларация: именно терминальная карточка раннера
  # доказывает, что эта сессия прошла обязательный процесс. Сопоставление по slug
  # не даёт чужой параллельной карточке закрыть текущую сессию. Для isolate-сессии
  # карточка создаётся в том же worktree, что и ORZ: канонический checkout не
  # обязан содержать её untracked-копию. Список ограничен snapshot-путём из
  # выбранного семафора, а не поиском по произвольным worktree.
  RUNNER_CARD_DIRS=("$IWE_ROOT/$GOV_REPO/inbox/agent/tasks")
  ISOLATED_REPO_DIR=$(dirname "$ORZ_SESSIONS_DIR")
  if [ "$ISOLATED_REPO_DIR" != "$IWE_ROOT/$GOV_REPO" ]; then
    RUNNER_CARD_DIRS+=("$ISOLATED_REPO_DIR/inbox/agent/tasks")
  fi
  RUNNER_CARDS=()
  for runner_dir in "${RUNNER_CARD_DIRS[@]}"; do
    for card in "$runner_dir"/RUN-quick-close-"${SLUG}"*.md; do
      [ -f "$card" ] && RUNNER_CARDS+=("$card")
    done
  done
  RUNNER_OK=""

  # WP-484 Ф118 (19.08, пир-сессия с Codex): сессия, открытая с "open
  # --close-path peer-session", по определению никогда не создаёт
  # RUN-quick-close-*.md — её протокол закрытия (DP.SC.154 Шаг 4.5.1/4.5.2)
  # прямой git commit, не раннер. Коммит ce0ab8ed того же дня легализовал
  # это в close-runner-gate.sh/close-gate-reminder.sh, но не здесь — живой
  # рецидив на параллельной сессии (macOS, WP-484 сама же тема) поймал
  # именно этот пробел: раннер-требование ниже применялось безусловно.
  # Синтетический sentinel по образцу cancel-obligation-ветки (WP-537, ниже)
  # — не файл карточки, downstream-очистка это уже умеет различать. Ключ —
  # $SLUG, не harness_session_id: последний пишется в семафор, только если
  # $CLAUDE_CODE_SESSION_ID был уже установлен на момент open (независимо
  # задокументированная гонка — см. пилотский разбор той же сессии), и
  # опора на него здесь сделала бы этот bypass ненадёжным именно в сценарии,
  # где он нужнее всего. close_path сам по себе — достаточное свидетельство.
  # Должен идти ПОСЛЕ "RUNNER_OK=\"\"" выше — иначе сброс стирает значение.
  if grep -q '^close_path: peer-session$' "$SEM_FILE" 2>/dev/null; then
    RUNNER_OK="declared-peer-session:$SLUG"
    FORCED_CARD="declared-peer-session:$SLUG"
    echo "Session CLOSE: close_path=peer-session объявлен при open — раннер не требуется (WP-484 Ф118)." >&2
  fi

  # "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}", not "${RUNNER_CARDS[@]}": a
  # peer-conversation close (no RUN-quick-close-* card ever written) leaves
  # RUNNER_CARDS empty, and macOS ships bash 3.2 (GPLv3 freeze) where `for x
  # in "${ARR[@]}"` on a zero-length array is an unbound-variable error under
  # `set -u` -- fixed only in bash 4.4+ (2016). Same fix applied to the two
  # other RUNNER_CARDS loops below (bug-2026-08-16-session-guard-close-
  # bash32-empty-array-unbound.md, DS-my-strategy/inbox/bugs, live-crashed
  # 2026-08-16-08-wp521-fragment-provenance-schema).
  for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
    grep -q '^process_id: quick-close$' "$card" || continue
    grep -q '^status: completed$' "$card" || continue
    RUNNER_OK="$card"
    break
  done

  # WP-520 Ф4 (2026-08-11, пир-сессия с Codex; review-01 «deadlock by
  # construction»): close вызывается и ИЗНУТРИ раннера — шаг session-guard-release
  # исполняется до того, как карточка физически может стать completed. Узкий
  # carve-out той же формы, что force-no-reflection ниже: карточка доказывает,
  # что прогон именно quick-close дошёл до самого release-шага (current_step) и
  # прошёл верификацию чеклиста (непустой verdict) — любое другое промежуточное
  # состояние по-прежнему отказ.
  if [ -z "$RUNNER_OK" ]; then
    for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
      grep -q '^process_id: quick-close$' "$card" || continue
      grep -q '^current_step: session-guard-release$' "$card" || continue
      grep -qE '^[[:space:]]*verdict:[[:space:]]*[^[:space:]]' "$card" || continue
      # yaml-пустышки (null/~/'') матчатся паттерном выше — отсечь отдельно
      grep -qE '^[[:space:]]*verdict:[[:space:]]*(null|~|""|'\'\'')[[:space:]]*$' "$card" && continue
      RUNNER_OK="$card"
      break
    done
  fi

  # WP-537 (19.08, пир-сессия с Codex): карточка, отменённая ИМЕННО на шаге
  # архивации (wp-archive-run), признаётся терминальной без ручного флага --
  # но ledger-событие пишется всегда, тем же путём, что раньше был доступен
  # только через --force-no-reflection (та ветка ниже теперь принимает только
  # blocked-witness-unavailable -- ревью нашло, что не слитые ветки на одной
  # и той же форме карточки молча теряли явно переданную пилотом причину).
  # К этому шагу конвейер уже обязан был пройти commit-push-check -- в
  # quick-close.yaml единственный путь дальше commit-push лежит через
  # reflection-gate, а туда пускает либо all_pushed:true (commit-push-check),
  # либо commit_needed:false (commit-push-gate-fallback) -- push-инвариант
  # ниже не перестраховка, а чтение уже доказанного конвейером факта. Живая
  # инвентаризация 207 cancelled-карточек (пир-сессия 2026-08-19-13-wp537-
  # session-guard-close) показала: самый частый случай (blocked-witness-
  # unavailable, 52/207) сюда сознательно НЕ включён -- на этом шаге ещё не
  # сделаны session-reflection-append/release, session-ledger-append,
  # wp-archive, ke-routing, memory-update, verify-r23 (почти весь хвост
  # конвейера), и это симптом отдельного нерасследованного бага витнес-канала
  # (WP-537, живая находка не по этой фазе) -- автозакрытие спрятало бы баг
  # и создало бы дыры в учёте, а не починило бы проблему.
  if [ -z "$RUNNER_OK" ]; then
    for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
      grep -q '^process_id: quick-close$' "$card" || continue
      grep -q '^current_step: wp-archive-run$' "$card" || continue
      grep -q '^status: cancelled$' "$card" || continue
      grep -qE '^[[:space:]]*(all_pushed: true|commit_needed: false)$' "$card" || continue
      RUNNER_OK="$card"
      FORCED_CARD="$card"
      break
    done
    if [ -n "$RUNNER_OK" ]; then
      # Причина явного --force-no-reflection (если пилот его передал) идёт в
      # тот же ledger-эвент, что раньше писала только флаговая ветка -- иначе
      # причина молча терялась бы для этой же формы карточки (ревью, Critical).
      ARCHIVE_REASON="${FORCE_NO_REFLECTION:-auto: wp-archive-run cancelled with proven push (WP-537)}"
      ARCHIVE_EVENT=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "card": sys.argv[4], "reason": sys.argv[5]}))
' "$WP" "$SLUG" "$AGENT" "$FORCED_CARD" "$ARCHIVE_REASON")
      bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_closed_no_reflection "$ARCHIVE_EVENT" session-guard
      echo "wp-archive-run отменён, push подтверждён -- закрываю автоматически ($FORCED_CARD), причина записана в ledger (WP-537)" >&2
    fi
  fi

  # --force-no-reflection (WP-484, 08.08, пилот): рефлексия про настроение дня
  # блокирует close, даже когда содержательная работа (commit+push) уже
  # подтверждена картой раннера — живой разбор показал, что вопрос рефлексии
  # часто рендерится ПОСЛЕ команды «закрывай», пилот её физически не видит.
  # Bypass узкий и предметный, не общий «пропусти карту раннера»: требует
  # ИМЕННО current_step: blocked-witness-unavailable и подтверждённый push —
  # любой ДРУГОЙ сбой раннера (упавший push, отменённый до commit-push прогон)
  # этим флагом по-прежнему не спрятать.
  if [ -z "$RUNNER_OK" ] && [ -n "$FORCE_NO_REFLECTION" ]; then
    for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
      grep -q '^process_id: quick-close$' "$card" || continue
      # WP-537 (19.08): current_step=wp-archive-run+cancelled переехал в
      # безусловную ветку выше -- она сама пишет ledger-событие с этим же
      # FORCE_NO_REFLECTION-текстом, если он передан, так что тот случай
      # сюда больше не попадает (RUNNER_OK уже не пуст). Единственный
      # оставшийся случай, всё ещё требующий явного человеческого флага —
      # содержательная работа уже доставлена, но это не читается из самого
      # конвейера так же однозначно, как wp-archive-run:
      #   blocked-witness-unavailable — исходный случай (08.08): рефлексия
      #   не отрендерилась пилоту. НЕ «любой cancelled» — код-ревью поймал
      #   регрессию именно на этой попытке (тест 2 намеренно проверяет
      #   current_step=commit-push как «сбой, который флаг прятать не
      #   должен»); список шагов сюда добавлять только по одному, с тем же
      #   обоснованием «после commit/push».
      grep -q '^current_step: blocked-witness-unavailable$' "$card" || continue
      # WP-520 (11.08, peer session with Kimi): a session that committed manually
      # before starting the runner (allowed path, bug-2026-07-17) is routed AROUND
      # commit-push by commit-push-gate, so all_pushed never appears in its card.
      # Accept the runner's own measurement instead: gather-session-facts writes
      # commit_needed=false when THIS session has nothing left to commit -- same
      # card, same single interpreter of git state (the gather handler), so the
      # "work is not lost" invariant this bypass guards stays intact.
      grep -qE '^[[:space:]]*(all_pushed: true|commit_needed: false)$' "$card" || continue
      RUNNER_OK="$card"
      FORCED_CARD="$card"
      break
    done
    if [ -z "$RUNNER_OK" ]; then
      fail "force-no-reflection: не нашёл RUN-quick-close-${SLUG}*.md с current_step blocked-witness-unavailable и (all_pushed=true или commit_needed=false) — этот флаг обходит только этот класс отказа (wp-archive-run+cancelled теперь принимается автоматически без флага, см. выше), не любой сбой раннера." 7
    fi
    FORCE_EVENT=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "card": sys.argv[4], "reason": sys.argv[5]}))
' "$WP" "$SLUG" "$AGENT" "$FORCED_CARD" "$FORCE_NO_REFLECTION")
    bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_closed_no_reflection "$FORCE_EVENT" session-guard
    echo "force-no-reflection: закрываю без рефлексии ($FORCED_CARD) — причина записана в ledger" >&2
  fi

  # WP-537 (18.08, пир-сессия с Codex, находка 3 от 16.08/17.08, живьём трижды):
  # close_obligation.py cancel --action cancel-close — явная, аудируемая отмена
  # пилота, записанная событием close_obligation в ledger. Это отдельный трекер
  # терминального состояния от RUN-quick-close-*.md выше и оперирует другим
  # session_id (harness-овый, записан здесь при open как `harness_session_id:`,
  # не epoch-based $SESSION_ID этого семафора) — до сих пор close не знал о нём
  # вообще, поэтому явная отмена пилота не снимала семафор, только TTL-очистка.
  # Узкий, предметный признак (как force-no-reflection выше): требует ИМЕННО
  # ledger-событие close_obligation с action cancel-close/close-override для
  # harness_session_id ЭТОЙ сессии — не отсутствие обязательства вообще
  # (cmd_cancel_status различает эти случаи, см. close_obligation.py).
  if [ -z "$RUNNER_OK" ]; then
    HARNESS_SESSION_ID=$(grep "^harness_session_id: " "$SEM_FILE" | cut -d' ' -f2- || true)
    OBLIGATION_CLI="$IWE_ROOT/$GOV_REPO/scripts/close_obligation.py"
    if [ -n "$HARNESS_SESSION_ID" ] && [ -f "$OBLIGATION_CLI" ]; then
      CANCEL_STATUS=$(python3 "$OBLIGATION_CLI" cancel-status --session-id "$HARNESS_SESSION_ID" 2>/dev/null) || CANCEL_STATUS=""
      if [ -n "$CANCEL_STATUS" ] && [ "$(printf '%s' "$CANCEL_STATUS" | jq -r '.cancelled // false' 2>/dev/null)" = "true" ]; then
        RUNNER_OK="cancel-obligation:$HARNESS_SESSION_ID"
        # Нет реальной карточки раннера -- пусть downstream-очистка (ниже, по
        # тому же признаку, что force-no-reflection) пойдёт по generic-пути
        # cancel-session без --exclude, не пытаясь grep run_id из синтетического
        # RUNNER_OK. FORCED_CARD гарантированно пуст здесь: этот блок выполняется
        # только когда RUNNER_OK ещё пуст, а force-no-reflection выше уже вышел бы
        # с непустым RUNNER_OK, если бы сам его установил.
        FORCED_CARD="cancel-obligation:$HARNESS_SESSION_ID"
        CANCEL_ACTION=$(printf '%s' "$CANCEL_STATUS" | jq -r '.action // "unknown"' 2>/dev/null)
        CANCEL_ACTOR=$(printf '%s' "$CANCEL_STATUS" | jq -r '.actor // "unknown"' 2>/dev/null)
        echo "Session CLOSE: раннер не завершён, но close-обязательство явно отменено пилотом ($CANCEL_ACTION, actor=$CANCEL_ACTOR) — признаю терминальным (WP-537)." >&2
      fi
    fi
  fi

  if [ -z "$RUNNER_OK" ]; then
    # WP-537 (19.08, пир-сессия с Codex): различить в тексте отказа «карточка
    # отменена, но не на автоматически безопасном шаге» от «карточки вообще
    # нет» -- иначе оператор читает один и тот же текст и для «раннер не
    # запускался», и для «запускался, отменён, но это осознанный policy-guard,
    # не поломка» (см. блок current_step: wp-archive-run выше).
    # /verify code (19.08) нашёл: одиночный проход брал ПЕРВУЮ попавшуюся
    # cancelled-карточку — при 2+ карточках одного slug (обычно после
    # повторных попыток раннера) текст мог назвать не тот шаг. Два прохода:
    # сперва целенаправленно ищем wp-archive-run (самое конкретное и
    # действенное сообщение из трёх), и только если такой карточки нет —
    # берём первую любую cancelled для общего сообщения.
    CANCELLED_STEP=""
    for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
      grep -q '^process_id: quick-close$' "$card" || continue
      grep -q '^status: cancelled$' "$card" || continue
      grep -q '^current_step: wp-archive-run$' "$card" || continue
      CANCELLED_STEP="wp-archive-run"
      break
    done
    if [ -z "$CANCELLED_STEP" ]; then
      for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
        grep -q '^process_id: quick-close$' "$card" || continue
        grep -q '^status: cancelled$' "$card" || continue
        CANCELLED_STEP=$(grep '^current_step: ' "$card" | head -1 | cut -d' ' -f2- || true)
        break
      done
    fi
    if [ "$CANCELLED_STEP" = "wp-archive-run" ]; then
      # Шаг правильный, но не прошёл push-инвариант выше -- отдельное
      # сообщение, иначе текст ниже звучит противоречиво («не безопасный
      # шаг», хотя шаг ровно тот, что признаётся безопасным).
      fail "Quick Close не завершён для slug '$SLUG': карточка отменена на шаге wp-archive-run, но push не подтверждён (нет all_pushed:true и commit_needed:false) -- WP-537 признаёт этот шаг терминальным только с доказанным push. Проверь commit-push вручную или попроси пилота об явной отмене (close_obligation.py cancel --action cancel-close)." 7
    elif [ -n "$CANCELLED_STEP" ]; then
      fail "Quick Close не завершён для slug '$SLUG': карточка отменена на шаге '$CANCELLED_STEP' -- это не автоматически безопасный терминальный шаг (только wp-archive-run с доказанным push признаётся без ручного вмешательства, WP-537) и нет отмены close-обязательства. Попроси пилота об явной отмене (close_obligation.py cancel --action cancel-close) или доведи раннер до wp-archive-run/completed." 7
    fi
    fail "Quick Close не завершён для slug '$SLUG': нет terminal RUN-quick-close-${SLUG}*.md и нет отмены close-обязательства (close_obligation.py cancel --action cancel-close) для этой сессии. Сначала запусти process-runner.py start quick-close с тем же --slug, либо попроси пилота об явной отмене." 7
  fi

  # WP-484 Ф87 (пир-сессия с Codex, 11.08): подчистить чужие незавершённые
  # прогоны ЭТОЙ сессии перед тем, как объявить close успешным — иначе они
  # висят до чужого стороннего `start quick-close`, упёршегося в лимит
  # (единственный триггер reap_orphan_cards в process-runner.py), что может
  # не наступить никогда. --exclude только для happy-path RUNNER_OK: он
  # completed.
  if [ -z "${FORCED_CARD:-}" ]; then
    EXCLUDE_RUN_ID=$(grep "^run_id: " "$RUNNER_OK" | head -1 | cut -d' ' -f2- || true)
    # WP-484 Ф119/Ф125: see the cd rationale on audit_runner_cards() above.
    (cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" cancel-session quick-close "$SESSION_ID" \
      --exclude "$EXCLUDE_RUN_ID") 2>&1 || echo "cancel-session (happy path) не прошёл — брошенные прогоны, если есть, останутся до планового reap-orphans" >&2
  else
    # WP-520 (11.08, peer session with Kimi, stuck-dashboard-cards case):
    # cancel-session matches by owner_session_id, which is null for cards
    # started without a harness mapping (Kimi CLI) -- it can never cancel the
    # accepted card, and the card then sits `waiting` on the dashboard until a
    # foreign `start quick-close` or manual cleanup. The accepted card's run_id
    # is known right here: cancel it by address first, keep cancel-session as
    # the sweep for runs that do carry a real owner_session_id.
    # WP-537: FORCED_CARD не всегда файл карточки -- cancel-obligation-путь выше
    # кладёт сюда синтетический sentinel ("cancel-obligation:<id>"), для которого
    # нет реальной карточки и grep корректно ничего не найдёт; 2>/dev/null глушит
    # "No such file or directory" на этом штатном случае, не только на реальном.
    FORCED_RUN_ID=$(grep "^run_id: " "$FORCED_CARD" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
    # WP-484 Ф119/Ф125: see the cd rationale on audit_runner_cards() above.
    if [ -n "$FORCED_RUN_ID" ]; then
      (cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" cancel "$FORCED_RUN_ID") \
        2>&1 || echo "адресный cancel принятой карточки ($FORCED_RUN_ID) не прошёл — причина в строке ERROR выше (уже терминальная карточка при повторном close — штатно)" >&2
    fi
    (cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" cancel-session quick-close "$SESSION_ID") \
      2>&1 || echo "cancel-session (force path) не прошёл — брошенные прогоны, если есть, останутся до планового reap-orphans" >&2
  fi

  audit_runner_cards

  # agent status idle
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality "$PERSONALITY_FROM_SEM" \
      "$AGENT" idle "" "" 2>/dev/null || true
  fi
  mv "$SEM_FILE" "$SEM_FILE.closed" 2>/dev/null || rm -f "$SEM_FILE"
  rm -f "$SEM_FILE.lease"
  # Remove agent pointer
  rm -f "$SESSION_DIR/current-${AGENT}.ptr"
  echo "Session CLOSE: $WP → $ORZ_FILE ✅"
  # version-handshake (WP-484 Ф124/Ф125 план Этапа 0, линия 1, wiring 3а) --
  # same best-effort surfacing as the open-side call above.
  IWE_VERSION_SCRIPT="$IWE_ROOT/scripts/iwe-version.sh"
  [ -x "$IWE_VERSION_SCRIPT" ] && "$IWE_VERSION_SCRIPT" 2>/dev/null || true

  # Push this session's own commits to origin/main, then remove the isolated
  # worktree `open --isolate` created — in that order. Until WP-484 Ф102 this
  # comment claimed "now that push is confirmed" while no push step existed
  # anywhere: a clean (no uncommitted changes) worktree was removed on trust
  # alone, silently discarding any commits that never made it to origin.
  # `isolate-push.sh` closes that gap via cherry-pick, not merge/rebase — see
  # its header and DRR-f102-isolated-push-cherry-pick.md (DS-my-strategy) for
  # why. Design consensus: peer-session
  # 2026-08-16-08-wp484-isolate-push-cherry-pick (Claude + Codex).
  CLOSING_WORKTREE=$(grep "^isolated_worktree: " "$SEM_FILE.closed" 2>/dev/null | cut -d' ' -f2- || true)
  if [ -n "$CLOSING_WORKTREE" ]; then
    ISOLATE_PUSH_SCRIPT="$IWE_ROOT/$GOV_REPO/scripts/isolate-push.sh"
    if [ -x "$ISOLATE_PUSH_SCRIPT" ]; then
      if "$ISOLATE_PUSH_SCRIPT" "$CLOSING_WORKTREE" main; then
        echo "Isolated worktree pushed to origin/main: $CLOSING_WORKTREE"
      else
        PUSH_STATUS=$?
        if [ "$PUSH_STATUS" = "3" ]; then
          echo "⚠️  cherry-pick конфликт при push $CLOSING_WORKTREE — worktree НЕ удаляю, разбор оставлен в выводе isolate-push.sh выше" >&2
          CLOSING_WORKTREE=""
        else
          echo "⚠️  isolate-push.sh не смог запушить $CLOSING_WORKTREE (exit $PUSH_STATUS) — worktree НЕ удаляю, почисти/допуши вручную" >&2
          CLOSING_WORKTREE=""
        fi
      fi
    else
      echo "⚠️  isolate-push.sh не найден по пути $ISOLATE_PUSH_SCRIPT — worktree НЕ удаляю, чтобы не потерять непушнутую работу: git -C $CLOSING_WORKTREE push" >&2
      CLOSING_WORKTREE=""
    fi
  fi
  # Code review (2026-08-20, session-close-hygiene): CLOSING_WORKTREE means
  # "push succeeded", not "worktree is gone" -- a failed `worktree remove`
  # right below (uncommitted stray file, etc.) used to leave it non-empty,
  # so the checklist publish-state computed further down read a physically
  # orphaned worktree as "clean". Separate variable for what it actually is.
  WORKTREE_REMOVED=1
  if [ -n "$CLOSING_WORKTREE" ]; then
    if git -C "$CLOSING_WORKTREE" worktree remove "$CLOSING_WORKTREE" 2>/dev/null; then
      echo "Isolated worktree removed: $CLOSING_WORKTREE"
    else
      echo "⚠️  не удалось убрать изолированный worktree $CLOSING_WORKTREE (возможно есть незакоммиченное) -- почисти вручную: git worktree remove $CLOSING_WORKTREE" >&2
      WORKTREE_REMOVED=0
    fi
  fi

  # Warn if local commits are not pushed in repos touched by this session
  _warn_unpushed() {
    local repo="$1"
    local ahead
    ahead=$(git -C "$repo" rev-list --left-only --count HEAD...origin/main 2>/dev/null || echo "")
    if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
      echo "⚠️  $ahead незапушенных коммита в $(basename "$repo"). Выполни: git -C $repo push" >&2
    fi
  }
  # Always check the ORZ repo (governance repo, $GOV_REPO)
  _warn_unpushed "$ORZ_DIR"
  # Also check repos inferred from file: entries in the semaphore
  # Семафор к этому моменту уже переименован в .closed (выше) — читаем его;
  # fallback на исходное имя, если mv не сработал и файл был удалён.
  _sem_read="$SEM_FILE.closed"
  [ -f "$_sem_read" ] || _sem_read="$SEM_FILE"
  _seen_repos="$ORZ_DIR"
  while IFS= read -r _line; do
    [[ "$_line" =~ ^file:\ (.*) ]] || continue
    _repo=$(git -C "$IWE_ROOT/$(dirname "${BASH_REMATCH[1]}")" rev-parse --show-toplevel 2>/dev/null || true)
    [ -z "$_repo" ] && continue
    echo "$_seen_repos" | grep -qxF "$_repo" && continue
    _seen_repos="$_seen_repos
$_repo"
    _warn_unpushed "$_repo"
  done < <(cat "$_sem_read" 2>/dev/null || true)

  # WP-484 Ф118 backlog (session-close-hygiene peer-session, 2026-08-20):
  # "session-close checklist as the NEXT open's gate" — the gate itself lives
  # in protocol-open.md (Background Gate reads the day ledger), this only
  # gives it a second, direct source: 4 fields recorded straight into the
  # semaphore this close just produced, not just the ledger. publish_state is
  # computed here, not passed by the caller — the caller has no way to know
  # it before this point in the function (it depends on the push attempts
  # just above). result/carry_over stay caller-supplied (--result/--defer):
  # session-guard.sh has no access to what the pilot decided was actually
  # accomplished, only git/process state.
  # Code review (2026-08-20): CLOSING_WORKTREE alone proved push, not
  # cleanup — WORKTREE_REMOVED (set right above, at the actual `worktree
  # remove` call) is the second half needed to tell "no isolation used",
  # "pushed and gone", and "pushed but physically still on disk" apart.
  _publish_state="clean"
  if grep -q '^isolated_worktree: ' "$_sem_read" 2>/dev/null; then
    if [ -z "$CLOSING_WORKTREE" ]; then
      _publish_state="worktree-push-failed"
    elif [ "$WORKTREE_REMOVED" -eq 0 ]; then
      _publish_state="worktree-pushed-not-removed"
    fi
  fi
  {
    echo "checklist_status: closed"
    echo "checklist_result: ${RESULT_ARG:-не указано}"
    echo "checklist_carry_over: ${DEFER_ARG:-нет}"
    echo "checklist_publish_state: $_publish_state"
  } >> "$_sem_read"

  # Best-effort атрибуция ТОЛЬКО для закрытий, обошедших process-runner.py
  # (FORCED_CARD непустой на каждом из 4 bypass-путей выше: peer-session,
  # auto-archive-cancelled, force-no-reflection, cancel-obligation) --
  # r23_verdict их не видит, R23-серия покрывала лишь ~7% реальных закрытий
  # (WP-484 Ф128/Ф131). Условие обязательно: без него событие писалось бы и
  # для нормального завершённого раннера, задваивая r23_verdict тем же
  # смыслом под другим именем (найдено cold-review Ф133, High). Никогда не
  # проваливает close.
  if [ -n "$FORCED_CARD" ] && [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    _cp_from_sem=$(grep "^close_path: " "$_sem_read" 2>/dev/null | cut -d' ' -f2- || echo "unknown")
    _direct_event=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "close_path": sys.argv[4]}))
' "$WP" "$SLUG" "$AGENT" "$_cp_from_sem" 2>/dev/null) || _direct_event=""
    if [ -n "$_direct_event" ]; then
      bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_closed_direct "$_direct_event" session-guard \
        >/dev/null 2>&1 || echo "  ⚠️  ledger session_closed_direct не записан (best-effort, не блокирует close)" >&2
    fi
  fi

  exit 0
fi

# --- NOTE-FILE (manual scope registration for Bash-created/deleted files) ---
if [ "$CMD" = "note-file" ]; then
  FILE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FILE_PATH" ] && fail "note-file: missing path argument" 1
  NOTE_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  # WP-464: resolve via select_semaphore, not the singleton current-<agent>.ptr —
  # the ptr gets clobbered by a second concurrent `open` of the same agent
  # (bug-2026-07-04-ptr-collision), silently writing scope into the wrong session.
  # WP-537 (19.08, пир-сессия с Codex): --session-id — тот же short-circuit, что
  # уже применён к `close` выше (resolve_semaphore_by_session_id, найдено
  # /verify как P2), той же причины ради (две открытые сессии одного РП,
  # --slug не всегда под рукой у вызывающего скрипта/раннера).
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$NOTE_AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") \
      || fail "note-file: --session-id $SESSION_ID_ARG не резолвится (см. диагностику выше)" 1
  else
    SEM_FILE=$(select_semaphore "$NOTE_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
      fail "note-file: нет открытой сессии для агента '$NOTE_AGENT'. Для разовой операции открой housekeeping-сессию:\n  session-guard.sh open --housekeeping note-file --agent $NOTE_AGENT\n  session-guard.sh note-file <path> --agent $NOTE_AGENT\n  git commit ...   # <-- закоммить ДО close: close снимает семафор и коммит перестанет проходить scope gate\n  session-guard.sh close --housekeeping note-file --agent $NOTE_AGENT" 1
    fi
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
    # WP-484 Д2а (15.08, peer-session 2026-08-15-05): no git context -> refuse.
    # The old fallback recorded the raw (often absolute) path verbatim -- the
    # exact registry poison Ф60's reader has to filter out, and a scoped
    # pathspec built from such an entry kills the whole git-status call later.
    fail "note-file: '$FILE_PATH' вне git-контекста (файла нет, и текущий каталог не в репозитории) — запись отклонена, реестр scope принимает только репо-относительные пути. Запусти из корня нужного репозитория или передай существующий путь." 1
  fi
  [ -n "$REL_PATH" ] || fail "note-file: cannot determine relative path for '$FILE_PATH'" 1
  case "$REL_PATH" in
    /*|../*|..)
      # Same Д2а rule for the computed form: an entry escaping the repo root can
      # never byte-match a `git diff --cached` path -- it only breaks the scoped
      # pathspec of every later reader.
      fail "note-file: '$REL_PATH' указывает вне репозитория '$REPO_ROOT' — запись отклонена. Зови note-file из репозитория, которому файл принадлежит." 1
      ;;
  esac
  # A noted path only protects a commit if it byte-matches what `git diff --cached`
  # reports later (repo-relative, no repo-name prefix). A repo-name-prefixed path
  # silently recorded here is bug-2026-07-31-runner-commit-push-stale-retry (gate
  # keeps blocking after an honest-looking registration). Future files (noted
  # BEFORE creation — day-close-mechanical pre-notes archive dest, sessions note
  # files they are about to Write) are legitimate: record verbatim, warn loudly.
  path_known_to_repo() {
    [ -e "$1/$2" ] && return 0
    git -C "$1" ls-files --cached --error-unmatch -- "$2" >/dev/null 2>&1 && return 0
    git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null && return 0
    return 1
  }
  if [ -n "$REPO_ROOT" ] && ! path_known_to_repo "$REPO_ROOT" "$REL_PATH"; then
    REPO_NAME=$(basename "$REPO_ROOT")
    STRIPPED="${REL_PATH#"$REPO_NAME"/}"
    if [ "$STRIPPED" != "$REL_PATH" ] && path_known_to_repo "$REPO_ROOT" "$STRIPPED"; then
      echo "note-file: путь '$REL_PATH' нормализован до репо-относительного '$STRIPPED' (префикс имени репозитория отброшен)" >&2
      REL_PATH="$STRIPPED"
    elif [ "$STRIPPED" != "$REL_PATH" ]; then
      # Prefix textually matches the repo name but neither form exists yet —
      # overwhelmingly the prefix mistake, not a self-named future subdir.
      echo "note-file: WARNING — '$REL_PATH' начинается с имени репозитория '$REPO_NAME/'; записываю без префикса как '$STRIPPED' (scope gate сравнивает репо-относительные пути)" >&2
      REL_PATH="$STRIPPED"
    else
      echo "note-file: WARNING — '$REL_PATH' пока не существует в репо '$REPO_NAME' (ни на диске, ни в индексе, ни в HEAD); записан как будущий файл. Если это опечатка — scope gate не пропустит staged-файл." >&2
    fi
  fi
  # A directory is registered as a directory (QUICKCLOSE-GAPS1 п.2): the trailing
  # slash is what tells the scope gate to cover everything underneath, including
  # files this session has not written yet. Without it a peer session had to
  # re-register each of its own files by hand right before committing.
  if [ -d "$FILE_PATH" ]; then
    case "$REL_PATH" in
      */) ;;
      *) REL_PATH="${REL_PATH}/" ;;
    esac
  fi
  # Avoid duplicate consecutive entries
  LAST=$(tail -1 "$SEM_FILE" 2>/dev/null || true)
  if [ "$LAST" != "file: $REL_PATH" ]; then
    echo "file: $REL_PATH" >> "$SEM_FILE"
  fi

  # WP-484 Ф133 (24.08, пир-сессия с Codex): авто-продление аренды при
  # реальной активности. Живой инцидент Ф132 п.5 -- многораундовая пир-сессия
  # легко превышает 4-часовую аренду (LEASE_SEC), и `pre-commit-check` не
  # различает "мой семафор просрочен" от "чужой" (сверяет ВСЕ .open файлы в
  # системе разом) -- явный `renew` не был вызван никем, потому что никто не
  # заметил приближение дедлайна до самого коммита. `note-file` -- каждый файл
  # сессии, который реально дописывается -- лучший доступный сигнал активности
  # без нового отдельного вызова. Best-effort: неудача не блокирует note-file
  # (та же атомарная запись, что renew -- temp-файл + mv, проверка что семафор
  # ещё жив на случай гонки с параллельным close).
  _LEASE_TMP="${SEM_FILE}.lease.tmp.$$"
  {
    echo "renewed_at: $(now_iso)"
    echo "session_id: $(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo unknown)"
  } > "$_LEASE_TMP" 2>/dev/null
  # Проверка [ -f "$SEM_FILE" ] вплотную к mv (не раньше) -- сужает, но не
  # закрывает TOCTOU-окно с параллельным close (cold-review Ф133, High): mv
  # переименовывает .lease по имени независимо от текущего состояния
  # $SEM_FILE, тот же класс окна, что и в renew выше, только без его fail.
  if [ -s "$_LEASE_TMP" ] && [ -f "$SEM_FILE" ]; then
    mv "$_LEASE_TMP" "${SEM_FILE}.lease" 2>/dev/null || rm -f "$_LEASE_TMP"
  else
    echo "note-file: lease renewal skipped (сессия могла закрыться параллельно)" >&2
    rm -f "$_LEASE_TMP"
  fi

  echo "Noted in scope: $REL_PATH"
  exit 0
fi

# --- HOT-FILE LOCK (WP-7 SessionGitRaceIsolation, 09.08) ---
#
# ArchGate verdict (09.08.2026): a git worktree per session was proposed to stop
# the repeated collisions on the SAME small set of files (DayPlan, an active WP
# card, hypotheses-log.md, MEMORY.md — 18+ documented cases in July, 5 more in
# this single session today, including this very WP-7 card getting clobbered
# mid-edit). Measured live: worktree creation on this repo (21000+ files) costs
# several seconds of "Updating files" AND requires updating every script that
# hardcodes a single $IWE_ROOT/$GOV_REPO path — too much cost for a class of
# collision confined to ~4 files, not the whole tree. This is the cheaper fix
# the ArchGate recommended instead: lock only the files that actually keep
# colliding, not the working tree they live in.
#
# Deliberately a session-guard.sh command, not a Claude-Code-only hook: Kimi and
# Codex peer sessions call this same script for open/close/note-file already
# (its own header: "единый gate ... для всех агентов"), so a lock here is the
# one place that can actually be cross-agent. A PreToolUse:Edit hook would only
# ever see Claude Code's own edits -- today's collisions came from a mix of
# agent types, so a Claude-only mechanism would have caught a fraction of them.
# Enforcement is cognitive for Kimi/Codex until their own instructions call it
# (same class as several findings in GateEnforcement-Audit) -- the FMT hook
# below is defense-in-depth for the one agent type that supports it, not the
# whole fix.
HOT_LOCK_DIR="$IWE_ROOT/.iwe-runtime/hot-file-locks"
HOT_LOCK_TTL_SEC="${IWE_HOT_LOCK_TTL_SEC:-600}"  # 10 min -- long enough for a real edit+commit, short enough that a crashed holder doesn't block the file for a whole session

_hot_lock_slug() {  # _hot_lock_slug <repo-relative-path> -- filesystem-safe lock dirname
  echo "$1" | tr '/' '_'
}

if [ "$CMD" = "lock-hot-file" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "lock-hot-file: missing path argument" 1
  LOCK_HOLDER_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  mkdir -p "$HOT_LOCK_DIR"
  LOCK_PATH="$HOT_LOCK_DIR/$(_hot_lock_slug "$HOT_PATH").lockdir"
  ATTEMPT=0
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    if [ -f "$LOCK_PATH/meta" ]; then
      HELD_AT=$(grep '^locked_at: ' "$LOCK_PATH/meta" 2>/dev/null | cut -d' ' -f2-)
      HELD_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$HELD_AT" +%s 2>/dev/null \
        || date -u -d "$HELD_AT" +%s 2>/dev/null || echo 0)
      AGE=$(( $(date +%s) - HELD_EPOCH ))
      if [ "$AGE" -gt "$HOT_LOCK_TTL_SEC" ]; then
        echo "lock-hot-file: stale lock on '$HOT_PATH' (age ${AGE}s > ttl ${HOT_LOCK_TTL_SEC}s) — reclaiming" >&2
        rm -rf "$LOCK_PATH"
        continue
      fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -gt 30 ]; then
      HOLDER=$(cat "$LOCK_PATH/agent" 2>/dev/null || echo "unknown")
      fail "lock-hot-file: '$HOT_PATH' held by '$HOLDER' for >30s, giving up — retry shortly" 1
    fi
    sleep 1
  done
  {
    echo "locked_at: $(now_iso)"
    echo "agent: $LOCK_HOLDER_AGENT"
  } > "$LOCK_PATH/meta"
  echo "$LOCK_HOLDER_AGENT" > "$LOCK_PATH/agent"
  echo "Locked: $HOT_PATH"
  exit 0
fi

if [ "$CMD" = "unlock-hot-file" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "unlock-hot-file: missing path argument" 1
  LOCK_PATH="$HOT_LOCK_DIR/$(_hot_lock_slug "$HOT_PATH").lockdir"
  rm -rf "$LOCK_PATH"
  echo "Unlocked: $HOT_PATH"
  exit 0
fi

# --- GC-BYPASS-MARKERS (WP-530 "Осталось после Ф9", 19.08 peer-session с Kimi) ---
#
# canonical-dirty-bypass/<hash>/ markers (created around line ~1032 above,
# Ф5) never expire on their own -- each one just records "some agent already
# saw and reported this exact dirty fingerprint", not an incident that needs
# investigation. history.log next to them is the append-only human record
# and is intentionally never touched here; only the per-fingerprint marker
# directories are garbage-collected, by mtime of their `first` file (a marker
# has no owner process to check liveness against, unlike lock-hot-file/
# with_isolate_lock -- age is the only signal available, so this is age-only
# by design, not the PID-first pattern used elsewhere in this file).
if [ "$CMD" = "gc-bypass-markers" ]; then
  GC_TTL_DAYS="${IWE_BYPASS_MARKER_TTL_DAYS:-14}"
  GC_DIR="$IWE_ROOT/.iwe-runtime/canonical-dirty-bypass"
  [ -d "$GC_DIR" ] || { echo "gc-bypass-markers: $GC_DIR отсутствует, нечего чистить"; exit 0; }
  GC_REMOVED=0
  while IFS= read -r -d '' gc_marker; do
    rm -rf "$gc_marker"
    GC_REMOVED=$((GC_REMOVED + 1))
  done < <(find "$GC_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$GC_TTL_DAYS" -print0 2>/dev/null)
  echo "gc-bypass-markers: удалено $GC_REMOVED маркеров старше ${GC_TTL_DAYS}д (history.log не тронут)"
  exit 0
fi

# --- WP-CONTEXT GUARDED EDIT (WP-530 Ф5 п.1, 17.08 peer-session с Kimi) ---
#
# lock-hot-file above only serialises writers -- it never checks whether the
# file changed between the caller reading it and the caller actually writing.
# An LLM agent that sees its edit go through a lock reads that as "protected"
# and stops re-reading before writing -- the exact false confidence that lost
# the WP-530 card's own Ф2 section between sessions on 2026-08-15. This
# command adds the missing check on top of the existing lock, without
# touching lock-hot-file itself (kept a pure filesystem primitive per Kimi's
# single-responsibility argument, turn 1 of this session -- content hashing
# belongs to the caller's semantics, not the lock).
#
# `--expected-hash` has no `auto` fallback on purpose (Kimi's turn-2
# objection, accepted): the hash MUST come from the moment the caller actually
# read the file, which for an LLM agent is tokens -- sometimes minutes --
# before this command runs. Computing it here instead would just narrow the
# race window, not close it, while looking closed.
#
# Scope of the guarantee (Kimi's turn-8 objection, accepted verbatim): guarded
# edit ensures serialization between callers that go through this primitive.
# It does not protect against concurrent modification by external processes
# not using lock-hot-file (e.g. editors with autosave). All write points to
# hot files must go through this primitive; integrating external tools is out
# of scope for WP-530.
if [ "$CMD" = "wp-context-guarded-edit" ]; then
  GUARD_PATH="${POSITIONAL[0]:-}"
  [ -z "$GUARD_PATH" ] && fail "wp-context-guarded-edit: missing path argument" 1
  # Ровно одна из двух семантик обязательна -- ни одной (случайный вызов без
  # проверки версии вообще) и обе сразу (противоречивое намерение: "файла
  # нет" и "вот хэш файла, который я читал" не могут быть верны одновременно)
  # запрещены явно, не оставлены на волю "--expected-hash побеждает".
  if [ -z "$EXPECTED_HASH" ] && [ "$EXPECTED_ABSENT" != "1" ]; then
    fail "wp-context-guarded-edit: нужен --expected-hash (файл читался) или --expected-absent (файла не было)" 1
  fi
  if [ -n "$EXPECTED_HASH" ] && [ "$EXPECTED_ABSENT" = "1" ]; then
    fail "wp-context-guarded-edit: --expected-hash и --expected-absent взаимоисключающие -- выбери одно" 1
  fi
  GUARD_CMD=("${POSITIONAL[@]:1}")
  [ "${#GUARD_CMD[@]}" -eq 0 ] && fail "wp-context-guarded-edit: команда после '--' обязательна" 1

  bash "$0" lock-hot-file "$GUARD_PATH" ${AGENT:+--agent "$AGENT"} >/dev/null

  # `set -e` (top of file) means a failing GUARD_CMD below would otherwise
  # jump straight past unlock-hot-file, leaving the lockdir on disk until its
  # TTL expires -- caught by cold-context review: the error path (a caller
  # like day-close-5g-apply.sh legitimately exiting 1 for LINE_NOT_FOUND) is
  # the COMMON case here, not an edge case, so this isn't optional hardening.
  # A trap fires on any exit from this subshell, not just a plain failing
  # command -- unlike guarding just the one line with `set +e`.
  trap 'bash "$0" unlock-hot-file "$GUARD_PATH" >/dev/null 2>&1' EXIT

  if [ "$EXPECTED_ABSENT" = "1" ]; then
    if [ -f "$GUARD_PATH" ]; then
      {
        echo "CONFLICT"
        echo "expected: absent"
        echo "actual: exists"
        echo "file: $GUARD_PATH"
      } >&2
      exit 1
    fi
  else
    ACTUAL_HASH=""
    if [ -f "$GUARD_PATH" ]; then
      ACTUAL_HASH=$({ shasum -a 256 "$GUARD_PATH" 2>/dev/null || sha256sum "$GUARD_PATH" 2>/dev/null; } | cut -d' ' -f1)
    fi

    if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
      {
        echo "CONFLICT"
        echo "expected_hash: $EXPECTED_HASH"
        echo "actual_hash: ${ACTUAL_HASH:-missing}"
        echo "file: $GUARD_PATH"
      } >&2
      exit 1
    fi
  fi

  set +e
  "${GUARD_CMD[@]}"
  GUARD_STATUS=$?
  set -e
  exit "$GUARD_STATUS"
fi

# --- FREEZE-CANONICAL (WP-520 ADR prototype) ---
# Physical OS-level lock, one layer below the `open`-time protocol check
# (FROZEN_CANONICAL_PATH above): that check only stops writes going through
# `session-guard.sh open` itself, not a direct `git commit`/`Edit` bypassing
# it entirely. `chflags uchg` sets the immutable flag on Darwin (this repo's
# only target platform per environment) -- any write syscall against a
# locked path fails at the kernel, regardless of which tool issued it.
# `-R` is required, not cosmetic: `chflags uchg <dir>` alone only locks the
# directory inode (blocks new files, e.g. `touch`/`git init`) -- existing
# files inside stay writable, confirmed empirically against this exact
# script during the WP-520 peer session that wrote it (2026-08-14).
if [ "$CMD" = "freeze-canonical" ]; then
  FREEZE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FREEZE_PATH" ] && fail "freeze-canonical: missing path argument" 1
  [ -d "$FREEZE_PATH" ] || fail "freeze-canonical: '$FREEZE_PATH' is not a directory" 1
  # Resolve before locking, not the caller-supplied string: if $FREEZE_PATH is
  # (or later becomes, via a symlink swap between this check and `chflags`) a
  # symlink, `chflags -R` on Darwin does NOT follow it into the link target --
  # confirmed empirically same session -- so locking the literal argument can
  # silently protect nothing. Refusing on a symlink is a known, accepted gap
  # for this prototype (peer-session finding, 2026-08-14): it stops the "path
  # is already a symlink" case, not a same-instant swap mid-syscall (TOCTOU
  # proper), which chflags's own atomicity is the only real defense against.
  if [ -L "$FREEZE_PATH" ]; then
    fail "freeze-canonical: '$FREEZE_PATH' is a symlink -- chflags -R does not follow it into the target on Darwin, so locking it protects nothing; pass the resolved path instead" 1
  fi
  if [ "$FORCE_FLAG" != "1" ]; then
    # TODO(WP-520): known gap, not fixed here (peer-session finding,
    # 2026-08-14): this enumeration and the `chflags -R` below are two
    # separate syscalls, not one atomic operation. A semaphore or file
    # created by another process in that window ends up unprotected --
    # `chflags -R` only locks what exists at the moment it runs. Acceptable
    # for a prototype gated on "no open semaphores for the caller"; a
    # production version would need a verify-pass (re-`find` + confirm every
    # path carries `uchg`, retry/fail on mismatch) to close it for real.
    LIVE=$(list_candidates "${AGENT:-${IWE_AGENT:-claude-code}}")
    if [ -n "$LIVE" ]; then
      echo "session-guard: freeze-canonical: agent has open semaphore(s) -- close them first or pass --force:" >&2
      echo "$LIVE" >&2
      exit 1
    fi
  fi
  chflags -R uchg "$FREEZE_PATH" \
    || fail "freeze-canonical: chflags -R uchg failed on '$FREEZE_PATH' (needs owner permission, not root, for user-owned paths)" 1
  echo "Frozen (chflags -R uchg): $FREEZE_PATH"
  exit 0
fi

# unfreeze-canonical used to run `chflags -R nouchg` itself -- any caller,
# agent or pilot, with no distinction between them. Peer-session
# 2026-08-14-13-wp520-two-layer-closing-arch (Codex review) found this was
# exactly the gap the DRR's second layer exists to close: an agent invoking
# this file through a CLI tool is indistinguishable from a pilot typing the
# same command by hand, so the command itself was never actually a barrier.
# A TTY check ([ -t 0 ]) was proposed and rejected in the same session --
# Codex: it's an interface heuristic (a process can hold or fake a PTY
# either way), not a permission boundary. The fix is not a smarter check; it
# is removing the executing path from agent-facing CLI entirely. This name
# now only tells the caller how to do it themselves.
if [ "$CMD" = "unfreeze-canonical" ]; then
  FREEZE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FREEZE_PATH" ] && fail "unfreeze-canonical: missing path argument" 1
  fail "unfreeze-canonical больше не снимает chflags сама -- эта команда предназначена для пилота, вручную, в его собственном терминале: 'chflags -R nouchg $FREEZE_PATH'. Агент: используй 'request-unfreeze-canonical $FREEZE_PATH --reason \"...\"' чтобы зафиксировать запрос -- сама разморозка остаётся ручным действием пилота вне любого агентского CLI." 1
fi

# request-unfreeze-canonical: the agent-facing half of the same boundary.
# Logs a timestamped, append-only request with a nonce and prints the exact
# manual command for the pilot -- it never touches chflags. The guarantee
# this buys is explicit, not implied: a physical safeguard against
# accidental or pipeline writes under one Unix user, not cryptographic
# authorization. The same UID can always run `chflags nouchg` by hand,
# bypassing this file completely -- that limit is a known, accepted
# boundary (Codex, same peer-session), not something a check here could
# close without a second UID or a privileged external operator, which is
# out of scope for this layer.
if [ "$CMD" = "request-unfreeze-canonical" ]; then
  FREEZE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FREEZE_PATH" ] && fail "request-unfreeze-canonical: missing path argument" 1
  [ -z "$UNFREEZE_REASON" ] && fail "request-unfreeze-canonical: --reason обязателен (зачем нужна разморозка)" 1
  UNFREEZE_LOG="$IWE_ROOT/.iwe-runtime/unfreeze-requests.log"
  mkdir -p "$(dirname "$UNFREEZE_LOG")"
  NONCE=$(date +%s%N 2>/dev/null || date +%s)-$$
  {
    echo "---"
    echo "requested_at: $(now_iso)"
    echo "path: $FREEZE_PATH"
    echo "reason: $UNFREEZE_REASON"
    echo "agent: ${AGENT:-${IWE_AGENT:-unknown}}"
    echo "nonce: $NONCE"
    echo "---"
  } >> "$UNFREEZE_LOG"
  echo "Запрос на разморозку зарегистрирован (nonce: $NONCE)."
  echo "Причина: $UNFREEZE_REASON"
  echo ""
  echo "Разморозка -- только вручную, пилотом, в его собственном терминале:"
  echo "  chflags -R nouchg $FREEZE_PATH"
  echo ""
  echo "Эта команда ничего не разморозила -- только записала запрос в $UNFREEZE_LOG."
  exit 0
fi

# --- AUDIT ---
# --- RENEW (WP-484 Ф49) ---
# Продлевает право семафора разрешать коммит. Отдельная команда, а не побочный
# эффект note-file: продление — намеренный сигнал «сессия жива», и связано оно
# с конкретным семафором через имя файла аренды, чтобы активность одной сессии
# не продлевала соседнюю.
if [ "$CMD" = "renew" ]; then
  RENEW_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE="$SESSION_DIR/${RENEW_AGENT}-${SESSION_ID_ARG}.open"
    [ -f "$SEM_FILE" ] || fail "renew: нет открытой сессии ${RENEW_AGENT}-${SESSION_ID_ARG}" 3
  else
    # Отказ при неоднозначности теперь живёт в самом select_semaphore (та же
    # находка Codex касалась и close/note-file), поэтому renew не держит своей
    # копии перебора — достаточно пробросить код возврата.
    SEM_FILE=$(select_semaphore "$RENEW_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
      fail "renew: нет открытой сессии для агента '$RENEW_AGENT' (уточни --wp/--slug/--session-id)" 3
    fi
  fi
  RENEW_SESSION_ID=$(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo "unknown")
  LEASE_TMP="${SEM_FILE}.lease.tmp.$$"
  {
    echo "renewed_at: $(now_iso)"
    echo "session_id: $RENEW_SESSION_ID"
  } > "$LEASE_TMP"
  # Параллельный close мог переименовать семафор, пока мы собирали аренду —
  # тогда публикация создала бы осиротевший .lease и отрапортовала о продлении
  # уже закрытой сессии (Codex, холодное ревью 04.08).
  if [ ! -f "$SEM_FILE" ]; then
    rm -f "$LEASE_TMP"
    fail "renew: сессия $(basename "$SEM_FILE") закрылась во время продления — продлевать нечего" 3
  fi
  # Замена целиком, а не дописывание: файл аренды всегда хранит одно значение,
  # поэтому у читателя нет выбора «первая или последняя запись».
  mv "$LEASE_TMP" "${SEM_FILE}.lease"
  echo "Lease RENEW: $(basename "$SEM_FILE") — права на коммит продлены на $((LEASE_SEC / 60)) мин"
  exit 0
fi

if [ "$CMD" = "audit" ]; then
  # Known gap (2026-08-12, same peer-session as gov_repo_dir()): sections 2-4
  # below scan $ORZ_DIR (canonical checkout) only, not per-session
  # orz_sessions_dir from each semaphore -- an `open` invoked from a worktree
  # writes its ORZ file there, not into canonical, so its session either
  # false-positives as "ORZ отсутствует" (§2) or is silently skipped from the
  # frontmatter/dead-untracked checks (§3-4). Not a correctness gate (nothing
  # here blocks a commit), but it does mean audit output undercounts worktree
  # sessions -- flagged here instead of silently narrowing scope; extending
  # these sections to enumerate `git worktree list` for $GOV_REPO is future
  # work, not done in this pass (kept to the narrower open/close fix agreed
  # with the pilot).
  if [ "$CLEANUP_ORPHANS" -eq 1 ]; then
    sweep_orphaned_semaphores
    echo
    sweep_stale_open_log_entries
    echo
  fi
  SINCE="${SINCE:-$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)}"
  echo "=== Session Guard Audit (since $SINCE) ==="
  echo

  # 1. Активные семафоры (open без close)
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -n "$ACTIVE" ]; then
    echo "⚠️ Активные сессии без close:"
    for f in $ACTIVE; do
      if lease_valid "$f"; then
        echo "  $(basename "$f")"
      else
        # WP-484 Ф49: просроченная аренда — не смерть сессии, а потеря права
        # разрешать коммит. Показываем отдельно, чтобы долг был виден человеку
        # в штатном ритме (Открытие дня читает этот же вывод), а не всплывал
        # внезапным блоком на коммите.
        echo "  $(basename "$f")  ⏳ права на коммит истекли (renew или close)"
      fi
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
      ORZ=$(ls "$ORZ_DIR/${dt:0:7}/$dt"-*"$wp"*.md 2>/dev/null | head -1 || true)
      if [ -z "$ORZ" ]; then
        echo "  $dt | $wp | ORZ отсутствует"
      fi
    done
    echo
  fi

  # 3. ORZ-файлы с невалидным frontmatter/секциями
  echo "ORZ-файлы с дефектами (после $SINCE):"
  find "$ORZ_DIR" -maxdepth 2 -mindepth 2 -name '*.md' -type f ! -name '00-index.md' -newermt "$SINCE" 2>/dev/null | while read -r orz; do
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

# --- RECOVER-ORPHANED (WP-484 Ф49, contract designed 04.08 peer-session
# 2026-08-04-13-session-ttl-f47-draft, ход 1: Codex В4) ---
# Карантинный файл — уже честная терминальная запись места, где сессия
# застряла; переименование обратно в `.open` имитировало бы штатное
# закрытие, которого не было (явно запрещено в записи Ф49). recover-orphaned
# вместо этого пишет отдельное ledger-событие и метит файл — сам файл
# карантина остаётся на диске как есть, историю не переписываем.
if [ "$CMD" = "recover-orphaned" ]; then
  ORPHAN_ARG="${POSITIONAL[0]:-}"
  [ -z "$ORPHAN_ARG" ] && fail "recover-orphaned: missing path argument" 1
  case "$ORPHAN_ARG" in
    /*) ORPHAN_FILE="$ORPHAN_ARG" ;;
    *)  ORPHAN_FILE="$SESSION_DIR/$ORPHAN_ARG" ;;
  esac
  [ -f "$ORPHAN_FILE" ] || fail "recover-orphaned: файл не найден: $ORPHAN_FILE" 1
  # Review post-consensus (одноразовый verification-запрос Codex, 04.08): команда
  # принимала любой путь на диске с подходящим именем — не ослабляет Scope gate
  # (.recovered не даёт прав коммита), но лишняя способность переименовывать файлы
  # вне каталога семафоров. Канонизируем и запираем в $SESSION_DIR, отклоняем
  # symlink и повторный вызов на уже восстановленном файле.
  CANON_FILE=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$ORPHAN_FILE")
  CANON_DIR=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$SESSION_DIR")
  case "$CANON_FILE" in
    "$CANON_DIR"/*) : ;;
    *) fail "recover-orphaned: '$ORPHAN_FILE' вне каталога семафоров ($SESSION_DIR)" 1 ;;
  esac
  [ -L "$ORPHAN_FILE" ] && fail "recover-orphaned: '$ORPHAN_FILE' — символическая ссылка, не карантинный файл" 1
  case "$(basename "$CANON_FILE")" in
    *.recovered) fail "recover-orphaned: '$(basename "$CANON_FILE")' уже восстановлен" 1 ;;
    *.orphaned-*) : ;;
    *) fail "recover-orphaned: '$(basename "$CANON_FILE")' не похож на карантинный семафор (ожидается суффикс .orphaned-*)" 1 ;;
  esac
  grep -qE '^(agent|opened_at|session_id): ' "$ORPHAN_FILE" || \
    fail "recover-orphaned: '$(basename "$CANON_FILE")' не похож на семафор session-guard (нет полей agent:/opened_at:/session_id:)" 1

  REASON=$(basename "$ORPHAN_FILE" | sed -n 's/.*\.orphaned-//p')
  REC_WP=$(grep "^wp: " "$ORPHAN_FILE" | cut -d' ' -f2- || true)
  REC_SLUG=$(grep "^slug: " "$ORPHAN_FILE" | cut -d' ' -f2- || true)
  REC_SID=$(grep "^session_id: " "$ORPHAN_FILE" | cut -d' ' -f2- || echo unknown)
  REC_PATH=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$ORPHAN_FILE" "$IWE_ROOT")

  EVENT_JSON=$(python3 -c '
import json, sys
print(json.dumps({
    "original_path": sys.argv[1],
    "quarantine_reason": sys.argv[2],
    "wp": sys.argv[3] or "unknown",
    "slug": sys.argv[4] or "unknown",
    "session_id": sys.argv[5],
}))
' "$REC_PATH" "$REASON" "${REC_WP:-}" "${REC_SLUG:-}" "$REC_SID")

  # mv ДО ledger-append (не наоборот, review post-consensus Codex): если mv
  # упадёт — ничего не залогировано, retry безопасен. Если бы ledger писался
  # первым и упал mv — retry на уже-переименованном файле молча дал бы
  # дубликат события; здесь повтор просто упрётся в проверку *.recovered выше.
  mv "$ORPHAN_FILE" "${ORPHAN_FILE}.recovered"
  bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_recovered_closed "$EVENT_JSON" session-guard

  echo "Recovered: $(basename "$ORPHAN_FILE") — файл помечен .recovered, session_recovered_closed записан в ledger ($REC_PATH, wp=${REC_WP:-unknown}, session_id=$REC_SID). Исходный карантинный файл НЕ возвращён в .open — это честная терминальная запись, не имитация штатного закрытия."
  exit 0
fi

# A registered directory covers everything under it (QUICKCLOSE-GAPS1 п.2, found
# live 04.08): a peer-conversation opens ONE session directory and then writes a
# dozen files into it as the run goes on. Before this, every one of those files
# needed its own note-file call right before the commit -- 13 calls for a single
# session, and the gate blocked whatever was forgotten, even though `open` had
# already claimed that exact directory. A directory entry is stored with a
# trailing slash, so it can never be confused with a file of the same name.
scope_has_path() {  # scope_has_path <semaphore> <repo-relative-path>
  local sem="$1" path="$2" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ "$entry" = "$path" ] && return 0
    case "$entry" in
      */) case "$path" in "$entry"*) return 0 ;; esac ;;
    esac
  done < <(sed -n 's/^file: //p' "$sem")
  return 1
}

# --- GIT PRE-COMMIT CHECK ---
if [ "$CMD" = "pre-commit-check" ]; then
  # WP-484 Ф49: право разрешать коммит истекает по аренде и отзывается у ВСЕГО
  # набора файлов семафора сразу. Частичный отзыв (запретить только новые
  # `file:`) дыру WP-507 не закрывает: уже перечисленные пути продолжали бы
  # пропускать чужие правки, сделанные после того, как сессия фактически
  # прекратилась. Отсюда же исчезновение mtime-байпаса просроченного семафора —
  # чем он старше, тем больше посторонних файлов проходило «по свежести».
  # Граница механизма (осознанная, не недосмотр): срок проверяется один раз за
  # хук, поэтому коммит, начатый за мгновение до истечения аренды, пройдёт.
  # Повторная проверка перед выходом окно не закрывает — между концом хука и
  # записью объекта git время идёт в любом случае, — а выглядела бы как
  # гарантия атомарности. При сроке в 4 часа «просрочен на доли секунды» и
  # «действителен» описывают одно и то же состояние сессии.
  ALL_OPEN=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  ACTIVE=""
  EXPIRED=""
  for sem in $ALL_OPEN; do
    if lease_valid "$sem"; then
      ACTIVE="${ACTIVE}${sem}"$'\n'
    else
      EXPIRED="${EXPIRED}${sem}"$'\n'
    fi
  done
  ACTIVE="${ACTIVE%$'\n'}"
  EXPIRED="${EXPIRED%$'\n'}"

  # Check 6a (WP-539, peer-session 2026-08-18-08-wp539-tsekh1-sync): an active
  # session can register an isolated worktree via `orz_sessions_dir` and still
  # have its git commands run out of the canonical checkout by inertia (an
  # absolute path in a script, or cwd lost between separate Bash tool calls) --
  # `open` recording the worktree was never enough on its own, nothing checked
  # that later git operations actually executed there. Live-confirmed via git
  # reflog: two unpushed commits (WP-537, WP-484 sessions) landed straight in
  # the canonical checkout despite both semaphores naming a worktree.
  # Scope: only fires when at least one ACTIVE semaphore names a worktree
  # (`orz_sessions_dir` under `.claude/worktrees/` or
  # `.iwe-runtime/isolated-worktrees/`, not the canonical checkout itself) and
  # the current commit's toplevel matches none of them -- a session with no
  # worktree registered is unaffected, same as before this check existed.
  # Warn-only by pilot decision (ArchGate WP-539, 2026-08-18): a hard block
  # here would change how agents work with git before they've had a chance to
  # see it fire on real traffic -- about a week of log-only observation first,
  # hard block is a separate, later change, not bundled into this commit.
  if [ -n "$ACTIVE" ]; then
    CURRENT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    REGISTERED_WORKTREES=""
    MATCHED_TOPLEVEL=0
    for sem in $ACTIVE; do
      # `|| true` on the read, not just the pipeline: under `set -euo pipefail`
      # a semaphore removed by a concurrent session between the `find` above
      # and this loop (routine under parallel agents -- the exact class of
      # race this whole check exists to warn about) would otherwise abort the
      # entire pre-commit-check with a hard exit, turning a warn-only check
      # into an accidental block -- the one outcome the pilot's ArchGate
      # decision explicitly ruled out for this observation week.
      sem_dir=$(sed -n 's/^orz_sessions_dir: //p' "$sem" 2>/dev/null | head -1) || sem_dir=""
      [ -z "$sem_dir" ] && continue
      sem_toplevel="${sem_dir%/sessions}"
      case "$sem_toplevel" in
        */.claude/worktrees/*|*/.iwe-runtime/isolated-worktrees/*)
          REGISTERED_WORKTREES="${REGISTERED_WORKTREES}${sem_toplevel} ($(basename "$sem"))"$'\n'
          [ "$sem_toplevel" = "$CURRENT_TOPLEVEL" ] && MATCHED_TOPLEVEL=1
          ;;
      esac
    done
    if [ -n "$REGISTERED_WORKTREES" ] && [ "$MATCHED_TOPLEVEL" -eq 0 ]; then
      echo "⚠️  SESSION-GUARD (warn-only, WP-539 observation week): зарегистрированная worktree не совпадает с местом выполнения git — коммит НЕ заблокирован." >&2
      echo "" >&2
      echo "Активная сессия зарегистрировала изолированную копию, но эта git-команда выполняется в:" >&2
      echo "  $CURRENT_TOPLEVEL" >&2
      echo "" >&2
      echo "Зарегистрированные worktree активных сессий:" >&2
      while IFS= read -r wt_line; do
        [ -z "$wt_line" ] && continue
        echo "  · $wt_line" >&2
      done <<< "$REGISTERED_WORKTREES"
      # CLAUDE_CODE_SESSION_ID, not CLAUDE_SESSION_ID -- the latter is never
      # set (confirmed bug-2026-08-05-trace-satisfaction-default-session-
      # bucket.md for the same wrong name elsewhere in this file); using it
      # here would collapse every session's warns into one shared `default`
      # bucket, defeating the per-session attribution this log exists for.
      _WARN_LOG="$HOME/.claude/state/session-${CLAUDE_CODE_SESSION_ID:-default}-warns.jsonl"
      mkdir -p "$(dirname "$_WARN_LOG")" 2>/dev/null || true
      python3 -c "
import json, sys
print(json.dumps({
    'ts': sys.argv[1], 'event': 'pre-commit', 'rule': 'WP-539-check6a',
    'verdict': 'warn', 'reason': 'registered worktree does not match git toplevel',
    'current_toplevel': sys.argv[2],
}))
" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CURRENT_TOPLEVEL" >> "$_WARN_LOG" 2>/dev/null || true
    fi
  fi

  if [ -z "$ACTIVE" ]; then
    if [ -n "$EXPIRED" ]; then
      echo "🚫 SESSION-GUARD: коммит заблокирован — у открытых сессий истёк срок полномочий." >&2
      echo "" >&2
      for sem in $EXPIRED; do
        sem_wp=$(grep "^wp: " "$sem" | cut -d' ' -f2- || echo "?")
        echo "  · $(basename "$sem") (WP: $sem_wp)" >&2
      done
      echo "" >&2
      echo "Сессия по-прежнему существует и закрывается штатно. Выбери:" >&2
      echo "  продлить:  bash ~/IWE/scripts/session-guard.sh renew --wp WP-N" >&2
      echo "  закрыть:   bash ~/IWE/scripts/session-guard.sh close --wp WP-N" >&2
      exit 4
    fi
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

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    status="${line%%$'\t'*}"
    f="${line##*$'\t'}"
    status_char="${status:0:1}"

    if [ "$status_char" = "D" ]; then
      # Deleted file: check append-log across all active semaphores
      FOUND=0
      for sem in $ACTIVE; do
        if scope_has_path "$sem" "$f"; then
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

    if [ "$status_char" = "A" ] || [ "$status_char" = "R" ] || [ "$status_char" = "C" ]; then
      # New path (added/renamed/copied): no mtime bypass. A semaphore's mtime
      # is refreshed by every heartbeat, so a long-open session (bug-2026-07-07:
      # Kimi session open 42h) makes "mtime > semaphore" pass for ANY file any
      # OTHER agent happens to touch near commit time — mtime says nothing
      # about whether the file is actually this session's work. New paths must
      # be explicitly declared via note-file.
      FOUND=0
      for sem in $ACTIVE; do
        if scope_has_path "$sem" "$f"; then
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" -eq 0 ]; then
        echo "🚫 BLOCK: $f — новый файл вне scope активных сессий (нужен note-file, mtime не засчитывается)" >&2
        BLOCKED=1
      fi
      continue
    fi

    # Modified existing (already-tracked) file: mtime > semaphore, or explicit
    # note-file append-log entry (needed for files edited before `open` was
    # called — e.g. peer-conversation-skill sessions whose own meta.yaml/
    # report.md already document the session).
    FILE_MTIME=$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$f")
    PASS=0
    for sem_mtime in "${SEMAPHORE_MTIMES[@]}"; do
      if [ "$FILE_MTIME" -gt "$sem_mtime" ]; then
        PASS=1
        break
      fi
    done
    if [ "$PASS" -eq 0 ]; then
      for sem in $ACTIVE; do
        if scope_has_path "$sem" "$f"; then
          PASS=1
          break
        fi
      done
    fi
    if [ "$PASS" -eq 0 ]; then
      echo "🚫 BLOCK: $f не тронут в активных сессиях (mtime <= всех семафоров, нет в note-file)" >&2
      BLOCKED=1
    fi
  done < <(git -c core.quotepath=false diff --cached --name-status)

  if [ "$BLOCKED" -ne 0 ]; then
    echo "" >&2
    echo "Scope gate: staged-файлы вне текущих сессий." >&2
    echo "Если файл относится к сессии, добавь его вручную:" >&2
    echo "  bash ~/IWE/scripts/session-guard.sh note-file <path>" >&2
    echo "Или убери из staged:" >&2
    echo "  git restore --staged <file>" >&2
    # Emit AR.216 warn to rule-engine session warn log
    _SESSION_ID="${CLAUDE_SESSION_ID:-default}"
    _WARN_LOG="$HOME/.claude/state/session-${_SESSION_ID}-warns.jsonl"
    mkdir -p "$(dirname "$_WARN_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","event":"pre-commit","rule":"AR.216","verdict":"warn","reason":"Scope gate: staged files outside active session — use git add <specific-path>"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_WARN_LOG" 2>/dev/null || true
    exit 6
  fi

  exit 0
fi

fail "Unknown command: $CMD (use: open, close, audit, renew, note-file, recover-orphaned, pre-commit-check)"
