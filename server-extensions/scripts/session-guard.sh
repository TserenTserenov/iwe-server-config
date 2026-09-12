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
#   note-commit <sha> [--repo <name>] [--agent ...]   # заявить коммит сессии: даёт commit-push.sh
#                                                      # проверять доставку по СВОИМ коммитам,
#                                                      # а не по состоянию всей ветки (WP-537).
#                                                      # <name> = каталог внутри $IWE_ROOT либо
#                                                      # iwe-root — сам корневой репозиторий
#   note-scheduled-drain --agent <agent> --session-id <UUIDv4>
#                        --owner-pid <PID> --scheduled-run-id <run>
#                                                      # producer attestation after its own
#                                                      # process-group/gate drain checks
#   heartbeat --agent <agent> --session-id <session> --owner-pid <PID>
#                                                      # exact, no-create heartbeat mutation
#                                                      # under the persistent session lock
#   machine-close --agent <agent> --session-id <UUIDv4>
#                                                      # exact machine-owned isolated session;
#                                                      # requires close_path machine-publish-only
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
#                                          # печатает `token: <fencing token>` — предъяви его
#                                          # в check-hot-lock/unlock-hot-file (WP-530 Ф24 п.5)
#   check-hot-lock <path> --token <t>     # держим ли мы ещё замок (0) или его отобрали (1)
#   unlock-hot-file <path> [--token <t>]  # mkdir-замок на файл, который часто
#                                          # коллизирует между параллельными сессиями
#                                          # (DayPlan, активная карточка РП, hypotheses-log,
#                                          # MEMORY.md) — не на всё рабочее дерево
#
# Аренда (WP-484 Ф49): существование сессии и её право разрешать коммит — разные
# вещи. Возраст отзывает только право (по умолчанию 4h, `IWE_SESSION_LEASE_SEC`);
# существование снимает лишь close либо смерть владельца вместе с точным
# terminal/scheduled-drain proof; один dead PID защитный барьер не снимает.
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
# Fail-closed: no silent default for the governance repo. Any default here is
# a liability -- a stale or wrong name causes silent failures in whatever
# reads GOV_REPO downstream, and the caller has no signal that anything went
# wrong (WP-484, peer-session 2026-08-30-28-night-cycle-hooks-fix: traced a
# week of failing automated runs to exactly this -- callers that never set
# the variable got a quietly wrong repo instead of an error).
GOV_REPO="${IWE_GOVERNANCE_REPO:?IWE_ERROR: IWE_GOVERNANCE_REPO is required, no silent default}"
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
# WP-526 Ф2: session content lives in MC-sessions now, not "$GOV_REPO/sessions"
# (cold-review finding, this session -- the original one-liner fix at `open`
# only updated the local variable there, missed this global used by close/
# audit/list further down). Same default as iwe_sessions_root() in
# governance-repo-path.sh (DS-my-strategy) -- not sourced from there to avoid
# a cross-repo dependency in this file (P2 exemption already accepted for
# this exact split, cold-review WP-526 Ф1).
ORZ_DIR="${IWE_SESSIONS_ROOT:-$IWE_ROOT/MC-sessions}"
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

# Prints the frozen checkout the caller is PHYSICALLY sitting in, or nothing.
# The question is "where does this invocation actually stand", not "where would
# a write land" -- gov_repo_dir() answers the second and falls back to $GOV_REPO
# whenever cwd doesn't match it, which made a second frozen path structurally
# unreachable (WP-484 Ф104 smoke test, 2026-08-16). Two callers now: the freeze
# block in `open` and the housekeeping branch above it, which used to exit
# before that block ever ran (WP-484, 2026-09-05).
frozen_checkout_match() {
  [ "${#FROZEN_CANONICAL_PATHS[@]}" -gt 0 ] || return 0
  local toplevel real frozen frozen_real
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  real=$(realpath "$toplevel" 2>/dev/null || echo "$toplevel")
  for frozen in "${FROZEN_CANONICAL_PATHS[@]}"; do
    frozen_real=$(realpath "$frozen" 2>/dev/null || echo "$frozen")
    if [ "$real" = "$frozen_real" ]; then
      echo "$toplevel"
      return 0
    fi
  done
}

# $ORZ_DIR deliberately NOT created here (found 29.08: an unconditional
# `mkdir -p "$ORZ_DIR"` at this point ran before any subcommand-specific
# check could see whether MC-sessions actually existed -- "never existed"
# and "just auto-created empty by this line" became indistinguishable, so
# the fail-closed check inside `open` never actually fired). Creating it
# is now `resolve_orz_sessions_dir`'s job, at the point a subcommand
# actually needs it, over the real pre-existing state.
mkdir -p "$SESSION_DIR" "$(dirname "$OPEN_LOG")" "$(dirname "$OPEN_LOG_RUNTIME")"

CMD="${1:-}"
shift || true

# --- helpers ---
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_date() { date +"%Y-%m-%d"; }
now_month() { date +"%Y-%m"; }
fail() { echo "session-guard: $1" >&2; exit "${2:-1}"; }

# yaml_task_line <value> -- render a "task: <value>" YAML line, quoting the
# value only when PyYAML's own writer decides it needs quoting. session-guard
# used to write this field with a bare `echo "task: $TASK"`: a value
# containing a literal ": " (a real one arrived 2026-09-09, "РП170: R15-триаж
# ...") produced a line no strict YAML parser can read back as a mapping,
# leaving the semaphore ambiguous to any such reader -- see
# bug-2026-09-09-git-wrapper-blocked-by-corrupt-semaphore.md. Delegates to
# PyYAML rather than reimplementing the plain-scalar grammar in bash, and
# falls back to the old bare form if PyYAML is unavailable -- a missing
# dependency degrades to previous behaviour instead of failing `open`. Not
# reused for other semaphore fields (e.g. `housekeeping:`/`slug:`, see the
# comment at their write site) -- those are matched elsewhere by exact
# raw-string equality and doubling as filename components, so quoting them
# would trade this bug for a different one, not just extend the same fix.
# width=10**7 disables PyYAML's default 80-column wrapping (cold review of
# this same fix, 2026-09-10): ordinary prose long enough to exceed 80
# columns -- not an edge case -- was folded onto a continuation line that
# every raw `grep '^task: ' | cut` reader then silently truncated away,
# reintroducing the same corruption class by length instead of by ": ".
# Embedded newlines fold the scalar the same way regardless of width, so
# they are collapsed to spaces first -- this field is documented as
# single-line, not free-form multi-line text.
yaml_task_line() {
  python3 -c '
import sys
value = " ".join(sys.argv[1].splitlines())
try:
    import yaml
except ImportError:
    print("task: %s" % value)
    raise SystemExit(0)
sys.stdout.write(yaml.safe_dump({"task": value}, allow_unicode=True, default_flow_style=False, width=10**7).rstrip("\n"))
' "$1"
}

# clear_peer_session_obligation <semaphore> <slug> -- release the conversation's
# close obligation when a peer session closes (WP-484 "eighth case", peer session
# 2026-09-05-33 with Kimi).
#
# close_obligation.py exempts a conversation from the Stop gate while the NEWEST
# semaphore of that conversation declares `close_path: peer-session`, and a closed
# peer-session semaphore keeps its `.open.closed` file forever -- so the exemption
# outlives the session. Nothing on that path mutates the obligation, so it stays
# armed and every later `process-runner.py start quick-close` in the same
# conversation refuses to start. peer-conversation/SKILL.md Step 4.5.3 clears it,
# but only if the session survives to that step: dying between the close and that
# step leaves the whole conversation stuck. Clearing here removes the window --
# close and clear stop being two steps something can happen between. The skill step
# stays as an idempotent duplicate for conversations on an older copy of this file.
#
# The conversation id comes from the semaphore, not from the environment: another
# process may be doing the closing, and its own CLAUDE_CODE_SESSION_ID would then
# name the wrong conversation. peer-conversation/SKILL.md Step 4.5.3 reads it from
# the environment instead -- the two agree in the normal case (the closing process
# IS the conversation), and the skill step is the fallback for old copies of this
# file, so the difference is not worth a second mechanism here.
#
# Not covered (known, cold review 06.09): sessions whose semaphore carries no
# `close_path: peer-session` -- Kimi writer sessions open theirs outside IWE without
# that flag (WP-561 follow-up), and 5 of 155 closed peer semaphores carry no
# conversation id at all. For those this is a silent no-op and the original defect
# stands; closing that needs the open side fixed, not this one.
#
# `--action peer-session-close` is a no-op while the obligation is `running`: one
# long conversation can span several work products, and an unconditional clear
# would wipe another product's Quick Close still in flight. Never fails the close,
# and time-boxed -- this work product has already had two incidents where a new
# gate hung a session close, and a missed clear is the cheaper of the two.
clear_peer_session_obligation() {
  local semaphore="$1" slug="$2"
  local obligation_cli="$IWE_ROOT/$GOV_REPO/scripts/close_obligation.py"
  [ -f "$obligation_cli" ] || return 0

  local harness_sid
  harness_sid=$(grep '^harness_session_id: ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [ -n "$harness_sid" ] || return 0

  timeout 10 python3 "$obligation_cli" cancel \
    --session-id "$harness_sid" --action peer-session-close --actor session-guard-close \
    --reason "peer-session $slug закрыта через session-guard, обязательство раннера неприменимо" \
    >/dev/null 2>&1 \
    || echo "  ⚠️  close_obligation cancel не прошёл (best-effort, не блокирует close)" >&2
  return 0
}

# emit_session_closed <channel> <semaphore> <wp> <slug> <agent> -- hours for a
# close that bypassed process-runner.py (WP-484, 05.09, peer-session
# 2026-09-05-25 with Kimi). The `session_closed_direct` event written at the end
# of `close` records WHO closed but carries no duration, and every hours consumer
# filters on `kind == "session_closed"` by strict equality (ledger-rollup.sh:384,
# day-close-prepare.sh:438, render-open.py:130,
# day-open-multiplier-backfill-patch.py:142). Live count on 05.09: 7
# `session_closed` against 21 `session_closed_direct` -- three quarters of the
# day's closes were invisible to the very hours CONCEPT-night-cycle.md §8 calls
# the universal source. Pilot decision that session (escalation-00.md): the
# multiplier denominator means machine-hours of ALL sessions, peer ones included
# -- so the fix belongs to the writer and no consumer changes.
#
# Duration comes from the SAME source the runner uses -- `opened_at` of this very
# semaphore, with the Ф38 plausibility band -- so `duration_min` keeps one meaning
# across runner and bypass closes. Measuring a peer session by its own meta.yaml
# was rejected in that session: it measures the conversation, not the session, and
# has no band (a live meta.yaml held -212 minutes that same day).
#
# Never fails the close: like `session_closed_direct`, the ledger is an auxiliary
# channel here, not the purpose of `close`.
emit_session_closed() {
  local channel="$1" semaphore="$2" wp="$3" slug="$4" agent="$5"
  local ledger_script="$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh"
  [ -f "$ledger_script" ] || return 0

  local personality orz_file session_id event_day
  personality=$(grep '^personality: ' "$semaphore" 2>/dev/null | cut -d' ' -f2- || true)
  orz_file=$(grep '^orz_file: ' "$semaphore" 2>/dev/null | cut -d' ' -f2- || true)
  session_id=$(grep '^session_id: ' "$semaphore" 2>/dev/null | cut -d' ' -f2- || true)

  # Event date from the session file, NOT from "today" -- the same rule and the
  # same reason as session-ledger-append.sh:112-116 (cold review 05.09): a close
  # that crosses midnight would otherwise file the whole session's hours under the
  # wrong day, taking them from the day that earned them and giving them to the
  # next one. Both the duplicate check and the write must use this date, or they
  # would consult one day file and write into another.
  event_day=$(printf '%s' "$orz_file" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  [ -n "$event_day" ] || event_day=$(now_date)

  # Idempotency, best-effort by design (Kimi, turn 3: two processes can both read
  # an absent event and both write it -- there is no distributed lock here).
  #
  # Matching by slug alone was wrong (cold review 05.09, Critical): `open` defaults
  # slug to $WP, so two independent sessions of the same WP on the same day share
  # it, and the second close would be silently skipped -- losing exactly the hours
  # this function exists to record. Identity is checked strongest-first: session_id
  # (unique per semaphore), then the session file basename (this is what lets the
  # check ALSO see an event the runner itself already wrote -- its events carry
  # session_file but neither slug nor session_id), then slug as the last resort.
  local ledger_file=""
  if [ -f "$IWE_ROOT/$GOV_REPO/scripts/lib/ledger-path.sh" ]; then
    # shellcheck source=../DS-my-strategy/scripts/lib/ledger-path.sh
    . "$IWE_ROOT/$GOV_REPO/scripts/lib/ledger-path.sh"
    ledger_file="$IWE_ROOT/$GOV_REPO/machine/ledger/$(ledger_path_rel day "$event_day" 2>/dev/null || true)"
  fi
  if [ -n "$ledger_file" ] && [ -f "$ledger_file" ]; then
    local dup=""
    dup=$(LEDGER_FILE_ENV="$ledger_file" SLUG_ENV="$slug" SID_ENV="${session_id:-}" \
      ORZ_ENV="${orz_file:-}" python3 -c '
import os, sys

try:
    import yaml
    with open(os.environ["LEDGER_FILE_ENV"], encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
except Exception as exc:
    # An unreadable ledger is not proof of a duplicate: say so and let the caller
    # write. Silence here would look identical to "checked, nothing found".
    print("unreadable: %s" % exc, file=sys.stderr)
    raise SystemExit(0)

want_sid = os.environ["SID_ENV"]
want_file = os.path.basename(os.environ["ORZ_ENV"])
want_slug = os.environ["SLUG_ENV"]
for event in doc.get("events") or []:
    if not isinstance(event, dict) or event.get("kind") != "session_closed":
        continue
    data = event.get("data") or {}
    if want_sid and str(data.get("session_id") or "") == want_sid:
        print("session_id")
        break
    if want_file and os.path.basename(str(data.get("session_file") or "")) == want_file:
        print("session_file")
        break
    if not want_sid and not want_file and data.get("slug") == want_slug:
        print("slug")
        break
' 2>/dev/null) || dup=""
    if [ -n "$dup" ]; then
      echo "  ℹ️  session_closed уже есть в журнале за $event_day (совпадение по $dup) — не дублирую" >&2
      return 0
    fi
  fi

  local opened observed duration_json known reason max_min
  max_min="${IWE_MAX_SESSION_MIN:-480}"
  observed=0
  duration_json=null
  known=false
  reason="field_missing"
  opened=$(grep -E '^(opened_at|created_at): ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  if [ -n "$opened" ]; then
    local opened_epoch
    opened_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$opened" +%s 2>/dev/null \
      || date -u -d "$opened" +%s 2>/dev/null || true)
    if [ -n "$opened_epoch" ]; then
      observed=$(( ( $(date -u +%s) - opened_epoch ) / 60 ))
      # A negative reading means the clock or the timestamp is wrong, never a real
      # session: it degrades to "unknown with a reason", the same verdict
      # gather-session-facts.sh gives it, never a fabricated zero.
      [ "$observed" -lt 0 ] && observed=0
      if [ "$observed" -le 0 ]; then
        reason="semaphore_zero"
      elif [ "$observed" -gt "$max_min" ]; then
        reason="semaphore_suspicious"
      else
        duration_json="$observed"
        known=true
        reason=""
      fi
    fi
    # An unparsable timestamp keeps reason="field_missing" -- the same value
    # gather-session-facts.sh leaves in that case, so duration_reason stays one
    # shared vocabulary instead of two dialects of the same schema.
  fi

  # Every command substitution below is guarded: this script runs under `set -e`,
  # where a bare `var=$(cmd)` on a failing command kills the whole close (verified
  # empirically 05.09) -- which would break the "never fails the close" contract
  # this function is written to keep, and would do it AFTER the semaphore is
  # already renamed and the push already done.
  local event_err event
  event_err=$(mktemp 2>/dev/null) || event_err=""
  event=$(CHANNEL_ENV="$channel" WP_ENV="$wp" SLUG_ENV="$slug" AGENT_ENV="$agent" \
    PERSONALITY_ENV="${personality:-unassigned}" ORZ_ENV="${orz_file:-}" \
    SID_ENV="${session_id:-}" DURATION_ENV="$duration_json" KNOWN_ENV="$known" \
    OBSERVED_ENV="$observed" REASON_ENV="$reason" python3 -c '
import json, os
duration = os.environ["DURATION_ENV"]
event = {
    "wp": os.environ["WP_ENV"] or "unknown",
    "slug": os.environ["SLUG_ENV"],
    "session_id": os.environ["SID_ENV"],
    "agent": os.environ["AGENT_ENV"] or "unknown",
    "personality": os.environ["PERSONALITY_ENV"],
    "close_channel": os.environ["CHANNEL_ENV"],
    "duration_min": None if duration == "null" else int(duration),
    "observed_duration_min": int(os.environ["OBSERVED_ENV"]),
    "duration_known": os.environ["KNOWN_ENV"] == "true",
    "duration_source": "session_semaphore",
    # turns stays 0: a bypass close has no runner card to count them from, and a
    # made-up number would be indistinguishable from a measured one.
    "turns": 0,
    "session_file": os.environ["ORZ_ENV"],
    "repos": [],
    "status": "completed",
}
if os.environ["REASON_ENV"]:
    event["duration_reason"] = os.environ["REASON_ENV"]
print(json.dumps(event, ensure_ascii=False))
' 2>"${event_err:-/dev/null}") || event=""
  if [ -z "$event" ]; then
    echo "  ⚠️  session_closed не собран для канала $channel: $(cat "${event_err:-/dev/null}" 2>/dev/null)" >&2
    [ -n "$event_err" ] && rm -f "$event_err"
    return 0
  fi
  [ -n "$event_err" ] && rm -f "$event_err"

  bash "$ledger_script" day "$event_day" session_closed "$event" session-guard \
    >/dev/null 2>&1 || echo "  ⚠️  ledger session_closed не записан (best-effort, не блокирует close)" >&2
}

# resolve_orz_sessions_dir -- three-way resolver for the sessions-content
# root (WP-526 Ф2 fix, 29.08). Prints the resolved path on success.
#   1. IWE_SESSIONS_ROOT set explicitly -- always fail-closed if broken,
#      never falls back: an explicit override is a deliberate choice, a
#      silent bypass of it would hide a real misconfiguration.
#   2. Default path ($IWE_ROOT/MC-sessions) exists and is a valid git repo
#      -- the normal case for an already-migrated checkout.
#   3. Default path exists but ISN'T a valid git repo -- looks like a
#      broken migration, not a fresh install. Fail-closed: falling back
#      here would create a second, undetected source of truth for an
#      already-migrated user.
#   4. Default path doesn't exist at all -- genuinely unmigrated (a fresh
#      template install; MC-sessions is created "on demand" per the
#      pilot's 18.08 decision, not at setup time). Legacy fallback to
#      "$GOV_REPO/sessions" with a visible WARN, same behaviour as before
#      WP-526 Ф2 existed.
resolve_orz_sessions_dir() {
  if [ -n "${IWE_SESSIONS_ROOT:-}" ]; then
    if [ -d "$IWE_SESSIONS_ROOT" ] && git -C "$IWE_SESSIONS_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$IWE_SESSIONS_ROOT"
      return 0
    fi
    fail "IWE_SESSIONS_ROOT=$IWE_SESSIONS_ROOT задан явно, но недоступен или не git-репозиторий"
  fi

  local default_mc="$IWE_ROOT/MC-sessions"
  if [ -d "$default_mc" ]; then
    if git -C "$default_mc" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$default_mc"
      return 0
    fi
    fail "MC-sessions существует ($default_mc), но не похож на git-репозиторий -- похоже на сломанную мигрированную установку, не откатываюсь на legacy-путь молча"
  fi

  echo "WARN: MC-sessions не найден ($default_mc) -- использую legacy-путь \$GOV_REPO/sessions (обычное поведение немигрированной установки шаблона)" >&2
  local legacy="$IWE_ROOT/$GOV_REPO/sessions"
  mkdir -p "$legacy"
  echo "$legacy"
}

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

# semaphore_governance_worktree <semaphore> — returns the checkout that owns
# this session's governance/code scope. `governance_worktree` is the explicit
# post-WP-526 contract. It is deliberately distinct from `isolated_worktree`:
# the latter also grants close permission to publish/remove a worktree, while
# an ordinary clone or manually-created worktree must never acquire that
# ownership merely because scope checks need to inspect it.
#
# Legacy fallback order is intentionally narrow:
#   1. isolated_worktree (old automatic-isolate semaphores);
#   2. the git root containing orz_sessions_dir, but only when it is provably
#      the governance repository (same common git dir or same origin URL).
# Explicit fields are authoritative semaphore data and only need to name a
# live git checkout; the identity proof applies to the inferred ORZ fallback.
# This still lets an independent clone be the legitimate governance checkout.
# Modern MC-sessions therefore cannot be mistaken for the governance checkout.
semaphore_governance_worktree() {
  local semaphore="$1" candidate="" sessions_dir=""
  local canonical="$IWE_ROOT/$GOV_REPO"
  local candidate_common="" canonical_common=""
  local candidate_remote="" canonical_remote=""

  candidate=$(sed -n 's/^governance_worktree: //p' "$semaphore" 2>/dev/null | head -1) || candidate=""
  if [ -z "$candidate" ]; then
    candidate=$(sed -n 's/^isolated_worktree: //p' "$semaphore" 2>/dev/null | head -1) || candidate=""
  fi
  if [ -n "$candidate" ]; then
    candidate=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || return 1
    printf '%s\n' "$candidate"
    return 0
  else
    sessions_dir=$(sed -n 's/^orz_sessions_dir: //p' "$semaphore" 2>/dev/null | head -1) || sessions_dir=""
    [ -n "$sessions_dir" ] || return 1
    candidate=$(git -C "$sessions_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  fi

  candidate_common=$(git -C "$candidate" rev-parse --git-common-dir 2>/dev/null) \
    || candidate_common=""
  canonical_common=$(git -C "$canonical" rev-parse --git-common-dir 2>/dev/null) \
    || canonical_common=""
  case "$candidate_common" in
    /*) ;;
    '') ;;
    *) candidate_common="$candidate/$candidate_common" ;;
  esac
  case "$canonical_common" in
    /*) ;;
    '') ;;
    *) canonical_common="$canonical/$canonical_common" ;;
  esac
  [ -z "$candidate_common" ] \
    || candidate_common=$(cd "$candidate_common" 2>/dev/null && pwd -P) \
    || candidate_common=""
  [ -z "$canonical_common" ] \
    || canonical_common=$(cd "$canonical_common" 2>/dev/null && pwd -P) \
    || canonical_common=""
  if [ -n "$candidate_common" ] && [ "$candidate_common" = "$canonical_common" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate_remote=$(git -C "$candidate" remote get-url origin 2>/dev/null) || candidate_remote=""
  canonical_remote=$(git -C "$canonical" remote get-url origin 2>/dev/null) || canonical_remote=""
  if [ -n "$candidate_remote" ] && [ -n "$canonical_remote" ] \
     && [ "$(normalize_remote_url "$candidate_remote")" = "$(normalize_remote_url "$canonical_remote")" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
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

# Authority lock for one session semaphore.  Unlike the historical mkdir/TTL
# lock below, this file is never unlinked or reclaimed: kernel flock lifetime,
# not PID/age guessing, fences close/recover/sweep against semaphore writers.
# FD 196 is deliberately fixed for macOS /bin/bash 3.2 compatibility.
SESSION_TRANSITION_LOCK_DIR="$IWE_ROOT/.iwe-runtime/session-transition-locks"
SESSION_TRANSITION_LOCK_FD=196
_SESSION_TRANSITION_LOCK_PATH=""
_SESSION_TRANSITION_LOCK_TOKEN=""
SCHEDULED_ADMISSION_LOCK_FD=195
_SCHEDULED_ADMISSION_LOCK_PATH=""
_SCHEDULED_ADMISSION_LOCK_TOKEN=""

# Resolve the one external primitive used by the persistent authority locks
# once, to an absolute and minimally trustworthy executable.  launchd and
# systemd often provide a smaller PATH than an interactive shell; the explicit
# installation paths keep that environment drift from looking like capacity
# contention.  A stock installation with no flock still fails closed -- a
# reclaimable mkdir/mtime lock is not an authority fallback.
_resolve_flock_bin() {
  local candidate=""
  if [ -n "${IWE_FLOCK_BIN+x}" ]; then
    # An explicit prerequisite path never silently falls back: this makes a
    # missing deployment dependency diagnosable and gives tests a safe way to
    # prove fail-closed behavior without renaming a host executable.
    candidate="$IWE_FLOCK_BIN"
  else
    candidate=$(command -v flock 2>/dev/null || true)
  fi
  case "$candidate" in
    /opt/homebrew/bin/flock|/usr/local/bin/flock|/run/current-system/sw/bin/flock) ;;
    *) candidate="" ;;
  esac
  if [ -z "$candidate" ] && [ -z "${IWE_FLOCK_BIN+x}" ]; then
    for candidate in /opt/homebrew/bin/flock /usr/local/bin/flock /run/current-system/sw/bin/flock; do
      [ -x "$candidate" ] && break
      candidate=""
    done
  fi
  [ -n "$candidate" ] || return 1
  python3 - "$candidate" <<'PY' 2>/dev/null
import os
import stat
import sys

path = os.path.realpath(sys.argv[1])
info = os.stat(path)
if (
    not stat.S_ISREG(info.st_mode)
    or not (info.st_mode & stat.S_IXUSR)
    or info.st_uid not in (0, os.geteuid())
    or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    raise SystemExit(1)
print(path)
PY
}

FLOCK_BIN=$(_resolve_flock_bin || true)

_validate_session_transition_fd() {  # <lock-path>; prints dev:ino
  python3 - "$1" "$SESSION_TRANSITION_LOCK_FD" <<'PY' 2>/dev/null
import os
import stat
import sys

path, fd_text = sys.argv[1:]
fd = int(fd_text)
info = os.fstat(fd)
current = os.lstat(path)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.geteuid()
    or stat.S_IMODE(info.st_mode) != 0o600
    or info.st_nlink != 1
    or stat.S_ISLNK(current.st_mode)
    or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
):
    raise SystemExit(1)
print("%d:%d" % (info.st_dev, info.st_ino))
PY
}

_validate_scheduled_admission_fd() {  # <lock-path>; prints dev:ino
  python3 - "$1" "$SCHEDULED_ADMISSION_LOCK_FD" <<'PY' 2>/dev/null
import os
import stat
import sys

path, fd_text = sys.argv[1:]
fd = int(fd_text)
info = os.fstat(fd)
current = os.lstat(path)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.geteuid()
    or stat.S_IMODE(info.st_mode) != 0o600
    or info.st_nlink != 1
    or stat.S_ISLNK(current.st_mode)
    or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
):
    raise SystemExit(1)
print("%d:%d" % (info.st_dev, info.st_ino))
PY
}

_release_transition_locks_on_exit() {
  [ -z "$_SESSION_TRANSITION_LOCK_PATH" ] || release_session_transition_lock || true
  [ -z "$_SCHEDULED_ADMISSION_LOCK_PATH" ] || release_scheduled_admission_lock || true
}

release_session_transition_lock() {
  local current_token=""
  [ -n "$_SESSION_TRANSITION_LOCK_PATH" ] || return 0
  current_token=$(_validate_session_transition_fd "$_SESSION_TRANSITION_LOCK_PATH" || true)
  if [ -z "$current_token" ] || [ "$current_token" != "$_SESSION_TRANSITION_LOCK_TOKEN" ]; then
    echo "session-guard: refusing to unlock mismatched session-transition FD $SESSION_TRANSITION_LOCK_FD" >&2
    return 1
  fi
  [ -n "$FLOCK_BIN" ] || return 1
  "$FLOCK_BIN" -u "$SESSION_TRANSITION_LOCK_FD" 2>/dev/null || return 1
  exec 196>&-
  _SESSION_TRANSITION_LOCK_PATH=""
  _SESSION_TRANSITION_LOCK_TOKEN=""
  if [ -z "$_SCHEDULED_ADMISSION_LOCK_PATH" ]; then
    trap - EXIT
  fi
}

acquire_session_transition_lock() {  # <original absolute .open path>
  local semaphore="$1" canonical_semaphore lock_id lock_path token wait_seconds
  [ -z "$_SESSION_TRANSITION_LOCK_PATH" ] \
    || fail "session-transition lock уже удерживается этим shell; повторный acquire запрещён" 1
  if { : >&196; } 2>/dev/null; then
    fail "session-transition reserved FD 196 уже занят; lock не захвачен" 1
  fi
  [ -n "$FLOCK_BIN" ] \
    || fail "session-transition требует доверенный flock (/opt/homebrew, /usr/local или /run/current-system/sw); без него mutation запрещена" 1
  python3 - "$SESSION_TRANSITION_LOCK_DIR" <<'PY' \
    || fail "session-transition lock-dir небезопасен; mutation запрещена" 1
import errno
import os
import stat
import sys

path = sys.argv[1]
try:
    os.mkdir(path, 0o700)
except OSError as error:
    if error.errno != errno.EEXIST:
        raise
info = os.lstat(path)
if (
    stat.S_ISLNK(info.st_mode)
    or not stat.S_ISDIR(info.st_mode)
    or info.st_uid != os.geteuid()
    or stat.S_IMODE(info.st_mode) != 0o700
):
    raise SystemExit(1)
PY
  canonical_semaphore=$(python3 - "$semaphore" <<'PY' 2>/dev/null
import os
import stat
import sys

path = os.path.abspath(os.path.normpath(sys.argv[1]))
parent = os.path.realpath(os.path.dirname(path))
info = os.lstat(parent)
if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != os.geteuid():
    raise SystemExit(1)
print(os.path.join(parent, os.path.basename(path)))
PY
  ) || fail "session-transition semaphore parent не канонизируется безопасно" 1
  lock_id=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$canonical_semaphore") \
    || fail "session-transition lock id не вычислен" 1
  lock_path="$SESSION_TRANSITION_LOCK_DIR/$lock_id.lock"
  python3 - "$lock_path" <<'PY' \
    || fail "session-transition lockfile небезопасен; mutation запрещена" 1
import os
import stat
import sys

path = sys.argv[1]
fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
finally:
    os.close(fd)
PY
  exec 196<> "$lock_path" \
    || fail "session-transition lockfile не открыт; mutation запрещена" 1
  token=$(_validate_session_transition_fd "$lock_path" || true)
  if [ -z "$token" ]; then
    exec 196>&-
    fail "session-transition lockfile изменился при open; mutation запрещена" 1
  fi
  wait_seconds="${IWE_SESSION_TRANSITION_WAIT_SEC:-30}"
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] && [ "$wait_seconds" -le 30 ] \
    || { exec 196>&-; fail "IWE_SESSION_TRANSITION_WAIT_SEC должен быть целым 0..30" 1; }
  if [ "$wait_seconds" -eq 0 ]; then
    "$FLOCK_BIN" -xn "$SESSION_TRANSITION_LOCK_FD" || {
      exec 196>&-
      fail "session-transition lock занят (nonblocking acquire); повтори позже" 1
    }
  elif ! "$FLOCK_BIN" -x -w "$wait_seconds" "$SESSION_TRANSITION_LOCK_FD"; then
    exec 196>&-
    fail "session-transition lock занят дольше ${wait_seconds}s; повтори позже" 1
  fi
  [ "$(_validate_session_transition_fd "$lock_path" || true)" = "$token" ] \
    || { "$FLOCK_BIN" -u "$SESSION_TRANSITION_LOCK_FD" 2>/dev/null || true; exec 196>&-; fail "session-transition lockfile изменился после flock; mutation запрещена" 1; }
  _SESSION_TRANSITION_LOCK_PATH="$lock_path"
  _SESSION_TRANSITION_LOCK_TOKEN="$token"
  trap _release_transition_locks_on_exit EXIT
}

release_scheduled_admission_lock() {
  local current_token=""
  [ -n "$_SCHEDULED_ADMISSION_LOCK_PATH" ] || return 0
  [ -z "$_SESSION_TRANSITION_LOCK_PATH" ] \
    || { echo "session-guard: release session-transition lock before scheduled-admission lock" >&2; return 1; }
  current_token=$(_validate_scheduled_admission_fd "$_SCHEDULED_ADMISSION_LOCK_PATH" || true)
  if [ -z "$current_token" ] || [ "$current_token" != "$_SCHEDULED_ADMISSION_LOCK_TOKEN" ]; then
    echo "session-guard: refusing to unlock mismatched scheduled-admission FD $SCHEDULED_ADMISSION_LOCK_FD" >&2
    return 1
  fi
  [ -n "$FLOCK_BIN" ] || return 1
  "$FLOCK_BIN" -u "$SCHEDULED_ADMISSION_LOCK_FD" 2>/dev/null || return 1
  exec 195>&-
  _SCHEDULED_ADMISSION_LOCK_PATH=""
  _SCHEDULED_ADMISSION_LOCK_TOKEN=""
  trap - EXIT
}

acquire_scheduled_admission_lock() {
  local lock_path token wait_seconds
  [ -z "$_SCHEDULED_ADMISSION_LOCK_PATH" ] \
    || fail "scheduled-admission lock уже удерживается этим shell" 1
  [ -z "$_SESSION_TRANSITION_LOCK_PATH" ] \
    || fail "lock order violation: scheduled-admission должен браться до session-transition" 1
  if { : >&195; } 2>/dev/null; then
    fail "scheduled-admission reserved FD 195 уже занят" 1
  fi
  [ -n "$FLOCK_BIN" ] \
    || fail "scheduled-admission требует доверенный flock (/opt/homebrew, /usr/local или /run/current-system/sw); без него admission/freeze запрещены" 1
  python3 - "$SESSION_TRANSITION_LOCK_DIR" <<'PY' \
    || fail "scheduled-admission lock-dir небезопасен" 1
import errno
import os
import stat
import sys

path = sys.argv[1]
try:
    os.mkdir(path, 0o700)
except OSError as error:
    if error.errno != errno.EEXIST:
        raise
info = os.lstat(path)
if (
    stat.S_ISLNK(info.st_mode)
    or not stat.S_ISDIR(info.st_mode)
    or info.st_uid != os.geteuid()
    or stat.S_IMODE(info.st_mode) != 0o700
):
    raise SystemExit(1)
PY
  lock_path="$SESSION_TRANSITION_LOCK_DIR/scheduled-quarantine-transition.lock"
  python3 - "$lock_path" <<'PY' \
    || fail "scheduled-admission lockfile небезопасен" 1
import os
import stat
import sys

path = sys.argv[1]
fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
finally:
    os.close(fd)
PY
  exec 195<> "$lock_path" || fail "scheduled-admission lockfile не открыт" 1
  token=$(_validate_scheduled_admission_fd "$lock_path" || true)
  if [ -z "$token" ]; then
    exec 195>&-
    fail "scheduled-admission lockfile изменился при open" 1
  fi
  wait_seconds="${IWE_SCHEDULED_ADMISSION_WAIT_SEC:-30}"
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] && [ "$wait_seconds" -le 30 ] \
    || { exec 195>&-; fail "IWE_SCHEDULED_ADMISSION_WAIT_SEC должен быть целым 0..30" 1; }
  if [ "$wait_seconds" -eq 0 ]; then
    "$FLOCK_BIN" -xn "$SCHEDULED_ADMISSION_LOCK_FD" || {
      exec 195>&-
      fail "scheduled-admission lock занят (nonblocking acquire)" 1
    }
  elif ! "$FLOCK_BIN" -x -w "$wait_seconds" "$SCHEDULED_ADMISSION_LOCK_FD"; then
    exec 195>&-
    fail "scheduled-admission lock занят дольше ${wait_seconds}s" 1
  fi
  [ "$(_validate_scheduled_admission_fd "$lock_path" || true)" = "$token" ] \
    || { "$FLOCK_BIN" -u "$SCHEDULED_ADMISSION_LOCK_FD" 2>/dev/null || true; exec 195>&-; fail "scheduled-admission lockfile изменился после flock" 1; }
  _SCHEDULED_ADMISSION_LOCK_PATH="$lock_path"
  _SCHEDULED_ADMISSION_LOCK_TOKEN="$token"
  trap _release_transition_locks_on_exit EXIT
}

with_scheduled_admission_lock() {
  local rc=0
  acquire_scheduled_admission_lock
  "$@" || rc=$?
  release_scheduled_admission_lock \
    || { echo "session-guard: scheduled-admission unlock failed" >&2; return 1; }
  return "$rc"
}

with_session_transition_lock() {  # <original .open path> <callback...>
  local semaphore="$1" rc=0
  shift
  acquire_session_transition_lock "$semaphore"
  "$@" || rc=$?
  release_session_transition_lock \
    || { echo "session-guard: session-transition unlock failed" >&2; return 1; }
  return "$rc"
}

_locked_open_identity() {  # <open path> <expected agent> [expected session] [allow terminal hardlink 0|1]
  python3 - "$1" "$2" "${3:-}" "${4:-0}" <<'PY' 2>/dev/null
import os
import stat
import sys

path, expected_agent, expected_session, allow_terminal_link = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink not in ((1, 2) if allow_terminal_link == "1" else (1,))
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    if info.st_nlink == 2:
        closed = os.lstat(path + ".closed")
        if stat.S_ISLNK(closed.st_mode) or (closed.st_dev, closed.st_ino) != (info.st_dev, info.st_ino):
            raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")
    if info.st_nlink == 2:
        closed = os.lstat(path + ".closed")
        if stat.S_ISLNK(closed.st_mode) or (closed.st_dev, closed.st_ino) != (info.st_dev, info.st_ino):
            raise SystemExit(1)
finally:
    os.close(fd)

def unique(key):
    prefix = key + ": "
    values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise SystemExit(1)
    return values[0]

agent = unique("agent")
if agent != expected_agent:
    raise SystemExit(1)

basename = os.path.basename(path)
housekeeping_values = [
    line[len("housekeeping: "):]
    for line in text.splitlines()
    if line.startswith("housekeeping: ")
]
if housekeeping_values:
    if expected_session or len(housekeeping_values) != 1 or not housekeeping_values[0]:
        raise SystemExit(1)
    reason = housekeeping_values[0]
    if unique("slug") != reason or basename != "%s-housekeeping-%s.open" % (agent, reason):
        raise SystemExit(1)
    session_values = [
        line[len("session_id: "):]
        for line in text.splitlines()
        if line.startswith("session_id: ")
    ]
    if len(session_values) > 1 or (session_values and not session_values[0]):
        raise SystemExit(1)
    print(session_values[0] if session_values else "housekeeping:" + reason)
else:
    session = unique("session_id")
    if expected_session and session != expected_session:
        raise SystemExit(1)
    if basename != "%s-%s.open" % (agent, session):
        raise SystemExit(1)
    print(session)
PY
}

_owner_pid_is_live_ancestor() {  # <owner-pid>; accidental call-shape guard, not authentication
  local wanted="$1" current="$PPID" hops=0 next=""
  kill -0 "$wanted" 2>/dev/null || return 1
  # A wrapper may tail-exec the guard as its last command.  In that shape the
  # wrapper PID is now this Bash PID rather than an ancestor visible from
  # PPID.  It is still the same live process identity; accepting it only
  # preserves the call-shape check and does not create an authentication
  # boundary (all same-user callers can choose argv either way).
  [ "$wanted" = "$$" ] && return 0
  while [ "$hops" -lt 8 ] && [[ "$current" =~ ^[1-9][0-9]*$ ]]; do
    [ "$current" = "$wanted" ] && return 0
    next=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$next" ] && [ "$next" != "$current" ] || break
    current="$next"
    hops=$((hops + 1))
  done
  return 1
}

_append_scheduled_drain_proof() {  # <sem> <agent> <session> <owner-pid> <run-id> <at>
  python3 - "$@" <<'PY'
import datetime
import os
import stat
import sys
import uuid

path, expected_agent, expected_session, expected_pid, expected_run, proof_at = sys.argv[1:]
proof = {
    "scheduled_drain_proof": "process-group-empty/v1",
    "scheduled_drain_session_id": expected_session,
    "scheduled_drain_owner_pid": expected_pid,
    "scheduled_drain_run_id": expected_run,
    "scheduled_drain_at": proof_at,
}

identity = {
    "agent": expected_agent,
    "session_id": expected_session,
    "pid": expected_pid,
    "close_path": "pipeline",
    "scheduled_owner": "wp-run-scheduled-tsekh1/v1",
    "scheduled_run_id": expected_run,
}

try:
    parsed = datetime.datetime.strptime(proof_at, "%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    raise SystemExit(1)
if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != proof_at:
    raise SystemExit(1)

flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags)
temp_fd = -1
temporary = path + ".scheduled-drain.%d.%s" % (os.getpid(), uuid.uuid4().hex)
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")

    def values(key):
        prefix = key + ": "
        return [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]

    for key, expected in identity.items():
        if values(key) != [expected]:
            raise SystemExit(1)
    if values("wp") == [] or values("slug") == []:
        raise SystemExit(1)
    if len(values("wp")) != 1 or len(values("slug")) != 1:
        raise SystemExit(1)
    if os.path.basename(path) != "%s-%s.open" % (expected_agent, expected_session):
        raise SystemExit(1)

    present = {key: values(key) for key in proof}
    if any(present.values()):
        # A retry after replace/fsync interruption accepts only one complete,
        # identity-bound proof.  Re-fsync both file and directory before success.
        for key, expected in proof.items():
            if key == "scheduled_drain_at":
                if len(present[key]) != 1:
                    raise SystemExit(1)
                try:
                    datetime.datetime.strptime(present[key][0], "%Y-%m-%dT%H:%M:%SZ")
                except ValueError:
                    raise SystemExit(1)
            elif present[key] != [expected]:
                raise SystemExit(1)
        os.fsync(fd)
        directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        raise SystemExit(0)

    payload = raw + "".join("%s: %s\n" % item for item in proof.items()).encode("utf-8")
    if len(payload) > 1024 * 1024:
        raise SystemExit(1)
    temp_fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        stat.S_IMODE(info.st_mode),
    )
    view = memoryview(payload)
    while view:
        written = os.write(temp_fd, view)
        if written <= 0:
            raise RuntimeError("short scheduled-drain write")
        view = view[written:]
    os.fsync(temp_fd)
    os.close(temp_fd)
    temp_fd = -1
    current = os.lstat(path)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise RuntimeError("semaphore changed before scheduled-drain replace")
    os.replace(temporary, path)
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

    verify_fd = os.open(path, flags)
    try:
        verify_info = os.fstat(verify_fd)
        verify_path = os.lstat(path)
        verified = b""
        while True:
            chunk = os.read(verify_fd, 65536)
            if not chunk:
                break
            verified += chunk
        if (
            not stat.S_ISREG(verify_info.st_mode)
            or verify_info.st_uid != os.geteuid()
            or verify_info.st_nlink != 1
            or stat.S_ISLNK(verify_path.st_mode)
            or (verify_path.st_dev, verify_path.st_ino) != (verify_info.st_dev, verify_info.st_ino)
            or verified != payload
        ):
            raise SystemExit(1)
    finally:
        os.close(verify_fd)
finally:
    if temp_fd >= 0:
        os.close(temp_fd)
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    os.close(fd)
PY
}

_append_heartbeat_atomic() {  # <sem> <agent> <session> <heartbeat-pid> <at>
  python3 - "$@" <<'PY'
import datetime
import os
import stat
import sys
import uuid

path, expected_agent, expected_session, heartbeat_pid, heartbeat_at = sys.argv[1:]
try:
    parsed = datetime.datetime.strptime(heartbeat_at, "%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    raise SystemExit(1)
if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != heartbeat_at:
    raise SystemExit(1)
if not heartbeat_pid.isdigit() or heartbeat_pid == "0":
    raise SystemExit(1)

flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags)  # no O_CREAT: a close can never be undone by heartbeat
temporary = path + ".heartbeat.%d.%s" % (os.getpid(), uuid.uuid4().hex)
temp_fd = -1
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")

    def values(key):
        prefix = key + ": "
        return [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]

    if (
        values("agent") != [expected_agent]
        or values("session_id") != [expected_session]
        or os.path.basename(path) != "%s-%s.open" % (expected_agent, expected_session)
        or values("housekeeping")
        or any(line.startswith(("close_", "recovery_")) for line in text.splitlines())
    ):
        raise SystemExit(1)

    payload = raw + (
        "heartbeat_at: %s\nheartbeat_pid: %s\n" % (heartbeat_at, heartbeat_pid)
    ).encode("utf-8")
    if len(payload) > 1024 * 1024:
        raise SystemExit(1)
    temp_fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        stat.S_IMODE(info.st_mode),
    )
    view = memoryview(payload)
    while view:
        written = os.write(temp_fd, view)
        if written <= 0:
            raise RuntimeError("short heartbeat write")
        view = view[written:]
    os.fsync(temp_fd)
    os.close(temp_fd)
    temp_fd = -1
    current = os.lstat(path)
    if (current.st_dev, current.st_ino, current.st_nlink) != (info.st_dev, info.st_ino, 1):
        raise RuntimeError("semaphore changed before heartbeat replace")
    os.replace(temporary, path)
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

    verify_fd = os.open(path, flags)
    try:
        verify_info = os.fstat(verify_fd)
        verify_path = os.lstat(path)
        verified = b""
        while True:
            chunk = os.read(verify_fd, 65536)
            if not chunk:
                break
            verified += chunk
        if (
            not stat.S_ISREG(verify_info.st_mode)
            or verify_info.st_uid != os.geteuid()
            or verify_info.st_nlink != 1
            or stat.S_ISLNK(verify_path.st_mode)
            or (verify_path.st_dev, verify_path.st_ino) != (verify_info.st_dev, verify_info.st_ino)
            or verified != payload
        ):
            raise SystemExit(1)
    finally:
        os.close(verify_fd)
finally:
    if temp_fd >= 0:
        os.close(temp_fd)
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    os.close(fd)
PY
}

_machine_close_identity_lines() {  # <sem> <agent> <canonical UUIDv4>
  python3 - "$1" "$2" "$3" "$IWE_ROOT" <<'PY' 2>/dev/null
import os
import re
import stat
import sys
import uuid

path, expected_agent, expected_session, iwe_root = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink not in (1, 2)
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    if info.st_nlink == 2:
        closed = os.lstat(path + ".closed")
        if stat.S_ISLNK(closed.st_mode) or (closed.st_dev, closed.st_ino) != (info.st_dev, info.st_ino):
            raise SystemExit(1)
    raw = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        raw += chunk
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")
finally:
    os.close(fd)

def unique(key):
    prefix = key + ": "
    values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
    if len(values) != 1 or not values[0] or any(ch in values[0] for ch in "\r\n\t\0"):
        raise SystemExit(1)
    return values[0]

agent = unique("agent")
session = unique("session_id")
wp = unique("wp")
slug = unique("slug")
owner_pid = unique("pid")
worktree = unique("isolated_worktree")
governance = unique("governance_worktree")
if (
    agent != expected_agent
    or session != expected_session
    or os.path.basename(path) != "%s-%s.open" % (agent, session)
    or unique("close_path") != "machine-publish-only"
    or any(line.startswith("housekeeping:") for line in text.splitlines())
    or not re.fullmatch(r"WP-[1-9][0-9]*", wp, re.I)
    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", slug)
    or not re.fullmatch(r"[1-9][0-9]*", owner_pid)
):
    raise SystemExit(1)
parsed = uuid.UUID(session)
if parsed.version != 4 or str(parsed) != session:
    raise SystemExit(1)

store = os.path.realpath(os.path.join(iwe_root, ".iwe-runtime", "isolated-worktrees"))
worktree_parent = os.path.realpath(os.path.dirname(worktree))
canonical_worktree = os.path.join(worktree_parent, os.path.basename(worktree))
if (
    not os.path.isabs(worktree)
    or worktree_parent != store
    or canonical_worktree != os.path.join(store, "%s-%s" % (agent, session))
    or governance != worktree
):
    raise SystemExit(1)
print(owner_pid)
print(wp.upper())
print(slug)
print(worktree)
PY
}

_scheduled_admission_barrier() {  # <wp> <scheduled 0|1> <agent> <session-id>
  python3 - "$SESSION_DIR" "$1" "$2" "$3" "$4" <<'PY'
import glob
import hashlib
import os
import re
import stat
import sys
import uuid

directory, wanted_wp, scheduled, caller_agent, caller_session = sys.argv[1:]

def snapshot(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_nlink != 1
            or info.st_size <= 0
            or info.st_size > 1024 * 1024
            or stat.S_ISLNK(current.st_mode)
            or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise ValueError("unsafe file identity")
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
        if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
            raise ValueError("malformed bytes")
        text = raw.decode("utf-8")
        digest = hashlib.sha256(raw).digest()
    finally:
        os.close(fd)
    verify_fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        verify = os.fstat(verify_fd)
        verify_raw = b""
        while True:
            chunk = os.read(verify_fd, 65536)
            if not chunk:
                break
            verify_raw += chunk
        if (
            (verify.st_dev, verify.st_ino, verify.st_nlink, verify.st_size)
            != (info.st_dev, info.st_ino, 1, info.st_size)
            or hashlib.sha256(verify_raw).digest() != digest
        ):
            raise ValueError("changed during snapshot")
    finally:
        os.close(verify_fd)
    return text

def unique(text, key):
    prefix = key + ": "
    values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise ValueError("missing/duplicate " + key)
    return values[0]

def validate_identity(path, text, suffix):
    agent = unique(text, "agent")
    session = unique(text, "session_id")
    wp = unique(text, "wp")
    if not re.fullmatch(r"WP-[1-9][0-9]*", wp, re.I):
        raise ValueError("bad wp")
    if os.path.basename(path) != "%s-%s%s" % (agent, session, suffix):
        raise ValueError("filename mismatch")
    if suffix != ".open":
        parsed = uuid.UUID(session)
        if parsed.version != 4 or str(parsed) != session:
            raise ValueError("bad scheduled UUID")
        if unique(text, "scheduled_owner") != "wp-run-scheduled-tsekh1/v1":
            raise ValueError("bad scheduled owner")
        if unique(text, "scheduled_drain_proof") != "process-group-empty/v1":
            raise ValueError("bad drain proof")
        if unique(text, "scheduled_drain_session_id") != session:
            raise ValueError("drain session mismatch")
        if unique(text, "scheduled_drain_owner_pid") != unique(text, "pid"):
            raise ValueError("drain pid mismatch")
        if unique(text, "scheduled_drain_run_id") != unique(text, "scheduled_run_id"):
            raise ValueError("drain run mismatch")
    return agent, session, wp.upper()

for suffix in (
    ".open.orphaned-scheduled-drained",
    ".open.orphaned-scheduled-drained.recovery-pending",
):
    for path in sorted(glob.glob(os.path.join(directory, "*" + suffix))):
        try:
            identity = validate_identity(path, snapshot(path), suffix)
        except (OSError, UnicodeError, ValueError):
            print("malformed frozen/pending quarantine: " + path, file=sys.stderr)
            raise SystemExit(2)
        if identity[2] == wanted_wp.upper():
            print("same-WP frozen/pending quarantine: " + path, file=sys.stderr)
            raise SystemExit(1)

if scheduled == "1":
    for path in sorted(glob.glob(os.path.join(directory, "*.open"))):
        try:
            text = snapshot(path)
            housekeeping = [
                line[len("housekeeping: "):]
                for line in text.splitlines()
                if line.startswith("housekeeping: ")
            ]
            if housekeeping:
                agent = unique(text, "agent")
                reason = unique(text, "housekeeping")
                if (
                    unique(text, "slug") != reason
                    or os.path.basename(path) != "%s-housekeeping-%s.open" % (agent, reason)
                    or any(line.startswith("wp: ") for line in text.splitlines())
                    or any(line.startswith("scheduled_owner: ") for line in text.splitlines())
                ):
                    raise ValueError("malformed housekeeping")
                session_values = [
                    line[len("session_id: "):]
                    for line in text.splitlines()
                    if line.startswith("session_id: ")
                ]
                if len(session_values) > 1 or (session_values and not session_values[0]):
                    raise ValueError("malformed housekeeping session")
                continue
            agent, session, wp = validate_identity(path, text, ".open")
        except (OSError, UnicodeError, ValueError):
            print("malformed active semaphore during scheduled admission: " + path, file=sys.stderr)
            raise SystemExit(2)
        if wp == wanted_wp.upper() and (agent, session) != (caller_agent, caller_session):
            print("same-WP active semaphore: " + path, file=sys.stderr)
            raise SystemExit(1)
PY
}

_open_reentry_matches() {  # exact immutable identity; never rewrites existing journal/scope
  python3 - "$@" <<'PY' 2>/dev/null
import glob
import os
import stat
import sys

(
    path, agent, session, wp, slug, personality, close_path, governance,
    isolated_worktree, isolated_branch, scheduled_owner, scheduled_run, owner_pid,
    harness_session, orz_file, orz_dir,
) = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    raw = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        raw += chunk
finally:
    os.close(fd)
if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
    raise SystemExit(1)
text = raw.decode("utf-8")

def values(key):
    prefix = key + ": "
    return [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]

required = {
    "agent": agent,
    "session_id": session,
    "wp": wp,
    "slug": slug,
    "personality": personality,
    "close_path": close_path,
    "governance_worktree": governance,
    "orz_file": orz_file,
    "orz_sessions_dir": orz_dir,
}
optional = {
    "isolated_worktree": isolated_worktree,
    "isolated_branch": isolated_branch,
    "scheduled_owner": scheduled_owner,
    "scheduled_run_id": scheduled_run,
    "pid": owner_pid,
    "harness_session_id": harness_session,
}
if any(values(key) != [value] for key, value in required.items()):
    raise SystemExit(1)
for key, value in optional.items():
    if values(key) != ([value] if value else []):
        raise SystemExit(1)
if os.path.basename(path) != "%s-%s.open" % (agent, session):
    raise SystemExit(1)
if not owner_pid and not harness_session:
    # The public session id is an address, not a capability.  Without a
    # long-lived owner identity an existing semaphore cannot be adopted as a
    # re-entry merely because a caller guessed/reused the same id.
    raise SystemExit(1)
if any(
    key.startswith(("close_delivery_", "close_publish_", "close_cleanup_", "checklist_"))
    for key in (
    line.split(":", 1)[0] for line in text.splitlines() if ":" in line
    )
):
    raise SystemExit(1)
for sibling in glob.glob(path + ".*"):
    if sibling != path + ".lease":
        raise SystemExit(1)
PY
}

_new_open_has_no_prior_state() {  # <future .open path>
  python3 - "$1" <<'PY' 2>/dev/null
import glob
import os
import sys

path = sys.argv[1]
if os.path.lexists(path) or glob.glob(path + ".*"):
    raise SystemExit(1)
parent = os.path.dirname(path)
current = os.lstat(parent)
if not os.path.isdir(parent) or os.path.islink(parent) or current.st_uid != os.geteuid():
    raise SystemExit(1)
PY
}

_publish_new_open_semaphore() {  # <owned temporary> <absent destination>
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

temporary, destination = sys.argv[1:]
try:
    info = os.lstat(temporary)
    if (
        not stat.S_ISREG(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
    ):
        raise SystemExit(1)
    os.link(temporary, destination, follow_symlinks=False)
    published = os.lstat(destination)
    if (published.st_dev, published.st_ino, published.st_nlink) != (info.st_dev, info.st_ino, 2):
        raise SystemExit(1)
    directory_fd = os.open(os.path.dirname(destination), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
        os.unlink(temporary)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

_retire_housekeeping_closed_receipt() {  # <closed path> <agent> <reason>
  python3 - "$1" "$2" "$3" <<'PY'
import os
import stat
import sys

path, expected_agent, expected_reason = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    raw = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        raw += chunk
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")

    def values(key):
        prefix = key + ": "
        return [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]

    if (
        values("agent") != [expected_agent]
        or values("housekeeping") != [expected_reason]
        or values("slug") != [expected_reason]
        or os.path.basename(path) != "%s-housekeeping-%s.open.closed" % (expected_agent, expected_reason)
        or any(line.startswith(("close_", "recovery_")) for line in text.splitlines())
    ):
        raise SystemExit(1)
    sessions = values("session_id")
    if len(sessions) > 1 or (sessions and not sessions[0]):
        raise SystemExit(1)
    current = os.lstat(path)
    if (current.st_dev, current.st_ino, current.st_nlink) != (info.st_dev, info.st_ino, 1):
        raise SystemExit(1)
    os.unlink(path)
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    os.close(fd)
PY
}

_cleanup_closed_session_projections() {  # <former .open> <agent> <session-id> [housekeeping reason]
  python3 - "$1" "$2" "$3" "${4:-}" "$SESSION_DIR/current-$2.ptr" <<'PY'
import os
import stat
import sys

open_path, expected_agent, expected_session, housekeeping_reason, pointer_path = sys.argv[1:]
closed_path = open_path + ".closed"

def read_owned(path, max_size):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_nlink != 1
            or info.st_size <= 0
            or info.st_size > max_size
            or stat.S_ISLNK(current.st_mode)
            or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise ValueError("unsafe projection")
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
        if len(data) != info.st_size or b"\0" in data or not data.endswith(b"\n"):
            raise ValueError("malformed projection")
        data.decode("utf-8")
        return data, (info.st_dev, info.st_ino, info.st_nlink)
    finally:
        os.close(fd)

closed, _ = read_owned(closed_path, 1024 * 1024)
text = closed.decode("utf-8")

def values(key):
    prefix = key + ": "
    return [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]

if housekeeping_reason:
    identity_matches = (
        values("agent") == [expected_agent]
        and values("session_id") == [expected_session]
        and values("housekeeping") == [housekeeping_reason]
        and values("slug") == [housekeeping_reason]
        and os.path.basename(open_path)
        == "%s-housekeeping-%s.open" % (expected_agent, housekeeping_reason)
    )
else:
    identity_matches = (
        values("agent") == [expected_agent]
        and values("session_id") == [expected_session]
        and not values("housekeeping")
        and os.path.basename(open_path) == "%s-%s.open" % (expected_agent, expected_session)
    )
if not identity_matches:
    raise SystemExit(1)

changed = False
lease_path = open_path + ".lease"
if os.path.lexists(lease_path):
    try:
        lease, identity = read_owned(lease_path, 64 * 1024)
        lease_text = lease.decode("utf-8")
        session_values = [
            line[len("session_id: "):]
            for line in lease_text.splitlines()
            if line.startswith("session_id: ")
        ]
        current = os.lstat(lease_path)
        if session_values == [expected_session] and (current.st_dev, current.st_ino, current.st_nlink) == identity:
            os.unlink(lease_path)
            changed = True
    except (OSError, UnicodeError, ValueError):
        pass

if not housekeeping_reason and os.path.lexists(pointer_path):
    try:
        pointer, identity = read_owned(pointer_path, 64 * 1024)
        current = os.lstat(pointer_path)
        if pointer == (open_path + "\n").encode("utf-8") and (current.st_dev, current.st_ino, current.st_nlink) == identity:
            os.unlink(pointer_path)
            changed = True
    except (OSError, UnicodeError, ValueError):
        pass

if changed:
    directory_fd = os.open(os.path.dirname(open_path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
PY
}

_agent_has_other_open_session() {  # <agent>; 0 if another or malformed .open exists
  local agent="$1" candidate candidate_id
  for candidate in "$SESSION_DIR/${agent}-"*.open; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    candidate_id=$(_locked_open_identity "$candidate" "$agent" "" || true)
    [ -n "$candidate_id" ] && return 0
    # An ambiguous file must never permit an idle projection.
    return 0
  done
  return 1
}

# with_isolate_lock <session_id> <callback...> -- single critical-section
# primitive (Codex, turn 3: "не копируем новый примитив в команды... единый
# внутренний with_session_lock, используемый и open, и cleanup"). Reuses the
# mkdir-is-atomic pattern already proven by lock-hot-file above, scoped per
# session_id instead of per hot-file path, so two concurrent re-entries for
# the SAME session_id can't both decide "worktree absent, create one".
# Locks currently held by THIS process, innermost last. Only the EXIT trap
# below reads it as a whole -- the normal return path pops just its own entry.
_ISOLATE_LOCKS_HELD=()

release_isolate_locks() {
  local held
  for held in ${_ISOLATE_LOCKS_HELD[@]+"${_ISOLATE_LOCKS_HELD[@]}"}; do
    [ -n "$held" ] && rm -rf "$held"
  done
  _ISOLATE_LOCKS_HELD=()
}

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
  # Both exits out of the critical section have to release the lock, and neither
  # did before (WP-530, peer session 2026-09-05-34 with Kimi):
  #   - a non-zero return from the callback killed the script right here under
  #     `set -euo pipefail` (line 63), before the release below ever ran;
  #   - `fail()` (line 149) is "message + exit", so a callback failing deep
  #     inside it leaves the function entirely -- which a RETURN trap would not
  #     catch either, the reason this is an EXIT trap and not that.
  # Nothing about waiting changes: a dead owner's lock is already reclaimed by
  # the PID-liveness branch above on the next contender's first pass, so what
  # leaked here was a stale directory on disk, not a window of protection.
  # The trap is installed for the critical section only and cleared right after
  # it -- this file's global EXIT trap belongs to another command
  # (wp-context-guarded-edit), and leaving ours armed would take it over.
  # The trap releases EVERY lock this process holds, not just this one. A
  # process has a single EXIT trap, so a nested call that armed its own would
  # disarm the outer one and leak the outer lock on an abort (cold review of
  # this change, Medium). Holding the paths in one stack keeps the trap correct
  # at any depth -- no call site nests today, and none has to remember not to.
  _ISOLATE_LOCKS_HELD+=("$lock_path")
  trap release_isolate_locks EXIT
  local rc=0
  "$@" || rc=$?
  # Normal path releases only this call's own lock; an outer holder's lock is
  # its own business and stays until that call returns.
  unset "_ISOLATE_LOCKS_HELD[$(( ${#_ISOLATE_LOCKS_HELD[@]} - 1 ))]"
  rm -rf "$lock_path"
  if [ "${#_ISOLATE_LOCKS_HELD[@]}" -eq 0 ]; then
    trap - EXIT
  fi
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
  # Human text (WP-538 addressee policy, peer-session 2026-09-03-05): what
  # happened, who owns the next step, when it resolves on its own -- this is
  # a fully automatic transition (see the comment above ZOMBIE_REGISTRY), so
  # the pilot owns nothing here beyond "read if curious".
  local age_h=$(( age_seconds / 3600 ))
  local msg
  msg="Осиротевшая сессия IWE: $(basename -- "$semaphore") уже ${age_h}ч не подтверждает, что за ней кто-то следит. Защитный барьер оставлен на месте: нужен точный terminal/drain proof или ручной разбор."

  # Same fallback pattern as check-wp353-trigger.sh: never let a missing/failing
  # notifier block the quarantine decision itself.
  # WP-538 Ф7 (11.09): iwe-tg routes through the allowlist gate — --source is
  # this script's own row (IWE-root / session-guard); exit 3 = quarantined,
  # not delivered, reported distinctly from a transport failure.
  if command -v iwe-tg >/dev/null 2>&1; then
    local tg_rc=0
    iwe-tg --source session-guard "$msg" || tg_rc=$?
    case "$tg_rc" in
      0) ;;
      3) echo "WARN: zombie alert quarantined by the allowlist gate (not delivered), only in log: $semaphore" >&2 ;;
      *) echo "WARN: iwe-tg failed (rc=$tg_rc), zombie alert only in log: $semaphore" >&2 ;;
    esac
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

# Top-level frontmatter field of a runner card (or semaphore), first match.
# Prints nothing when the key is absent; a literal "null" comes back as-is, so
# an owner comparison against a real id fails closed.
_card_field() {  # <card> <key>
  grep "^$2: " "$1" 2>/dev/null | head -1 | cut -d' ' -f2- || true
}

# WP a quick-close card ran for, as a bare number ("484"), or nothing.
# Cards carry no top-level wp: the runner reads it from the semaphore into
# results.gather-session-facts.wp (source of truth), while
# results.wp-context-update.wp is the WP whose context file was written and
# may legitimately differ -- consulted only when gather's is empty (cards
# started without --wp leave it '' but still reach completed; ~28% of real
# completed cards, review 07.09). Both "WP-484" and "484" forms occur.
_quick_close_card_wp() {  # <card>
  python3 - "$1" <<'PY' 2>/dev/null || true
import re, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.match(r"^---\n(.*?)\n---(?:\n|$)", text, re.S)
if not m:
    sys.exit(0)
try:
    doc = yaml.safe_load(m.group(1)) or {}
except yaml.YAMLError:
    sys.exit(0)
results = doc.get("results") if isinstance(doc, dict) else None
results = results if isinstance(results, dict) else {}
for step in ("gather-session-facts", "wp-context-update"):
    entry = results.get(step)
    wp = entry.get("wp") if isinstance(entry, dict) else None
    num = re.sub(r"^wp-", "", "" if wp is None else str(wp).strip(), flags=re.I)
    if num:
        print(num)
        break
PY
}

# A dead PID proves owner absence; a missing PID plus age proves only that the
# semaphore is stale enough to quarantine. Neither proves that the session
# finished its delivery protocol. In particular, isolate-push.sh transfers every
# clean commit in the worktree and the caller removes that worktree on success;
# doing either after quarantine alone can publish a partial session and destroy
# its only local recovery copy. Reuse the same narrow terminal Quick Close
# outcomes accepted by close() below. An explicit close-obligation cancellation
# is intentionally not enough: it authorizes ending the obligation, not
# publishing or deleting whatever happens to be in the abandoned worktree.
_orphaned_worktree_terminal_outcome_proven() {
  local quarantined_semaphore="$1"
  local worktree_path slug harness_session_id guard_session_id expected_owner semaphore_wp_num
  local card_dir card card_rel proof_sha="" mode=""
  worktree_path=$(_unique_record_field "$quarantined_semaphore" isolated_worktree || true)
  slug=$(_unique_record_field "$quarantined_semaphore" slug || true)
  harness_session_id=$(_unique_record_field "$quarantined_semaphore" harness_session_id || true)
  guard_session_id=$(_unique_record_field "$quarantined_semaphore" session_id || true)
  semaphore_wp_num=$(_unique_record_field "$quarantined_semaphore" wp || true)
  semaphore_wp_num=$(printf '%s' "$semaphore_wp_num" | sed -E 's/^[Ww][Pp]-//' || true)
  [ -n "$worktree_path" ] && [ -d "$worktree_path" ] || return 1
  [[ "$slug" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  [ -z "$harness_session_id" ] || [[ "$harness_session_id" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  [[ "$guard_session_id" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  expected_owner="${harness_session_id:-$guard_session_id}"
  [[ "$semaphore_wp_num" =~ ^[1-9][0-9]*$ ]] || return 1

  # Destructive recovery must be bound to this exact session generation. A
  # completed card merely present in the canonical checkout (or inherited in
  # the worktree from its base commit) is not proof: a long harness may reuse a
  # slug across retries or WPs. The trusted runner registers its freshly
  # created terminal card through note-file, so require that scope entry plus
  # exact owner, requested slug, run id and WP before publishing/removing the
  # abandoned worktree. Legacy semaphores lacking these fields fail closed and
  # remain available to recover-orphaned/manual review.
  card_dir="$worktree_path/inbox/agent/tasks"
  [ -d "$card_dir" ] || return 1
  for card in "$card_dir"/RUN-quick-close-"$slug"*.md; do
    [ -f "$card" ] || continue
    card_rel="${card#"$worktree_path"/}"
    [ "$card_rel" != "$card" ] || continue
    grep -Fqx "file: $card_rel" "$quarantined_semaphore" || continue
    for mode in completed archive-cancelled; do
      proof_sha=$(_terminal_card_snapshot_sha "$card" "$mode" "$expected_owner" \
        "WP-$semaphore_wp_num" "$slug" || true)
      if [ -n "$proof_sha" ]; then
        printf '%s\n' "$proof_sha"
        return 0
      fi
    done
  done
  return 1
}

_owned_semaphore_snapshot_sha() {  # <path> [allow matching .closed hardlink 0|1]
  python3 - "$1" "${2:-0}" <<'PY' 2>/dev/null
import fcntl
import hashlib
import os
import stat
import sys

path, allow_terminal_link = sys.argv[1:]
fd = -1
try:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    fcntl.flock(fd, fcntl.LOCK_SH)
    info = os.fstat(fd)
    expected_links = (1, 2) if allow_terminal_link == "1" else (1,)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink not in expected_links:
        raise SystemExit(1)
    if info.st_size <= 0 or info.st_size > 1024 * 1024:
        raise SystemExit(1)
    data = os.read(fd, info.st_size + 1)
    if len(data) != info.st_size or b"\0" in data or not data.endswith(b"\n"):
        raise SystemExit(1)
    data.decode("utf-8")
    current = os.lstat(path)
    if stat.S_ISLNK(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)
    if info.st_nlink == 2:
        closed = os.lstat(path + ".closed")
        if stat.S_ISLNK(closed.st_mode) or (closed.st_dev, closed.st_ino) != (info.st_dev, info.st_ino):
            raise SystemExit(1)
    print(hashlib.sha256(data).hexdigest())
finally:
    if fd >= 0:
        os.close(fd)
PY
}

_rename_owned_semaphore_cas() {  # <source> <destination> <snapshot-sha256>
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null
import fcntl
import hashlib
import os
import stat
import sys

source, destination, expected = sys.argv[1:]
fd = -1
try:
    fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    fcntl.flock(fd, fcntl.LOCK_EX)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink not in (1, 2):
        raise SystemExit(1)
    if info.st_size <= 0 or info.st_size > 1024 * 1024:
        raise SystemExit(1)
    data = os.read(fd, info.st_size + 1)
    if len(data) != info.st_size or b"\0" in data or not data.endswith(b"\n"):
        raise SystemExit(1)
    data.decode("utf-8")
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit(1)
    current = os.lstat(source)
    if stat.S_ISLNK(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)
    # Portable NOREPLACE transition (macOS has no renameat2). A crash after
    # link(2), before unlink(2), leaves two names for the same exact inode; a
    # retry may finish only that inode-bound transition. A foreign destination
    # is never overwritten.
    if os.path.lexists(destination):
        target = os.lstat(destination)
        if (
            stat.S_ISLNK(target.st_mode)
            or (target.st_dev, target.st_ino) != (info.st_dev, info.st_ino)
            or info.st_nlink != 2
        ):
            raise SystemExit(1)
    else:
        if info.st_nlink != 1:
            raise SystemExit(1)
        os.link(source, destination, follow_symlinks=False)
        target = os.lstat(destination)
        linked = os.fstat(fd)
        if (
            stat.S_ISLNK(target.st_mode)
            or (target.st_dev, target.st_ino) != (linked.st_dev, linked.st_ino)
            or linked.st_nlink != 2
        ):
            raise SystemExit(1)
    directory_fd = os.open(os.path.dirname(source), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
        current = os.lstat(source)
        target = os.lstat(destination)
        if (
            (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
            or (target.st_dev, target.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise SystemExit(1)
        os.unlink(source)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if fd >= 0:
        os.close(fd)
PY
}

# A scheduler drain proof is deliberately narrower than a terminal outcome.
# It proves only that the exact wrapper and every process group it owned have
# stopped, so automatic handling may freeze the semaphore out of `.open`.
# It does NOT authorize publish, worktree removal, a terminal ledger event, or
# a new session generation.  The producer appends the proof under an exclusive
# fcntl lock; this reader takes the matching exclusive lock and validates one
# immutable snapshot.  Missing/duplicate/malformed fields all fail closed.
_freeze_scheduled_drained() {  # <open semaphore> <frozen destination>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import datetime
import fcntl
import os
import re
import stat
import sys
import uuid

path, target = sys.argv[1:]

def validate_and_rename(fd):
    fcntl.flock(fd, fcntl.LOCK_EX)
    info = os.fstat(fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
    ):
        raise SystemExit(1)
    current = os.lstat(path)
    if stat.S_ISLNK(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)
    raw = os.read(fd, info.st_size + 1)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")

    def unique(key):
        prefix = key + ": "
        values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
        if len(values) != 1 or not values[0]:
            raise SystemExit(1)
        return values[0]

    agent = unique("agent")
    session_id = unique("session_id")
    owner_pid = unique("pid")
    run_id = unique("scheduled_run_id")
    opened_at = unique("opened_at")
    drained_at = unique("scheduled_drain_at")
    if unique("scheduled_owner") != "wp-run-scheduled-tsekh1/v1":
        raise SystemExit(1)
    if unique("close_path") != "pipeline":
        raise SystemExit(1)
    if unique("scheduled_drain_proof") != "process-group-empty/v1":
        raise SystemExit(1)
    if unique("scheduled_drain_session_id") != session_id:
        raise SystemExit(1)
    if unique("scheduled_drain_owner_pid") != owner_pid:
        raise SystemExit(1)
    if unique("scheduled_drain_run_id") != run_id:
        raise SystemExit(1)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", run_id):
        raise SystemExit(1)
    if not re.fullmatch(r"[1-9][0-9]*", owner_pid):
        raise SystemExit(1)
    try:
        parsed_uuid = uuid.UUID(session_id)
    except (ValueError, AttributeError):
        raise SystemExit(1)
    if parsed_uuid.version != 4 or str(parsed_uuid) != session_id.lower():
        raise SystemExit(1)
    if os.path.basename(path) != "%s-%s.open" % (agent, session_id):
        raise SystemExit(1)

    def parse_utc(value):
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
            raise SystemExit(1)
        try:
            return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            raise SystemExit(1)

    if parse_utc(drained_at) < parse_utc(opened_at):
        raise SystemExit(1)
    try:
        os.kill(int(owner_pid), 0)
    except ProcessLookupError:
        pass
    except PermissionError:
        raise SystemExit(1)
    else:
        raise SystemExit(1)

    if target != path + ".orphaned-scheduled-drained":
        raise SystemExit(1)
    current = os.lstat(path)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)
    # Portable NOREPLACE freeze. If the process dies after link(2), a retry
    # may finish only the exact same two-link inode; a foreign destination is
    # never overwritten and the source remains the operational barrier.
    if os.path.lexists(target):
        frozen = os.lstat(target)
        linked = os.fstat(fd)
        if (
            stat.S_ISLNK(frozen.st_mode)
            or (frozen.st_dev, frozen.st_ino) != (linked.st_dev, linked.st_ino)
            or linked.st_nlink != 2
        ):
            raise SystemExit(1)
    else:
        if info.st_nlink != 1:
            raise SystemExit(1)
        os.link(path, target, follow_symlinks=False)
        frozen = os.lstat(target)
        linked = os.fstat(fd)
        if (
            stat.S_ISLNK(frozen.st_mode)
            or (frozen.st_dev, frozen.st_ino) != (linked.st_dev, linked.st_ino)
            or linked.st_nlink != 2
        ):
            raise SystemExit(1)
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
        current = os.lstat(path)
        frozen = os.lstat(target)
        if (
            (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
            or (frozen.st_dev, frozen.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise SystemExit(1)
        os.unlink(path)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

fd = -1
try:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    validate_and_rename(fd)
finally:
    if fd >= 0:
        os.close(fd)
PY
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
  # One global, kernel-owned admission/freeze critical section closes the
  # last-reader-wins gap between a new same-WP open and scheduled quarantine.
  # Lock order is always admission (FD195) -> exact session (FD196).
  with_scheduled_admission_lock _sweep_orphaned_semaphores_body
}

_semaphore_transition_lock_id() {  # <absolute semaphore path>
  python3 -c 'import hashlib,sys; print("semaphore-" + hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"
}

_classify_dead_semaphore() {  # <semaphore> <observed pid>
  local semaphore="$1" observed_pid="$2" pid target epoch age
  [ -f "$semaphore" ] && [ ! -L "$semaphore" ] || return 0
  pid=$(grep '^pid: ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [ "$pid" = "$observed_pid" ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]] \
    && ! kill -0 "$pid" 2>/dev/null || return 0

  # A scheduler-owned semaphore is a distinct class.  Even if a stale
  # terminal-looking card is present, automatic handling may only freeze
  # after the exact drain contract; it never publishes/removes.
  if grep -q '^scheduled_owner:' "$semaphore" 2>/dev/null; then
    target="${semaphore}.orphaned-scheduled-drained"
    if _freeze_scheduled_drained "$semaphore" "$target"; then
      echo "WARNING: exact scheduled drain proven for dead owner pid $pid; semaphore frozen, worktree retained" >&2
      _SWEEP_SCHEDULED_FROZEN=$((_SWEEP_SCHEDULED_FROZEN + 1))
      return 0
    fi
    epoch=$(semaphore_epoch "$semaphore" || echo 0)
    age=$(( $(date +%s) - epoch ))
    [ "$age" -lt 0 ] && age=0
    if ! zombie_registry_has_action "$semaphore" "escalated"; then
      append_zombie_event "scheduled_owner_without_exact_drain_proof" \
        "$semaphore" "$epoch" "$age" "escalated"
      notify_zombie_escalation "$semaphore" "$age"
      _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    fi
    echo "WARNING: scheduled owner pid $pid is dead, but exact drain proof is absent; $(basename "$semaphore") remains .open" >&2
    _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
    return 0
  fi

  # Generic dead-PID evidence is never fencing.  Even a terminal-looking
  # mutable card is consumed only by the explicit recovery transaction,
  # which can bind its receipt and ledger recovery_id.  Sweep therefore
  # leaves ordinary sessions `.open` and only escalates.
  epoch=$(semaphore_epoch "$semaphore" || echo 0)
  age=$(( $(date +%s) - epoch ))
  [ "$age" -lt 0 ] && age=0
  if ! zombie_registry_has_action "$semaphore" "escalated"; then
    append_zombie_event "dead_owner_without_terminal_or_drain_proof" \
      "$semaphore" "$epoch" "$age" "escalated"
    notify_zombie_escalation "$semaphore" "$age"
    _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
  fi
  echo "WARNING: pid $pid is dead, but terminal/scheduled-drain proof is absent or changed; $(basename "$semaphore") remains .open" >&2
  _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
}

_sweep_orphaned_semaphores_body() {
  local semaphore pid epoch age
  _SWEEP_AMBIGUOUS=0
  _SWEEP_TERMINAL_REAPED=0
  _SWEEP_SCHEDULED_FROZEN=0
  _SWEEP_ZOMBIES_ESCALATED=0
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
        with_session_transition_lock "$semaphore" _classify_dead_semaphore "$semaphore" "$pid"
      fi
      continue
    fi

    # Missing/invalid PID (all Kimi headless semaphores, by construction) is a
    # zombie candidate, never an immediate delete: unlike a dead numeric PID,
    # there is no proof of death here, only absence of proof of life.
    epoch=$(semaphore_epoch "$semaphore" || true)
    [ -n "$epoch" ] || {
      echo "WARNING: semaphore $(basename "$semaphore") has no live pid or parseable timestamp; manual review required" >&2
      _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
      continue
    }
    age=$(( $(date +%s) - epoch ))

    if [ "$age" -ge "$IWE_ZOMBIE_ESCALATE_SEC" ] \
       && ! zombie_registry_has_action "$semaphore" "escalated"; then
      append_zombie_event "missing_or_invalid_owner_pid" "$semaphore" \
        "$epoch" "$age" "escalated"
      notify_zombie_escalation "$semaphore" "$age"
      _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    fi

    if [ "$age" -gt 1800 ]; then
      echo "WARNING: semaphore $(basename "$semaphore") is ${age}s old without owner PID; age cannot fence a writer, kept .open for manual review" >&2
      _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
    fi
  done < <(find "$SESSION_DIR" -name '*.open' -type f 2>/dev/null)
  echo "Semaphore sweep: terminal_reaped=$_SWEEP_TERMINAL_REAPED scheduled_frozen=$_SWEEP_SCHEDULED_FROZEN ambiguous=$_SWEEP_AMBIGUOUS zombies_escalated=$_SWEEP_ZOMBIES_ESCALATED"
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
SCHEDULED_OWNER=""
SCHEDULED_RUN_ID=""
SESSION_ID_ARG=""
REPO_ARG=""
CLEANUP_ORPHANS=0
FORCE_NO_REFLECTION=""
CANONICAL_OWNER=""
FORCE_FLAG=0
UNFREEZE_REASON=""
ISOLATE_FLAG=0
EXPECTED_HASH=""
EXPECTED_ABSENT=0
HOT_LOCK_TOKEN=""
BASE_SHA=""
RENEW_FOREIGN=0
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
    # WP-545 (2026-09-05): `renew --session-id <X>` без `--foreign` продлевает
    # ЧУЖОЙ семафор (другого agent/session_id) молча — использовано как обход
    # lease-гейта живым инцидентом накануне (peer-session
    # 2026-09-05-01-bot-alerts-diagnostika, продлил 3 просроченных семафора
    # WP-526/WP-539, чтобы pre-commit пропустил СВОЙ коммит). --foreign делает
    # это явным намерением, не побочным эффектом; проверка — в блоке CMD=renew.
    --foreign) RENEW_FOREIGN=1; shift ;;
    --reason)
      # Same class of bug as --force-no-reflection below (WP-520 sixteenth
      # live finding, session-guard.sh:310 at the time): a value-bearing
      # flag passed last with nothing after it makes `$2` a read past the
      # argv end under `set -u`, killing the script mid-parse instead of
      # failing with a readable message.
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--reason требует непустое значение (причина запроса)" 1
      fi
      UNFREEZE_REASON="$2"; shift 2 ;;
    --personality) PERSONALITY="$2"; shift 2 ;;
    --owner-pid) OWNER_PID="$2"; shift 2 ;;
    --scheduled-owner)
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--scheduled-owner требует непустое значение" 1
      fi
      SCHEDULED_OWNER="$2"; shift 2 ;;
    --scheduled-run-id)
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--scheduled-run-id требует непустое значение" 1
      fi
      SCHEDULED_RUN_ID="$2"; shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --repo)
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--repo требует непустое значение (имя репозитория внутри \$IWE_ROOT)" 1
      fi
      REPO_ARG="$2"; shift 2 ;;
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
    # WP-530 Ф24 п.5 (АрхГейт межмашинного замка, 06.09): fencing token
    # захвата hot-file-замка. Держатель предъявляет его в check-hot-lock и
    # unlock-hot-file, чтобы отбор протухшего замка перестал быть невидимым
    # для прежнего держателя.
    --token)
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--token требует непустое значение (fencing token, напечатанный lock-hot-file)" 1
      fi
      HOT_LOCK_TOKEN="$2"; shift 2 ;;
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
    # WP-7 Ф83: was a silent `shift` -- unrecognized flags vanished with no diagnostic.
    -*)       fail "неизвестный флаг: $1" 1 ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$AGENT" ] && { [ "$CMD" = "open" ] || [ "$CMD" = "close" ] || [ "$CMD" = "note-scheduled-drain" ] || [ "$CMD" = "heartbeat" ] || [ "$CMD" = "machine-close" ]; }; then
  fail "--agent обязателен для open/close/machine-close/note-scheduled-drain/heartbeat (или переменная IWE_AGENT)" 1
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

# Scheduled ownership is a closed, versioned producer contract.  The exact
# value prevents accidental/malformed producer drift; it is not an
# authentication boundary (another process of the same user can pass it).
# The orphan classifier below additionally binds it to the long-lived owner
# PID, run id, UUID and an exact drain-proof block.
if [ "$CMD" = "open" ] && { [ -n "$SCHEDULED_OWNER" ] || [ -n "$SCHEDULED_RUN_ID" ]; }; then
  [ "$SCHEDULED_OWNER" = "wp-run-scheduled-tsekh1/v1" ] \
    || fail "--scheduled-owner: поддерживается только wp-run-scheduled-tsekh1/v1" 1
  [[ "$SCHEDULED_RUN_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] \
    || fail "--scheduled-run-id должен быть безопасным токеном длиной 1..128" 1
  [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] \
    || fail "scheduled open требует положительный --owner-pid" 1
  [ "$CLOSE_PATH" = "pipeline" ] \
    || fail "scheduled open требует --close-path pipeline" 1
  python3 - "${IWE_SESSION_ID:-}" <<'PY' >/dev/null 2>&1 \
    || fail "scheduled open требует canonical lowercase UUIDv4 в IWE_SESSION_ID" 1
import sys
import uuid

try:
    value = uuid.UUID(sys.argv[1])
except (AttributeError, ValueError):
    raise SystemExit(1)
if value.version != 4 or str(value) != sys.argv[1]:
    raise SystemExit(1)
PY
elif [ "$CMD" = "note-scheduled-drain" ]; then
  [ -z "$SCHEDULED_OWNER" ] \
    || fail "note-scheduled-drain читает scheduled_owner из semaphore; --scheduled-owner не передавай" 1
  [[ "$SCHEDULED_RUN_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] \
    || fail "note-scheduled-drain требует безопасный --scheduled-run-id длиной 1..128" 1
  [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] \
    || fail "note-scheduled-drain требует положительный --owner-pid" 1
  python3 - "$SESSION_ID_ARG" <<'PY' >/dev/null 2>&1 \
    || fail "note-scheduled-drain требует canonical lowercase UUIDv4 в --session-id" 1
import sys
import uuid

try:
    value = uuid.UUID(sys.argv[1])
except (AttributeError, ValueError):
    raise SystemExit(1)
if value.version != 4 or str(value) != sys.argv[1]:
    raise SystemExit(1)
PY
elif [ "$CMD" = "heartbeat" ]; then
  [[ "$SESSION_ID_ARG" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] \
    || fail "heartbeat требует безопасный --session-id длиной 1..256" 1
  [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] \
    || fail "heartbeat требует положительный --owner-pid вызывающего процесса" 1
  [ -z "$WP$SLUG$HOUSEKEEPING$SCHEDULED_OWNER$SCHEDULED_RUN_ID" ] \
    || fail "heartbeat принимает только --agent/--session-id/--owner-pid" 1
elif [ "$CMD" = "machine-close" ]; then
  [[ "$AGENT" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] \
    || fail "machine-close требует безопасный --agent длиной 1..128" 1
  python3 - "$SESSION_ID_ARG" <<'PY' >/dev/null 2>&1 \
    || fail "machine-close требует canonical lowercase UUIDv4 в --session-id" 1
import sys
import uuid

try:
    value = uuid.UUID(sys.argv[1])
except (AttributeError, ValueError):
    raise SystemExit(1)
if value.version != 4 or str(value) != sys.argv[1]:
    raise SystemExit(1)
PY
  [ -z "$WP$SLUG$TASK$FILES$HOUSEKEEPING$CLOSE_PATH$RESULT_ARG$DEFER_ARG$OWNER_PID$SCHEDULED_OWNER$SCHEDULED_RUN_ID$REPO_ARG$EXPECTED_HASH$BASE_SHA" ] \
    && [ "$ISOLATE_FLAG" -eq 0 ] && [ "$FORCE_FLAG" -eq 0 ] && [ "$EXPECTED_ABSENT" -eq 0 ] \
    || fail "machine-close принимает только --agent и --session-id" 1
  [ "${#POSITIONAL[@]}" -eq 0 ] \
    || fail "machine-close не принимает positional arguments" 1
elif [ -n "$SCHEDULED_OWNER" ] || [ -n "$SCHEDULED_RUN_ID" ]; then
  fail "--scheduled-owner/--scheduled-run-id применимы только к scheduled open/note-scheduled-drain" 1
fi

if [ "$CMD" = "open" ] && [ "$CLOSE_PATH" = "machine-publish-only" ]; then
  [ "$ISOLATE_FLAG" = "1" ] \
    || fail "close_path machine-publish-only требует --isolate" 1
  [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] \
    || fail "close_path machine-publish-only требует положительный --owner-pid" 1
  python3 - "${IWE_SESSION_ID:-}" <<'PY' >/dev/null 2>&1 \
    || fail "close_path machine-publish-only требует canonical lowercase UUIDv4 в IWE_SESSION_ID" 1
import sys
import uuid

try:
    value = uuid.UUID(sys.argv[1])
except (AttributeError, ValueError):
    raise SystemExit(1)
if value.version != 4 or str(value) != sys.argv[1]:
    raise SystemExit(1)
PY
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
    # Freeze applies here too (WP-484, 2026-09-05). This branch returns before the
    # freeze block below ever runs, so `open --housekeeping` used to sail through on
    # the frozen canonical checkout where a plain `open` refuses -- a one-flag way
    # around the freeze, found while Day Close itself took that route. Same rule as
    # a plain open, minus the slug re-entry carve-out (a housekeeping semaphore is
    # keyed by reason, not by slug, and its own TTL branch below already handles
    # resuming): a scheduled runner names itself with --canonical-owner, everyone
    # else goes to an isolated worktree.
    if [ -z "$CANONICAL_OWNER" ]; then
      HK_FROZEN_TOPLEVEL=$(frozen_checkout_match)
      if [ -n "$HK_FROZEN_TOPLEVEL" ]; then
        fail "этот checkout ($HK_FROZEN_TOPLEVEL) под freeze (WP-520/WP-484 Ф104) — housekeeping-сессия здесь не открывается. Плановому раннеру: добавь --canonical-owner <reason>. Остальным: изолированный worktree (EnterWorktree или 'git worktree add' от свежего origin/main)." 1
      fi
    fi

    # Housekeeping is still a short no-ORZ session, but it is a semaphore
    # mutation like every other open.  Age/dead-PID guesses must not clear an
    # operational barrier: only an exact close may make the fixed name reusable.
    [[ "$HOUSEKEEPING" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] \
      || fail "open --housekeeping: reason должен быть безопасным токеном длиной 1..128" 1
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    acquire_scheduled_admission_lock
    acquire_session_transition_lock "$HK_FILE"
    if [ -e "$HK_FILE" ] || [ -L "$HK_FILE" ]; then
      HK_EXISTING_ID=$(_locked_open_identity "$HK_FILE" "$AGENT" "" || true)
      [ -n "$HK_EXISTING_ID" ] \
        || fail "open --housekeeping: existing semaphore небезопасен; mutation запрещена" 1
      fail "open --housekeeping: '${HOUSEKEEPING}' уже открыт; PID/возраст не дают права снять барьер" 1
    fi
    if [ -e "$HK_FILE.closed" ] || [ -L "$HK_FILE.closed" ]; then
      _retire_housekeeping_closed_receipt "$HK_FILE.closed" "$AGENT" "$HOUSEKEEPING" \
        || fail "open --housekeeping: прежний terminal receipt не принадлежит exact agent/reason" 1
    fi
    rm -f "$HK_FILE.lease" \
      || fail "open --housekeeping: прежняя lease projection не удалена" 1
    _new_open_has_no_prior_state "$HK_FILE" \
      || fail "open --housekeeping: найден неизвестный sibling state; автоматический reclaim запрещён" 1
    HK_SID=$(python3 -c 'import uuid; print(uuid.uuid4())') \
      || fail "open --housekeeping: runtime-neutral session id не создан" 1
    SEM_TEMP=$(mktemp "$SESSION_DIR/.housekeeping-open.XXXXXX") \
      || fail "open --housekeeping: temporary semaphore не создан" 1
    chmod 600 "$SEM_TEMP" || fail "open --housekeeping: temporary permissions не установлены" 1
    {
      echo "---"
      echo "agent: $AGENT"
      echo "personality: $PERSONALITY"
      echo "housekeeping: $HOUSEKEEPING"
      echo "slug: $HOUSEKEEPING"
      echo "created_at: $(now_iso)"
      echo "session_id: $HK_SID"
      [ -n "${OWNER_PID:-${CLAUDE_PID:-}}" ] && echo "pid: ${OWNER_PID:-$CLAUDE_PID}"
      echo "---"
    } > "$SEM_TEMP"
    _publish_new_open_semaphore "$SEM_TEMP" "$HK_FILE" \
      || fail "open --housekeeping: atomic no-clobber publication не прошла" 1
    release_session_transition_lock \
      || fail "open --housekeeping: semaphore опубликован, но session lock не освободился" 1
    release_scheduled_admission_lock \
      || fail "open --housekeeping: semaphore опубликован, но admission lock не освободился" 1
    # Маркер standalone-доверия — по тому же id, что попал в семафор.
    if [ "${STANDALONE_LAUNCH:-0}" = "1" ] && [ "$AGENT" = "kimi" ]; then
      : > "$IWE_ROOT/.iwe-runtime/kimi-standalone-${HK_SID}.marker" 2>/dev/null || true
    fi
    echo "Housekeeping OPEN: $HK_FILE (reason: $HOUSEKEEPING)"
    exit 0
  fi

  [ -z "$WP" ] && fail "--wp обязателен для open" 2

  acquire_scheduled_admission_lock
  SCHEDULED_ADMISSION=0
  [ -n "$SCHEDULED_OWNER" ] && SCHEDULED_ADMISSION=1
  if _scheduled_admission_barrier "$WP" "$SCHEDULED_ADMISSION" "$AGENT" "${IWE_SESSION_ID:-}"; then
    :
  else
    ADMISSION_RC=$?
    case "$ADMISSION_RC" in
      1) fail "open: WP $WP удерживается active/frozen quarantine; formal recovery обязателен до новой scheduled generation" 1 ;;
      *) fail "open: quarantine/admission state неоднозначен; fail closed" 1 ;;
    esac
  fi

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
      OTHER_REPO_DIR=$(semaphore_governance_worktree "$OTHER_SEM" || true)
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
    ACTUAL_CWD_TOPLEVEL=$(frozen_checkout_match)
    if [ -n "$ACTUAL_CWD_TOPLEVEL" ]; then
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
    fi
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

    # WP-484 Ф140 (2026-08-28, peer-session with Kimi+Codex): print the resolved
    # repo BEFORE any dirty-check/worktree work, not just at the very end inside
    # the worktree_path JSON -- a silent wrong resolution here was undetectable
    # until the session already lost its files (2026-08-25, session-guard.sh
    # isolated iwe-local-config instead of DS-my-strategy). Strip userinfo from
    # the origin URL (Codex, this session) -- an HTTPS remote can embed a token
    # and this line goes straight to stderr/session logs.
    ISOLATE_BASE_ORIGIN="$(git -C "$ISOLATE_BASE_DIR" remote get-url origin 2>/dev/null || printf '%s\n' "no-origin")"
    case "$ISOLATE_BASE_ORIGIN" in
      *://*@*)
        ISOLATE_ORIGIN_SCHEME="${ISOLATE_BASE_ORIGIN%%://*}"
        ISOLATE_ORIGIN_REST="${ISOLATE_BASE_ORIGIN#*://}"
        # ##*@ (greedy), not #*@ (shortest match): a literal `@` inside the
        # userinfo/password itself (round-2 cold-review, WP-484 Ф140) would
        # otherwise leave a secret fragment after the first `@` in the log.
        ISOLATE_BASE_ORIGIN="${ISOLATE_ORIGIN_SCHEME}://${ISOLATE_ORIGIN_REST##*@}"
        ;;
    esac
    printf 'session-guard: --isolate: изолирую %q (origin: %q)\n' \
      "$ISOLATE_BASE_DIR" "$ISOLATE_BASE_ORIGIN" >&2

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
    # The stable kernel lock is the authority for the whole same-session
    # transition, including dirty/re-entry reads, fetch, worktree creation and
    # semaphore publication.  A crashed creator releases it automatically;
    # the next caller then sees either the exact semaphore/worktree pair or a
    # fail-closed worktree-without-semaphore state, never two concurrent owners.
    acquire_session_transition_lock "$ISOLATE_EXISTING_SEM"

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
      if ! timeout 60 git -C "$ISOLATE_BASE_DIR" fetch origin main --quiet 2>&1; then
        fail "--isolate: git fetch origin main не прошёл -- не создаю worktree от потенциально устаревшего origin/main. Проверь сеть и повтори." 1
      fi
    fi

    ISOLATE_STORE_DIR="$IWE_ROOT/.iwe-runtime/isolated-worktrees"
    mkdir -p "$ISOLATE_STORE_DIR"
    ISOLATE_STORE_DIR_REAL="$(realpath "$ISOLATE_STORE_DIR")"
    ISOLATED_WORKTREE_PATH="$ISOLATE_STORE_DIR/${AGENT}-${ISOLATE_SESSION_ID}"
    ISOLATED_WORKTREE_BRANCH="session-isolate/${AGENT}-${ISOLATE_SESSION_ID}"

    [ -f "$ISOLATE_EXISTING_SEM" ] && ISOLATE_SEM_EXISTS=1 || ISOLATE_SEM_EXISTS=0
    timeout 120 bash -c '
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

    # WP-526 Ф2: no more per-worktree ORZ_ISOLATE_OVERRIDE assignment here
    # (was "$ISOLATED_WORKTREE_PATH/sessions"). The untracked-ORZ-blocks-a-
    # neighbor bug this used to work around (live-reproduced 2026-08-15,
    # 4-agent run, peer-session 2026-08-15-14-isolate-aware-orz-dir) is
    # moot now: ORZ scaffold lands in MC-sessions (see the unconditional
    # resolution below), never inside DS-my-strategy's canonical checkout,
    # isolate or not -- there's nothing left to dirty there.

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
  # Liveness is now decided where it matters (scope gate, via `lease_valid`).
  # Even a dead pid keeps `.open` unless the sweep also has an exact terminal
  # or scheduled-drain proof; age alone only escalates.
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
  SESSION_ID="${ISOLATE_SESSION_ID:-${IWE_SESSION_ID:-$(date +%s)-$(isolate_entropy_suffix)}}"
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
  if [ "$ISOLATE_FLAG" != "1" ]; then
    acquire_session_transition_lock "$SEM_FILE"
  else
    [ "$SEM_FILE" = "$ISOLATE_EXISTING_SEM" ] \
      || fail "--isolate: session semaphore path изменился после lock" 1
    [ -n "$(_validate_session_transition_fd "$_SESSION_TRANSITION_LOCK_PATH" || true)" ] \
      || fail "--isolate: persistent session lock потерян до semaphore publication" 1
  fi
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
  # WP-526 Ф2: session content moved out of DS-my-strategy entirely, into
  # its own repo (MC-sessions) -- one shared location regardless of
  # isolate/non-isolate, so ORZ_ISOLATE_OVERRIDE's old per-worktree copy
  # (removed above, was "$ISOLATED_WORKTREE_PATH/sessions") no longer
  # applies; both paths resolve identically here. `resolve_orz_sessions_dir`
  # fails closed for an already-migrated checkout (MC-sessions exists but is
  # broken, or IWE_SESSIONS_ROOT is set but broken) -- that fallback is
  # exactly the split-brain this move exists to close. A template install
  # that never migrated (MC-sessions was never cloned) gets the pre-Ф2
  # legacy path instead, not an error -- see the function's docstring.
  ORZ_SESSIONS_DIR="$(resolve_orz_sessions_dir)"
  ORZ_FILE="$ORZ_SESSIONS_DIR/$ORZ_BASENAME"
  mkdir -p "$(dirname "$ORZ_FILE")"
  EFFECTIVE_OWNER_PID="${OWNER_PID:-${CLAUDE_PID:-}}"
  REUSE_EXISTING_SEMAPHORE=0
  if [ -e "$SEM_FILE" ] || [ -L "$SEM_FILE" ]; then
    _open_reentry_matches "$SEM_FILE" "$AGENT" "$SESSION_ID" "$WP" "${SLUG:-$WP}" \
      "$PERSONALITY" "${CLOSE_PATH:-unknown}" "${ISOLATED_WORKTREE_PATH:-$CURRENT_REPO_DIR}" \
      "${ISOLATED_WORKTREE_PATH:-}" "${ISOLATED_WORKTREE_BRANCH:-}" "$SCHEDULED_OWNER" \
      "$SCHEDULED_RUN_ID" "$EFFECTIVE_OWNER_PID" "${CLAUDE_CODE_SESSION_ID:-}" \
      "$ORZ_BASENAME" "$ORZ_SESSIONS_DIR" \
      || fail "open re-entry: existing semaphore identity/stage/sibling не совпадает; не перезаписываю" 1
    REUSE_EXISTING_SEMAPHORE=1
  else
    _new_open_has_no_prior_state "$SEM_FILE" \
      || fail "open: для этого session_id уже есть terminal/quarantine/lease state; выбери новый session_id" 1
  fi

  if [ "$REUSE_EXISTING_SEMAPHORE" -eq 0 ]; then
    SEM_TEMP=$(mktemp "$SESSION_DIR/.session-open.XXXXXX") \
      || fail "open: temporary semaphore не создан" 1
    chmod 600 "$SEM_TEMP" || fail "open: temporary semaphore permissions не установлены" 1
    {
    echo "---"
    echo "agent: $AGENT"
    echo "personality: $PERSONALITY"
    echo "wp: $WP"
    echo "$(yaml_task_line "${TASK:-}")"
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
    [ -n "$SCHEDULED_OWNER" ] && echo "scheduled_owner: $SCHEDULED_OWNER"
    [ -n "$SCHEDULED_RUN_ID" ] && echo "scheduled_run_id: $SCHEDULED_RUN_ID"
    # Recorded here so `close` (a separate invocation, possibly a different
    # process/cwd) can read the resolved worktree back instead of
    # recomputing it -- same pattern already used for orz_sessions_dir above.
    echo "governance_worktree: ${ISOLATED_WORKTREE_PATH:-$CURRENT_REPO_DIR}"
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
    # session's own `git status` from a prior, unrelated WP. WP-526 Ф2 (cold-
    # review finding, this session): path used to be relative to $ORZ_DIR's
    # PARENT because ORZ_DIR was a "sessions" subfolder of the governance repo
    # -- now ORZ_DIR IS the MC-sessions repo root, so $ORZ_BASENAME alone is
    # already the correct repo-relative path in that layout (no parent prefix
    # to add).
    #
    # WP-484 (03.09, peer-session "fix-quickclose-test-debt", Codex diagnosis):
    # the comment above is only true when $ORZ_SESSIONS_DIR IS a git repo's
    # root -- the modern MC-sessions layout. resolve_orz_sessions_dir()'s
    # legacy fallback (no MC-sessions repo found) returns "$GOV_REPO/sessions",
    # a SUBDIRECTORY of the governance repo, not its own repo root -- a commit
    # from $GOV_REPO then sees this file at "sessions/$ORZ_BASENAME", one path
    # segment longer than what used to be registered here unconditionally, so
    # the scope gate's exact-match never fired (live-reproduced, legacy layout
    # only). Compute the git-root-relative path the same way note-file already
    # does for the general case (below, ~line 2645), instead of assuming
    # $ORZ_BASENAME already is one -- realpath() on BOTH sides is required,
    # not optional: `git rev-parse --show-toplevel` resolves symlinks (macOS
    # /var -> /private/var), while $ORZ_FILE is built from $IWE_ROOT verbatim
    # -- os.path.relpath() on one resolved + one unresolved absolute path
    # produces a long, wrong "../../../private/var/..." chain instead of the
    # short in-repo path (caught live testing this same fix, mktemp -d sandbox).
    ORZ_GIT_ROOT="$(git -C "$ORZ_SESSIONS_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$ORZ_SESSIONS_DIR")"
    ORZ_REL_PATH="$(python3 -c "
import os, sys
f = os.path.realpath(sys.argv[1])
r = os.path.realpath(sys.argv[2])
print(os.path.relpath(f, r))
" "$ORZ_FILE" "$ORZ_GIT_ROOT")"
    echo "file: $ORZ_REL_PATH"
    # Same class of gap as the ORZ line above (Ф32 п.5), found for --isolate
    # re-entry (peer-session 2026-08-14-13, turn 15, Codex): OPEN_LOG's own
    # append below is a real, expected, this-session side effect --
    # registering it here means the isolate re-entry check (below in this
    # same script) can trust the `file:` allowlist instead of guessing this
    # specific filename by name.
    echo "file: $(basename "$(dirname "$OPEN_LOG")")/$(basename "$OPEN_LOG")"
    } > "$SEM_TEMP"
    _publish_new_open_semaphore "$SEM_TEMP" "$SEM_FILE" \
      || fail "open: atomic no-clobber semaphore publication не прошла" 1
  fi
  # Marker is a projection: a missing marker can be rebuilt, while a marker
  # without a durable semaphore must never be treated as session authority.
  if [ "${STANDALONE_LAUNCH:-0}" = "1" ] && [ "$AGENT" = "kimi" ] && [ -n "$SESSION_ID" ]; then
    : > "$IWE_ROOT/.iwe-runtime/kimi-standalone-${SESSION_ID}.marker" 2>/dev/null || true
  fi
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
  # The authority mutation is complete.  Release both kernel locks before
  # best-effort status/ledger/version children so a detached publisher cannot
  # inherit and prolong admission/session ownership.
  release_session_transition_lock \
    || fail "Session OPEN опубликован, но exact session lock не освободился; проверь $SEM_FILE" 1
  release_scheduled_admission_lock \
    || fail "Session OPEN опубликован, но admission lock не освободился; проверь $SEM_FILE" 1
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
  # session_opened ledger event (WP-561 Ф6-а, TACT-01 contract DP.SC.201;
  # designed peer-session 2026-09-03-13-wp561-sync-next-steps). Best-effort,
  # never blocks open -- same discipline as session_closed_direct below.
  # sync_gate_marker_present surfaces the .claude/state/wp-sync-<WP>.done
  # freshness race-guard that protocol-open.md Sync Gate already writes as a
  # mechanically checkable fact instead of trusting the agent's declaration
  # that it ran Sync Gate; it does not enforce Sync Gate, only records it.
  if [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    _sync_marker="$IWE_ROOT/.claude/state/wp-sync-${WP}.done"
    if find "$_sync_marker" -mmin -480 >/dev/null 2>&1; then
      _sync_marker_present=true
    else
      _sync_marker_present=false
    fi
    _open_event=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3],
                   "task": sys.argv[4], "sync_gate_marker_present": sys.argv[5] == "true"}))
' "$WP" "${SLUG:-$WP}" "$AGENT" "${TASK:-}" "$_sync_marker_present" 2>/dev/null) || _open_event=""
    if [ -n "$_open_event" ]; then
      bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_opened "$_open_event" session-guard \
        >/dev/null 2>&1 || echo "  ⚠️  ledger session_opened не записан (best-effort, не блокирует open)" >&2
    fi
  fi
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
validate_orz() { # <orz-path> <agent> [orz-base-dir, default $ORZ_DIR] [tracked-set-file, optional]
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
  orz_base_dir="${orz_base_dir%/}"
  local tracked_set_file="${4:-}"
  local errors=0

  # 1. file exists
  if [ ! -f "$orz" ]; then
    echo "  ❌ ORZ-файл не найден: $orz" >&2
    return 1
  fi

  # Checks 2-4 read the file once into a bash variable and use builtin
  # pattern matching instead of ~13 `grep`/`sed`/`head` subprocesses per
  # call (6 key checks + 1 agent-value pipeline + 4 section checks, plus a
  # duplicate agent-value pipeline the audit() call site used to run before
  # calling in here at all). Measured live 31.08 (peer-session with
  # Kimi+Codex, WP-484 line AC): with ~3771 files in MC-sessions this was
  # the dominant cost keeping `audit` from finishing inside a 5-minute
  # timeout even after the git-tracked check (below) was batched.
  # `$'\n'` is prepended so "key at the very start of the file" and "key
  # after a newline" are the same substring match, matching what the old
  # `grep -qE "^key:"` anchor covered without needing multiline `^`.
  local nl=$'\n'
  local content
  content="$(<"$orz")" 2>/dev/null || content=""
  local content_nl="${nl}${content}"

  # 2. frontmatter keys
  local keys=("date:" "type:" "wp:" "duration_h:" "artifacts:" "agent:")
  for key in "${keys[@]}"; do
    case "$content_nl" in
      *"${nl}${key}"*) : ;;
      *)
        echo "  ❌ в frontmatter отсутствует ключ '$key'" >&2
        errors=$((errors + 1))
        ;;
    esac
  done

  # 3. agent value
  # `[ -n "$agent" ]` guard added WP-484 line AC (31.08): the audit() call
  # site used to pre-extract the file's own agent: value with a redundant
  # grep|sed|head pipeline and feed it straight back in here as `$agent`,
  # which made this comparison a self-match that could never fail -- proven
  # by re-running before/after this fix's benchmark and diffing every
  # reported defect. Passing "" from that call site (agent identity isn't
  # meaningful for an archival scan) reproduces the same always-skip outcome
  # without redoing the extraction. close()'s real caller always has a
  # non-empty --agent (validated earlier in this script), so this guard
  # changes nothing there.
  local orz_agent="" agent_re="${nl}agent:[[:space:]]*([^${nl}]*)"
  if [[ "$content_nl" =~ $agent_re ]]; then
    orz_agent="${BASH_REMATCH[1]}"
  fi
  if [ -n "$agent" ] && [ -n "$orz_agent" ]; then
    if [ "$orz_agent" != "$agent" ] && \
       ! { [ "$agent" = "kimi" ] && [ "$orz_agent" = "kimi-headless" ]; }; then
      echo "  ❌ agent в ORZ ('$orz_agent') не совпадает с агентом сессии ('$agent')" >&2
      errors=$((errors + 1))
    fi
  fi

  # 4. required sections
  local sections=("## Главный инсайт" "## Контекст" "## Достигнуто" "## Ключевые решения")
  for sec in "${sections[@]}"; do
    case "$content" in
      *"$sec"*) : ;;
      *)
        echo "  ❌ отсутствует секция '$sec'" >&2
        errors=$((errors + 1))
        ;;
    esac
  done

  # 5. git tracked
  local rel
  local is_tracked=1
  if [ -n "$tracked_set_file" ] && [ -s "$tracked_set_file" ]; then
    # Batch path (audit section 3, WP-484 line AC): one `git ls-files` call up
    # front instead of one `git ls-files --error-unmatch` per file, AND skip
    # the python3 relpath subprocess too -- measured live 31.08 (peer-session
    # with Kimi+Codex) that with the git call removed, python3 startup
    # (~30-40ms) was the larger remaining per-file cost against ~3771 files
    # in MC-sessions, not the grep lookup itself. Safe to inline here because
    # this call site's `orz` always comes from `find "$ORZ_DIR" ...`, so it is
    # always a literal `$orz_base_dir/...` path; the general fallback below
    # (other callers) keeps os.path.relpath, which also covers the
    # non-prefixed cases it was added for (WP-520 case 8).
    rel="${orz#"$orz_base_dir"/}"
    grep -qxF "$rel" "$tracked_set_file" && is_tracked=0
  else
    rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[3]))" -- "$orz" "$orz_base_dir")"
    git -C "$orz_base_dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1 && is_tracked=0
  fi
  if [ "$is_tracked" -ne 0 ]; then
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
# WP-526 Ф2: modern MC-sessions registers 00-index.md bare; template installs
# that still use the supported legacy layout register sessions/00-index.md.
# Keep these as two exact aliases. A basename/glob exemption would let an
# unrelated nested 00-index.md bypass the close cleanliness gate.
is_append_safe_session_path() { # <repo-relative path>
  case "$1" in
    00-index.md|sessions/00-index.md) return 0 ;;
    *) return 1 ;;
  esac
}

session_scope_dirty_paths() { # <semaphore> — prints only dirty registered paths
  local semaphore="$1" registered_path status scope_repo_dir sessions_repo_dir runner_card checked_dir
  local canonical_fallback=0 canonical_fallback_warned=0
  # The ORZ snapshot names the worktree that owns this session's GOVERNANCE
  # work (WP cards, code). Checking the canonical checkout here makes
  # unrelated current work look like this session's dirt and permanently
  # blocks a clean isolated close.
  scope_repo_dir=$(semaphore_governance_worktree "$semaphore" || true)
  if [ -z "$scope_repo_dir" ] || { [ ! -d "$scope_repo_dir/.git" ] && [ ! -f "$scope_repo_dir/.git" ]; }; then
    # Legacy/corrupt semaphores without a trustworthy checkout keep the old
    # canonical fallback. Warning on mere absence would fire on every legacy
    # ordinary close, so surface it only below when that fallback finds dirt.
    canonical_fallback=1
    scope_repo_dir="$IWE_ROOT/$GOV_REPO"
  fi
  # WP-526 Ф2 (cold-review finding + live-reproduced bypass, this session):
  # a session's registered files can now legitimately live in TWO different
  # repos -- governance work in $scope_repo_dir above, session content
  # (peer-conversation transcripts) in MC-sessions. The single-repo check
  # this function had before silently found "clean" for every session-
  # content path once $ORZ_SESSIONS_DIR stopped being a subfolder of the
  # governance repo -- close could ship real uncommitted MC-sessions content
  # with no warning. $ORZ_SESSIONS_DIR (read from the semaphore, same field
  # `open` recorded) is MC-sessions itself now, so use it directly as the
  # second candidate, no dirname().
  sessions_repo_dir=$(grep '^orz_sessions_dir: ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [ -n "$sessions_repo_dir" ] || sessions_repo_dir="$ORZ_DIR"
  while IFS= read -r registered_path; do
    registered_path="${registered_path#file: }"
    [ -n "$registered_path" ] || continue
    is_append_safe_session_path "$registered_path" && continue
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
    checked_dir="$scope_repo_dir"
    status=$(git -c core.quotePath=false -C "$scope_repo_dir" status --porcelain --untracked-files=all -- "$registered_path" 2>/dev/null || true)
    if [ -z "$status" ] && [ "$sessions_repo_dir" != "$scope_repo_dir" ] \
       && { [ -d "$sessions_repo_dir/.git" ] || [ -f "$sessions_repo_dir/.git" ]; }; then
      checked_dir="$sessions_repo_dir"
      status=$(git -c core.quotePath=false -C "$sessions_repo_dir" status --porcelain --untracked-files=all -- "$registered_path" 2>/dev/null || true)
    fi
    [ -z "$status" ] && continue
    while IFS= read -r status_line; do
      [ -n "$status_line" ] || continue
      case "$status_line" in
        # ' M' (tracked, modified vs the parked foreign branch's HEAD) joins
        # '??' for the same reason: a shared checkout parked on another agent's
        # branch legitimately carries main's newer version of shared scripts.
        "?? "*|" M "*)
          _untracked_matches_published "$checked_dir" "${status_line:3}" && continue
          ;;
      esac
      # checked_dir may have moved on to $sessions_repo_dir just above (WP-526
      # Ф2, MC-sessions content) -- that fallback is unrelated to a manually
      # bypassed `--isolate`, so only warn when the divergence was actually
      # found in $scope_repo_dir, the canonical governance checkout itself
      # (cold-review finding, this session: the message used to hardcode
      # $IWE_ROOT/$GOV_REPO and fire even when the real diverging path was
      # sessions_repo_dir -- pointed the pilot at the wrong, clean directory).
      if [ "$canonical_fallback" = 1 ] && [ "$checked_dir" = "$scope_repo_dir" ] && [ "$canonical_fallback_warned" = 0 ]; then
        echo "session-guard: close: семафор без isolated_worktree/governance_worktree, а по каноническому чекауту ($checked_dir) есть расхождение -- если эта сессия работала в собственноручно созданной копии (в обход 'open --isolate'), сверка ниже может ошибочно показать чужую грязь или не увидеть уже опубликованные файлы." >&2
        canonical_fallback_warned=1
      fi
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

_unique_record_field() {  # <file> <top-level key>
  awk -v prefix="$2: " '
    index($0, prefix) == 1 { count++; value=substr($0, length(prefix) + 1) }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  ' "$1" 2>/dev/null
}

_repo_head_has_publish_proof() {  # <repo> <role>
  local repo="$1" role="$2" root origin_url origin_ref
  root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || {
    echo "Session CLOSE: $role не является читаемым git checkout: $repo" >&2
    return 1
  }
  origin_url=$(git -C "$root" remote get-url origin 2>/dev/null) || {
    echo "Session CLOSE: $role не имеет origin; clean без publish proof запрещён: $root" >&2
    return 1
  }
  [ -n "$origin_url" ] || {
    echo "Session CLOSE: $role имеет пустой origin; clean без publish proof запрещён: $root" >&2
    return 1
  }
  if ! timeout 10 git -C "$root" fetch --quiet origin \
      '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
    echo "Session CLOSE: свежий origin/main для $role не получен; кэш не считаю publish proof: $root" >&2
    return 1
  fi
  origin_ref=$(git -C "$root" rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null) || {
    echo "Session CLOSE: $role не имеет проверяемого refs/remotes/origin/main: $root" >&2
    return 1
  }
  if ! git -C "$root" merge-base --is-ancestor HEAD "$origin_ref" 2>/dev/null; then
    echo "Session CLOSE: HEAD $role не достижим из origin/main; есть неподтверждённая доставка: $root" >&2
    return 1
  fi
  return 0
}

_claimed_commits_have_publish_proof() {  # <semaphore>
  local semaphore="$1" entry repo_name commit_sha repo_dir fetched=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    repo_name=${entry%% *}
    commit_sha=${entry#* }
    [ "$repo_name" != "$entry" ] \
      && [[ "$repo_name" =~ ^[A-Za-z0-9._-]+$ ]] \
      && [[ "$commit_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] \
      || { echo "Session CLOSE: malformed commit claim: $entry" >&2; return 1; }
    if [ "$repo_name" = "iwe-root" ] || [ "$repo_name" = "$(basename "$IWE_ROOT")" ]; then
      repo_dir="$IWE_ROOT"
    else
      repo_dir="$IWE_ROOT/$repo_name"
    fi
    git -C "$repo_dir" cat-file -e "$commit_sha^{commit}" 2>/dev/null \
      || { echo "Session CLOSE: claimed commit не читается: $repo_name $commit_sha" >&2; return 1; }
    if ! printf '%s\n' "$fetched" | grep -qxF "$repo_dir"; then
      git -C "$repo_dir" remote get-url origin >/dev/null 2>&1 \
        || { echo "Session CLOSE: claimed repo не имеет origin: $repo_name" >&2; return 1; }
      timeout 10 git -C "$repo_dir" fetch --quiet origin \
        '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null \
        || { echo "Session CLOSE: свежий origin/main не получен для claimed repo: $repo_name" >&2; return 1; }
      fetched="${fetched}${repo_dir}"$'\n'
    fi
    if git -C "$repo_dir" merge-base --is-ancestor "$commit_sha" refs/remotes/origin/main 2>/dev/null; then
      continue
    fi
    # isolate-push delivers linear commits by cherry-picking them onto fresh
    # origin/main, so the published commit has a different SHA.  Require the
    # same remote-first patch-equivalence proof used by commit-push.sh; merge
    # commits deliberately have no such proof and fail closed.
    if [ "$(git -C "$repo_dir" rev-list --no-walk --count --merges "$commit_sha" 2>/dev/null || echo 0)" = "1" ]; then
      echo "Session CLOSE: claimed merge commit не является предком origin/main; patch proof неприменим: $repo_name $commit_sha" >&2
      return 1
    fi
    if git -C "$repo_dir" rev-parse --verify --quiet "${commit_sha}^1" >/dev/null 2>&1; then
      git -C "$repo_dir" cherry refs/remotes/origin/main "$commit_sha" "${commit_sha}~1" 2>/dev/null \
        | grep -q '^- ' \
        || { echo "Session CLOSE: claimed commit не опубликован и не имеет patch-эквивалента в origin/main: $repo_name $commit_sha" >&2; return 1; }
    else
      local wanted_patch candidate candidate_patch matched=0
      wanted_patch=$(git -C "$repo_dir" diff-tree -p --root "$commit_sha" 2>/dev/null \
        | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
      [ -n "$wanted_patch" ] \
        || { echo "Session CLOSE: patch-id корневого claimed commit не вычислен: $repo_name $commit_sha" >&2; return 1; }
      while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        candidate_patch=$(git -C "$repo_dir" diff-tree -p --root "$candidate" 2>/dev/null \
          | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
        if [ "$candidate_patch" = "$wanted_patch" ]; then
          matched=1
          break
        fi
      done < <(git -C "$repo_dir" rev-list --max-count=200 refs/remotes/origin/main 2>/dev/null)
      [ "$matched" -eq 1 ] \
        || { echo "Session CLOSE: patch-эквивалент корневого claimed commit не найден в origin/main: $repo_name $commit_sha" >&2; return 1; }
    fi
  done < <(sed -n 's/^commit: //p' "$semaphore")
  return 0
}

_terminal_proof_snapshot_sha() {  # <file|sentinel> <accepted card/sentinel>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import hashlib
import os
import re
import stat
import sys

kind, value = sys.argv[1:]
if kind == "file":
    fd = os.open(value, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        current = os.lstat(value)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_nlink != 1
            or info.st_size <= 0
            or info.st_size > 1024 * 1024
            or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise SystemExit(1)
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        data = b"".join(chunks)
        if len(data) != info.st_size or b"\0" in data or not data.endswith(b"\n"):
            raise SystemExit(1)
    finally:
        os.close(fd)
    material = b"file\0" + os.path.realpath(value).encode("utf-8") + b"\0" + data
elif kind == "sentinel":
    # Sentinels are a closed set produced by the already-completed close
    # policy gate.  A missing RUN card path must never silently become one.
    if not re.fullmatch(
        r"(?:declared-peer-session|declared-publish-only|declared-machine-publish-only|cancel-obligation):[A-Za-z0-9._-]{1,256}",
        value,
    ):
        raise SystemExit(1)
    material = b"sentinel\0" + value.encode("utf-8")
else:
    raise SystemExit(1)
print(hashlib.sha256(material).hexdigest())
PY
}

_terminal_card_snapshot_sha() {  # <card> <mode> <owner-or-empty> <WP-N> <slug>; validates and hashes one FD snapshot
  python3 - "$@" <<'PY' 2>/dev/null
import hashlib
import os
import re
import stat
import sys

try:
    import yaml
except ImportError:
    raise SystemExit(1)

path, mode, expected_owner, expected_wp, expected_slug = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
finally:
    os.close(fd)
if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
    raise SystemExit(1)
text = raw.decode("utf-8")
match = re.match(r"^---\n(.*?)\n---(?:\n|$)", text, re.S)
if not match:
    raise SystemExit(1)
frontmatter = match.group(1)

def top_values(key):
    pattern = re.compile(r"^" + re.escape(key) + r":\s*(.*?)\s*$")
    values = []
    for line in frontmatter.splitlines():
        found = pattern.match(line)
        if found:
            values.append(found.group(1))
    return values

for key in (
    "process_id", "run_id", "requested_slug", "status", "current_step",
    "owner_session_id",
):
    if len(top_values(key)) > 1:
        raise SystemExit(1)
doc = yaml.safe_load(frontmatter) or {}
if not isinstance(doc, dict) or doc.get("process_id") != "quick-close":
    raise SystemExit(1)
status = doc.get("status")
step = doc.get("current_step")
results = doc.get("results") if isinstance(doc.get("results"), dict) else {}
if mode in {"completed", "marker-completed", "owner-completed"}:
    if status != "completed" or step != "done":
        raise SystemExit(1)
elif mode == "release-step":
    verify_result = results.get("verify-r23")
    verdict = verify_result.get("verdict") if isinstance(verify_result, dict) else None
    if status != "running" or step != "session-guard-release" or verdict in (None, "", "null", "~"):
        raise SystemExit(1)
elif mode == "archive-cancelled":
    if status != "cancelled" or step != "wp-archive-run":
        raise SystemExit(1)
elif mode == "blocked-witness":
    if step != "blocked-witness-unavailable":
        raise SystemExit(1)
else:
    raise SystemExit(1)
if mode in {"archive-cancelled", "blocked-witness"}:
    all_pushed = doc.get("all_pushed") is True
    commit_needed = doc.get("commit_needed") is False
    for value in results.values():
        if isinstance(value, dict):
            all_pushed = all_pushed or value.get("all_pushed") is True
            commit_needed = commit_needed or value.get("commit_needed") is False
    if not (all_pushed or commit_needed):
        raise SystemExit(1)
owner = doc.get("owner_session_id")
if not expected_owner or owner != expected_owner:
    raise SystemExit(1)

card_wp = ""
for stage in ("gather-session-facts", "wp-context-update"):
    value = results.get(stage)
    candidate = value.get("wp") if isinstance(value, dict) else None
    candidate = re.sub(r"^wp-", "", "" if candidate is None else str(candidate).strip(), flags=re.I)
    if candidate:
        card_wp = "WP-" + candidate
        break
if card_wp.upper() != expected_wp.upper():
    raise SystemExit(1)
requested_slug = doc.get("requested_slug")
if mode not in {"marker-completed", "owner-completed"}:
    if requested_slug != expected_slug:
        raise SystemExit(1)
elif not isinstance(requested_slug, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,256}", requested_slug):
    raise SystemExit(1)
prefix = "RUN-quick-close-" + requested_slug
name = os.path.basename(path)
if not (name == prefix + ".md" or name.startswith(prefix + "-")):
    raise SystemExit(1)
run_id = doc.get("run_id")
if not isinstance(run_id, str) or name != "RUN-" + run_id + ".md":
    raise SystemExit(1)
material = b"file\0" + os.path.realpath(path).encode("utf-8") + b"\0" + raw
print(hashlib.sha256(material).hexdigest())
PY
}

_session_commit_claims_json() {  # <semaphore>
  sed -n 's/^commit: //p' "$1" | LC_ALL=C sort -u | python3 -c \
    'import json,sys; print(json.dumps([line for line in sys.stdin.read().splitlines() if line], separators=(",", ":")))'
}

_worktree_clean_status_sha() {  # <worktree>; prints hash only for exact clean status
  python3 - "$1" <<'PY' 2>/dev/null
import hashlib
import subprocess
import sys

status = subprocess.run(
    ["git", "-C", sys.argv[1], "status", "--porcelain=v2", "-z", "--untracked-files=all"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
ignored = subprocess.run(
    ["git", "-C", sys.argv[1], "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
if status.returncode != 0 or ignored.returncode != 0 or status.stdout or ignored.stdout:
    raise SystemExit(1)
print(hashlib.sha256(b"status-v2\0" + status.stdout + b"ignored\0" + ignored.stdout).hexdigest())
PY
}

_isolated_source_commits_json() {  # <worktree> <base> <head>
  git -C "$1" rev-list --reverse "$2..$3" 2>/dev/null | python3 -c '
import json
import re
import sys

commits = sys.stdin.read().splitlines()
if any(not re.fullmatch(r"[0-9a-fA-F]{40,64}", item) for item in commits):
    raise SystemExit(1)
print(json.dumps(commits, separators=(",", ":")))
'
}

_close_delivery_state() {  # <semaphore> <session-id> [state|prepared-hook-json]
  python3 - "$1" "$2" "${3:-state}" <<'PY' 2>/dev/null
import hashlib
import json
import os
import re
import stat
import sys
import uuid

path, expected_session, output_mode = sys.argv[1:]
if output_mode not in {"state", "prepared-hook-json"}:
    raise SystemExit(1)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink not in (1, 2)
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")
    raw_sha256 = hashlib.sha256(raw).hexdigest()
    snapshot_dev = info.st_dev
    snapshot_ino = info.st_ino
    if info.st_nlink == 2:
        closed = os.lstat(path + ".closed")
        if stat.S_ISLNK(closed.st_mode) or (closed.st_dev, closed.st_ino) != (info.st_dev, info.st_ino):
            raise SystemExit(1)
finally:
    os.close(fd)

prepare_keys = (
    "close_delivery_version", "close_attempt_id", "close_delivery_session_id",
    "close_delivery_worktree", "close_delivery_common_dir",
    "close_delivery_origin", "close_delivery_target_ref",
    "close_delivery_source_base", "close_delivery_source_head",
    "close_delivery_source_commits", "close_delivery_source_commits_digest",
    "close_delivery_source_status_sha256", "close_delivery_expected_commits",
    "close_delivery_claimed_commits",
    "close_delivery_terminal_kind", "close_delivery_terminal_reference",
    "close_delivery_terminal_sha256", "close_delivery_semaphore_sha256",
    "close_delivery_prepare_digest",
)
publish_keys = (
    "close_publish_proof", "close_publish_session_id",
    "close_publish_prepare_digest", "close_publish_source_head",
    "close_publish_source_status_sha256", "close_publish_terminal_sha256",
    "close_publish_remote_main_sha", "close_publish_verified_commits",
    "close_publish_digest",
)
cleanup_keys = (
    "close_cleanup_proof", "close_cleanup_session_id",
    "close_cleanup_publish_digest",
)

def values(key):
    prefix = key + ": "
    return [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]

present_prepare = [key for key in prepare_keys if values(key)]
present_publish = [key for key in publish_keys if values(key)]
present_cleanup = [key for key in cleanup_keys if values(key)]
if not present_prepare and not present_publish and not present_cleanup:
    if output_mode != "state":
        raise SystemExit(1)
    print("none")
    raise SystemExit(0)
if len(present_prepare) != len(prepare_keys):
    raise SystemExit(1)
fields = {}
for key in prepare_keys:
    found = values(key)
    if len(found) != 1 or not found[0]:
        raise SystemExit(1)
    fields[key] = found[0]
if fields["close_delivery_version"] != "isolate-push/v2":
    raise SystemExit(1)
if fields["close_delivery_session_id"] != expected_session:
    raise SystemExit(1)
try:
    attempt = uuid.UUID(fields["close_attempt_id"])
except (AttributeError, ValueError):
    raise SystemExit(1)
if attempt.version != 4 or str(attempt) != fields["close_attempt_id"]:
    raise SystemExit(1)
for key in (
    "close_delivery_source_base", "close_delivery_source_head",
    "close_delivery_source_commits_digest", "close_delivery_source_status_sha256",
    "close_delivery_terminal_sha256", "close_delivery_semaphore_sha256",
    "close_delivery_prepare_digest",
):
    if not re.fullmatch(r"[0-9a-f]{40,64}", fields[key]):
        raise SystemExit(1)
try:
    source_commits = json.loads(fields["close_delivery_source_commits"])
    expected = json.loads(fields["close_delivery_expected_commits"])
    claimed = json.loads(fields["close_delivery_claimed_commits"])
except (TypeError, ValueError):
    raise SystemExit(1)
if (
    not isinstance(source_commits, list)
    or any(not isinstance(item, str) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", item) for item in source_commits)
    or len(source_commits) != len(set(source_commits))
    or expected != source_commits
    or not isinstance(claimed, list)
    or any(not isinstance(item, str) for item in claimed)
    or any(not re.fullmatch(r"[A-Za-z0-9._-]+ [0-9a-fA-F]{40,64}", item) for item in claimed)
    or claimed != sorted(set(claimed))
):
    raise SystemExit(1)
source_digest = hashlib.sha256(
    json.dumps(source_commits, separators=(",", ":")).encode()
).hexdigest()
if source_digest != fields["close_delivery_source_commits_digest"]:
    raise SystemExit(1)
if fields["close_delivery_terminal_kind"] not in {"file", "sentinel"}:
    raise SystemExit(1)
terminal_reference = fields["close_delivery_terminal_reference"]
if "\n" in terminal_reference or "\0" in terminal_reference:
    raise SystemExit(1)
if (
    not fields["close_delivery_origin"]
    or "\n" in fields["close_delivery_origin"]
    or "\0" in fields["close_delivery_origin"]
    or fields["close_delivery_target_ref"] != "refs/heads/main"
):
    raise SystemExit(1)
if fields["close_delivery_terminal_kind"] == "file" and not os.path.isabs(terminal_reference):
    raise SystemExit(1)
if fields["close_delivery_terminal_kind"] == "sentinel" and not re.fullmatch(
    r"(?:declared-peer-session|declared-publish-only|declared-machine-publish-only|cancel-obligation):[A-Za-z0-9._-]{1,256}",
    terminal_reference,
):
    raise SystemExit(1)
payload = {
    "version": fields["close_delivery_version"],
    "close_attempt_id": fields["close_attempt_id"],
    "session_id": fields["close_delivery_session_id"],
    "worktree": fields["close_delivery_worktree"],
    "common_dir": fields["close_delivery_common_dir"],
    "origin": fields["close_delivery_origin"],
    "target_ref": fields["close_delivery_target_ref"],
    "source_base": fields["close_delivery_source_base"],
    "source_head": fields["close_delivery_source_head"],
    "source_commits": source_commits,
    "source_commits_digest": fields["close_delivery_source_commits_digest"],
    "source_status_sha256": fields["close_delivery_source_status_sha256"],
    "expected_commits": expected,
    "claimed_commits": claimed,
    "terminal_kind": fields["close_delivery_terminal_kind"],
    "terminal_reference": fields["close_delivery_terminal_reference"],
    "terminal_sha256": fields["close_delivery_terminal_sha256"],
    "semaphore_sha256": fields["close_delivery_semaphore_sha256"],
}
digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if digest != fields["close_delivery_prepare_digest"]:
    raise SystemExit(1)
if not present_publish:
    if present_cleanup:
        raise SystemExit(1)
    if output_mode == "prepared-hook-json":
        print(json.dumps({
            "state": "prepared",
            "semaphore_sha256": raw_sha256,
            "semaphore_dev": snapshot_dev,
            "semaphore_ino": snapshot_ino,
            "session_id": expected_session,
            "worktree": fields["close_delivery_worktree"],
            "common_dir": fields["close_delivery_common_dir"],
            "origin": fields["close_delivery_origin"],
            "target_ref": fields["close_delivery_target_ref"],
            "source_commits": source_commits,
            "scope": values("file"),
        }, sort_keys=True, separators=(",", ":")))
    else:
        print("prepared")
    raise SystemExit(0)
if len(present_publish) != len(publish_keys):
    raise SystemExit(1)
published = {}
for key in publish_keys:
    found = values(key)
    if len(found) != 1 or not found[0]:
        raise SystemExit(1)
    published[key] = found[0]
if (
    published["close_publish_proof"] != "isolate-push-exit0/v1"
    or published["close_publish_session_id"] != expected_session
    or published["close_publish_prepare_digest"] != digest
    or published["close_publish_source_head"] != fields["close_delivery_source_head"]
    or published["close_publish_source_status_sha256"] != fields["close_delivery_source_status_sha256"]
    or published["close_publish_terminal_sha256"] != fields["close_delivery_terminal_sha256"]
    or not re.fullmatch(r"[0-9a-f]{40,64}", published["close_publish_remote_main_sha"])
):
    raise SystemExit(1)
try:
    verified = json.loads(published["close_publish_verified_commits"])
except (TypeError, ValueError):
    raise SystemExit(1)
if verified != expected:
    raise SystemExit(1)
publish_payload = {
    "proof": published["close_publish_proof"],
    "session_id": published["close_publish_session_id"],
    "prepare_digest": digest,
    "source_head": published["close_publish_source_head"],
    "source_status_sha256": published["close_publish_source_status_sha256"],
    "terminal_sha256": published["close_publish_terminal_sha256"],
    "remote_main_sha": published["close_publish_remote_main_sha"],
    "verified_commits": verified,
}
publish_digest = hashlib.sha256(
    json.dumps(publish_payload, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if publish_digest != published["close_publish_digest"]:
    raise SystemExit(1)
if not present_cleanup:
    if output_mode != "state":
        raise SystemExit(1)
    print("published")
    raise SystemExit(0)
if len(present_cleanup) != len(cleanup_keys):
    raise SystemExit(1)
cleanup = {}
for key in cleanup_keys:
    found = values(key)
    if len(found) != 1 or not found[0]:
        raise SystemExit(1)
    cleanup[key] = found[0]
if (
    cleanup["close_cleanup_proof"] != "worktree-absent/v1"
    or cleanup["close_cleanup_session_id"] != expected_session
    or cleanup["close_cleanup_publish_digest"] != publish_digest
):
    raise SystemExit(1)
if output_mode != "state":
    raise SystemExit(1)
print("cleaned")
PY
}

_append_close_fields_atomic() {  # <semaphore> <JSON object of exact close_/recovery_ fields>
  python3 - "$1" "$2" <<'PY'
import json
import os
import stat
import sys

path, fields_json = sys.argv[1:]
fields = json.loads(fields_json)
if not isinstance(fields, dict) or not fields:
    raise SystemExit(1)
if any(
    not isinstance(key, str) or not key.startswith(("close_", "recovery_"))
    or not isinstance(value, str) or not value or "\n" in value or "\0" in value
    for key, value in fields.items()
):
    raise SystemExit(1)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
temporary = path + ".stage.%d" % os.getpid()
temp_fd = -1
try:
    info = os.fstat(fd)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
        or stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit(1)
    text = raw.decode("utf-8")
    existing = {}
    for key, value in fields.items():
        prefix = key + ": "
        found = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
        if found and found != [value]:
            raise SystemExit(1)
        existing[key] = found
    if any(existing.values()):
        if all(existing[key] == [value] for key, value in fields.items()):
            raise SystemExit(0)
        raise SystemExit(1)
    payload = raw + "".join("%s: %s\n" % item for item in fields.items()).encode("utf-8")
    if len(payload) > 1024 * 1024:
        raise SystemExit(1)
    temp_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IMODE(info.st_mode))
    view = memoryview(payload)
    while view:
        written = os.write(temp_fd, view)
        if written <= 0:
            raise RuntimeError("short stage write")
        view = view[written:]
    os.fsync(temp_fd)
    os.close(temp_fd)
    temp_fd = -1
    current = os.lstat(path)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise RuntimeError("semaphore changed during staged close")
    os.replace(temporary, path)
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if temp_fd >= 0:
        os.close(temp_fd)
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    os.close(fd)
PY
}

_record_close_prepared() {  # exact source snapshot before isolate-push; prints prepare digest
  local semaphore="$1" session_id="$2" worktree="$3" common_dir="$4"
  local source_base="$5" source_head="$6" source_status_sha="$7"
  local source_commits_json="$8" claims_json="$9" terminal_kind="${10}"
  local terminal_reference="${11}" terminal_sha="${12}"
  local source_origin="${13}" target_ref="${14}"
  local attempt_id snapshot_sha fields_json digest
  [ "$(_terminal_proof_snapshot_sha "$terminal_kind" "$terminal_reference" || true)" = "$terminal_sha" ] \
    || return 1
  attempt_id=$(python3 -c 'import uuid; print(uuid.uuid4())') || return 1
  snapshot_sha=$(_owned_semaphore_snapshot_sha "$semaphore") || return 1
  fields_json=$(python3 - "$attempt_id" "$session_id" "$worktree" "$common_dir" \
    "$source_base" "$source_head" "$source_status_sha" "$source_commits_json" \
    "$claims_json" "$terminal_kind" "$terminal_reference" "$terminal_sha" "$snapshot_sha" \
    "$source_origin" "$target_ref" <<'PY'
import hashlib
import json
import sys

(
    attempt, session, worktree, common, source_base, source_head, source_status,
    source_commits_json, claims_json, terminal_kind, terminal_reference,
    terminal_sha, semaphore_sha, source_origin, target_ref,
) = sys.argv[1:]
source_commits = json.loads(source_commits_json)
claims = json.loads(claims_json)
source_commits_digest = hashlib.sha256(
    json.dumps(source_commits, separators=(",", ":")).encode()
).hexdigest()
payload = {
    "version": "isolate-push/v2",
    "close_attempt_id": attempt,
    "session_id": session,
    "worktree": worktree,
    "common_dir": common,
    "origin": source_origin,
    "target_ref": target_ref,
    "source_base": source_base,
    "source_head": source_head,
    "source_commits": source_commits,
    "source_commits_digest": source_commits_digest,
    "source_status_sha256": source_status,
    "expected_commits": source_commits,
    "claimed_commits": claims,
    "terminal_kind": terminal_kind,
    "terminal_reference": terminal_reference,
    "terminal_sha256": terminal_sha,
    "semaphore_sha256": semaphore_sha,
}
digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
fields = {
    "close_delivery_version": "isolate-push/v2",
    "close_attempt_id": attempt,
    "close_delivery_session_id": session,
    "close_delivery_worktree": worktree,
    "close_delivery_common_dir": common,
    "close_delivery_origin": source_origin,
    "close_delivery_target_ref": target_ref,
    "close_delivery_source_base": source_base,
    "close_delivery_source_head": source_head,
    "close_delivery_source_commits": json.dumps(source_commits, separators=(",", ":")),
    "close_delivery_source_commits_digest": source_commits_digest,
    "close_delivery_source_status_sha256": source_status,
    "close_delivery_expected_commits": json.dumps(source_commits, separators=(",", ":")),
    "close_delivery_claimed_commits": json.dumps(claims, separators=(",", ":")),
    "close_delivery_terminal_kind": terminal_kind,
    "close_delivery_terminal_reference": terminal_reference,
    "close_delivery_terminal_sha256": terminal_sha,
    "close_delivery_semaphore_sha256": semaphore_sha,
    "close_delivery_prepare_digest": digest,
}
print(json.dumps(fields, separators=(",", ":")))
PY
  ) || return 1
  _append_close_fields_atomic "$semaphore" "$fields_json" || return 1
  [ "$(_terminal_proof_snapshot_sha "$terminal_kind" "$terminal_reference" || true)" = "$terminal_sha" ] \
    || return 1
  digest=$(_unique_record_field "$semaphore" close_delivery_prepare_digest || true)
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

_record_close_published() {  # <semaphore> <session> <prepare-digest> <remote-sha> <verified-json>
  local fields_json digest
  fields_json=$(python3 - "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'PY'
import hashlib
import json
import sys

session, prepare, remote, verified_json, source_head, source_status, terminal_sha = sys.argv[1:]
verified = json.loads(verified_json)
payload = {
    "proof": "isolate-push-exit0/v1",
    "session_id": session,
    "prepare_digest": prepare,
    "source_head": source_head,
    "source_status_sha256": source_status,
    "terminal_sha256": terminal_sha,
    "remote_main_sha": remote,
    "verified_commits": verified,
}
digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
print(json.dumps({
    "close_publish_proof": "isolate-push-exit0/v1",
    "close_publish_session_id": session,
    "close_publish_prepare_digest": prepare,
    "close_publish_source_head": source_head,
    "close_publish_source_status_sha256": source_status,
    "close_publish_terminal_sha256": terminal_sha,
    "close_publish_remote_main_sha": remote,
    "close_publish_verified_commits": json.dumps(verified, separators=(",", ":")),
    "close_publish_digest": digest,
}, separators=(",", ":")))
PY
  ) || return 1
  _append_close_fields_atomic "$1" "$fields_json" || return 1
  digest=$(_unique_record_field "$1" close_publish_digest || true)
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

_record_close_cleanup() {  # <semaphore> <session> <publish-digest>
  local fields_json
  fields_json=$(python3 - "$2" "$3" <<'PY'
import json
import sys
print(json.dumps({
    "close_cleanup_proof": "worktree-absent/v1",
    "close_cleanup_session_id": sys.argv[1],
    "close_cleanup_publish_digest": sys.argv[2],
}, separators=(",", ":")))
PY
  ) || return 1
  _append_close_fields_atomic "$1" "$fields_json"
}

_worktree_absent_and_unregistered() {  # <common-dir> <worktree>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import os
import subprocess
import sys

common, worktree = sys.argv[1:]
if os.path.lexists(worktree) or not os.path.isdir(common) or os.path.islink(common):
    raise SystemExit(1)
result = subprocess.run(
    ["git", "--git-dir=" + common, "worktree", "list", "--porcelain"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
    text=True,
)
if result.returncode != 0:
    raise SystemExit(1)
target = os.path.abspath(worktree)
for line in result.stdout.splitlines():
    if line.startswith("worktree ") and os.path.abspath(line[9:]) == target:
        raise SystemExit(1)
PY
}

_prepare_close_receipt() {  # <open semaphore> <result> <carry-over> [publish-digest] <terminal-sha>
  python3 - "$1" "$2" "$3" "${4:-}" "$5" <<'PY'
import fcntl
import os
import stat
import sys

path, result, carry_over, delivery_digest, terminal_sha = sys.argv[1:]
result = " ".join(result.replace("\x00", "").splitlines()) or "не указано"
carry_over = " ".join(carry_over.replace("\x00", "").splitlines()) or "нет"
expected = {
    "checklist_status": "closed",
    "checklist_result": result,
    "checklist_carry_over": carry_over,
    "checklist_publish_state": "clean",
    "checklist_terminal_sha256": terminal_sha,
}
if not terminal_sha or any(ch not in "0123456789abcdef" for ch in terminal_sha):
    raise SystemExit("terminal digest is missing or malformed")
if delivery_digest:
    expected["checklist_delivery_digest"] = delivery_digest
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    source_fd = os.open(path, flags)
except OSError as error:
    raise SystemExit("cannot open semaphore: %s" % error)
fcntl.flock(source_fd, fcntl.LOCK_EX)
info = os.fstat(source_fd)
current = os.lstat(path)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.geteuid()
    or info.st_nlink != 1
    or info.st_size <= 0
    or info.st_size > 1024 * 1024
):
    raise SystemExit("semaphore is not an owned regular file")
if stat.S_ISLNK(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
    raise SystemExit("semaphore pathname changed")
chunks = []
while True:
    chunk = os.read(source_fd, 65536)
    if not chunk:
        break
    chunks.append(chunk)
content = b"".join(chunks).decode("utf-8")
if len(content.encode("utf-8")) != info.st_size or "\x00" in content or not content.endswith("\n"):
    raise SystemExit("semaphore content is truncated or malformed")
lines = content.splitlines()
if delivery_digest:
    required = {
        "close_publish_digest": delivery_digest,
        "close_cleanup_proof": "worktree-absent/v1",
        "close_cleanup_publish_digest": delivery_digest,
    }
    for key, value in required.items():
        prefix = key + ": "
        found = [line[len(prefix):] for line in lines if line.startswith(prefix)]
        if found != [value]:
            raise SystemExit("prepared receipt is not bound to exact delivery/cleanup proof")
present = {}
for line in lines:
    for key in expected:
        prefix = key + ": "
        if line.startswith(prefix):
            present.setdefault(key, []).append(line[len(prefix):])
if present:
    if set(present) != set(expected) or any(present[key] != [expected[key]] for key in expected):
        raise SystemExit("existing checklist receipt is partial, duplicate, or mismatched")
    raise SystemExit(0)

payload = content
if payload and not payload.endswith("\n"):
    payload += "\n"
payload += "".join("%s: %s\n" % item for item in expected.items())
encoded = payload.encode("utf-8")
if len(encoded) > 1024 * 1024:
    raise SystemExit("prepared receipt exceeds size limit")
temporary = path + ".close-prepared.%d" % os.getpid()
temp_fd = -1
try:
    temp_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IMODE(info.st_mode))
    view = memoryview(encoded)
    while view:
        written = os.write(temp_fd, view)
        if written <= 0:
            raise RuntimeError("short write while preparing receipt")
        view = view[written:]
    os.fsync(temp_fd)
    os.close(temp_fd)
    temp_fd = -1
    current = os.lstat(path)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise RuntimeError("semaphore changed before receipt replace")
    os.replace(temporary, path)
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if temp_fd >= 0:
        os.close(temp_fd)
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    os.close(source_fd)
PY
}

_rename_open_to_closed() {  # <prepared open> <closed destination>
  python3 - "$1" "$2" <<'PY'
import fcntl
import os
import stat
import sys

source, destination = sys.argv[1:]
source_fd = -1
destination_fd = -1
directory_fd = -1
try:
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    fcntl.flock(source_fd, fcntl.LOCK_EX)
    info = os.fstat(source_fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink not in (1, 2)
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
    ):
        raise SystemExit(1)
    data = os.read(source_fd, info.st_size + 1)
    if len(data) != info.st_size or b"\0" in data or not data.endswith(b"\n"):
        raise SystemExit(1)
    text = data.decode("utf-8")
    expected = {
        "checklist_status": "closed",
        "checklist_publish_state": "clean",
    }
    for key, value in expected.items():
        prefix = key + ": "
        values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
        if values != [value]:
            raise SystemExit(1)
    terminal_values = [
        line[len("checklist_terminal_sha256: "):]
        for line in text.splitlines()
        if line.startswith("checklist_terminal_sha256: ")
    ]
    if (
        len(terminal_values) != 1
        or len(terminal_values[0]) not in (40, 64)
        or any(ch not in "0123456789abcdef" for ch in terminal_values[0])
    ):
        raise SystemExit(1)
    current = os.lstat(source)
    if stat.S_ISLNK(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)

    # link(2) is the portable macOS/Bash-era no-clobber primitive: unlike
    # rename(2), it fails atomically when an unrelated destination exists.
    # The two-link state is intentional crash recovery.  A retry may remove
    # `.open` only when both names still identify this exact prepared inode.
    if os.path.lexists(destination):
        destination_fd = os.open(
            destination,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        destination_info = os.fstat(destination_fd)
        destination_path_info = os.lstat(destination)
        if (
            stat.S_ISLNK(destination_path_info.st_mode)
            or not stat.S_ISREG(destination_info.st_mode)
            or destination_info.st_uid != os.geteuid()
            or (destination_info.st_dev, destination_info.st_ino) != (info.st_dev, info.st_ino)
            or (destination_path_info.st_dev, destination_path_info.st_ino) != (info.st_dev, info.st_ino)
            or info.st_nlink != 2
            or destination_info.st_nlink != 2
        ):
            raise SystemExit(1)
    else:
        if info.st_nlink != 1:
            raise SystemExit(1)
        os.link(source, destination, follow_symlinks=False)
        destination_fd = os.open(
            destination,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        destination_info = os.fstat(destination_fd)
        source_after_link = os.fstat(source_fd)
        destination_path_info = os.lstat(destination)
        if (
            stat.S_ISLNK(destination_path_info.st_mode)
            or (destination_info.st_dev, destination_info.st_ino) != (info.st_dev, info.st_ino)
            or (destination_path_info.st_dev, destination_path_info.st_ino) != (info.st_dev, info.st_ino)
            or source_after_link.st_nlink != 2
            or destination_info.st_nlink != 2
        ):
            raise SystemExit(1)

    directory_fd = os.open(os.path.dirname(source), os.O_RDONLY)
    # Make the exact closed receipt durable before removing the open name.
    os.fsync(directory_fd)
    if os.environ.get("IWE_SESSION_GUARD_FAULT_POINT") == "after-terminal-link":
        # Deliberately leave both names linked to the exact same durable
        # receipt.  The next close completes unlink after inode/content CAS.
        raise SystemExit(99)
    os.unlink(source)
    try:
        os.fsync(directory_fd)
    except OSError as error:
        # The durable destination is already the sole authoritative name.
        # Returning failure now would falsely promise the caller that `.open`
        # still exists.  Surface the post-commit durability warning instead.
        print("warning: closed receipt committed, but final directory fsync failed: %s" % error, file=sys.stderr)
finally:
    if directory_fd >= 0:
        os.close(directory_fd)
    if destination_fd >= 0:
        os.close(destination_fd)
    if source_fd >= 0:
        os.close(source_fd)
PY
}

_prepared_source_snapshot_matches() {  # <semaphore> <worktree>
  local semaphore="$1" worktree="$2" expected_head expected_common expected_status
  local expected_base expected_commits expected_claims terminal_kind terminal_ref terminal_sha
  local expected_origin expected_target actual_common actual_status actual_commits actual_claims actual_terminal actual_origin
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  expected_head=$(_unique_record_field "$semaphore" close_delivery_source_head) || return 1
  expected_common=$(_unique_record_field "$semaphore" close_delivery_common_dir) || return 1
  expected_status=$(_unique_record_field "$semaphore" close_delivery_source_status_sha256) || return 1
  expected_base=$(_unique_record_field "$semaphore" close_delivery_source_base) || return 1
  expected_commits=$(_unique_record_field "$semaphore" close_delivery_source_commits) || return 1
  expected_claims=$(_unique_record_field "$semaphore" close_delivery_claimed_commits) || return 1
  terminal_kind=$(_unique_record_field "$semaphore" close_delivery_terminal_kind) || return 1
  terminal_ref=$(_unique_record_field "$semaphore" close_delivery_terminal_reference) || return 1
  terminal_sha=$(_unique_record_field "$semaphore" close_delivery_terminal_sha256) || return 1
  expected_origin=$(_unique_record_field "$semaphore" close_delivery_origin) || return 1
  expected_target=$(_unique_record_field "$semaphore" close_delivery_target_ref) || return 1

  [ "$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" = "$expected_head" ] \
    || return 1
  actual_common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$actual_common" in /*) ;; *) actual_common="$worktree/$actual_common" ;; esac
  actual_common=$(cd "$actual_common" 2>/dev/null && pwd -P) || return 1
  [ "$actual_common" = "$expected_common" ] || return 1
  actual_origin=$(git -C "$worktree" remote get-url origin 2>/dev/null) || return 1
  actual_origin=$(normalize_remote_url "$actual_origin")
  [ "$actual_origin" = "$expected_origin" ] && [ "$expected_target" = "refs/heads/main" ] || return 1
  actual_status=$(_worktree_clean_status_sha "$worktree" || true)
  [ -n "$actual_status" ] && [ "$actual_status" = "$expected_status" ] || return 1
  actual_commits=$(_isolated_source_commits_json "$worktree" "$expected_base" "$expected_head" || true)
  [ "$actual_commits" = "$expected_commits" ] || return 1
  actual_claims=$(_session_commit_claims_json "$semaphore" || true)
  [ "$actual_claims" = "$expected_claims" ] || return 1
  actual_terminal=$(_terminal_proof_snapshot_sha "$terminal_kind" "$terminal_ref" || true)
  [ -n "$actual_terminal" ] && [ "$actual_terminal" = "$terminal_sha" ] || return 1
}

_publish_prepared_source() {  # <semaphore> <worktree> <isolate-push-script>
  local semaphore="$1" worktree="$2" isolate_push_script="$3"
  local commits_json commit_count commit push_rc=0
  commits_json=$(_unique_record_field "$semaphore" close_delivery_source_commits) || return 1
  commit_count=$(python3 - "$commits_json" <<'PY' 2>/dev/null
import json
import sys
value = json.loads(sys.argv[1])
if not isinstance(value, list):
    raise SystemExit(1)
print(len(value))
PY
  ) || return 1
  if [ "$commit_count" -eq 0 ]; then
    # An empty prepared set is already-delivered evidence, not permission to
    # recalculate a moving range.  Calling ordinary isolate-push here would
    # publish a commit created after PREPARED before the post-check noticed.
    timeout 10 git -C "$worktree" fetch --quiet origin \
      '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null || return 1
    commit=$(_unique_record_field "$semaphore" close_delivery_source_head) || return 1
    git -C "$worktree" merge-base --is-ancestor "$commit" refs/remotes/origin/main 2>/dev/null
    return $?
  fi
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    push_rc=0
    timeout 300 "$isolate_push_script" "$worktree" main --exact-commit "$commit" || push_rc=$?
    [ "$push_rc" -eq 0 ] || return "$push_rc"
  done < <(python3 - "$commits_json" <<'PY'
import json
import sys
for item in json.loads(sys.argv[1]):
    print(item)
PY
  )
}

_prepared_source_set_has_publish_proof() {  # <semaphore> <worktree>, fresh origin/main required
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json
import os
import subprocess
import sys

semaphore, worktree = sys.argv[1:]

def field(key):
    prefix = (key + ": ").encode()
    with open(semaphore, "rb") as source:
        values = [line[len(prefix):].rstrip(b"\n") for line in source if line.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise SystemExit(1)
    return values[0].decode("utf-8")

def git(*args):
    result = subprocess.run(
        ["git", "-C", worktree, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(1)
    return result.stdout

commits = json.loads(field("close_delivery_source_commits"))
source_base = field("close_delivery_source_base")
source_head = field("close_delivery_source_head")
remote_head = git("rev-parse", "--verify", "refs/remotes/origin/main^{commit}").strip().decode()
if not commits:
    result = subprocess.run(
        ["git", "-C", worktree, "merge-base", "--is-ancestor", source_head, remote_head],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    raise SystemExit(0 if result.returncode == 0 else 1)
if all(
    subprocess.run(
        ["git", "-C", worktree, "merge-base", "--is-ancestor", commit, remote_head],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0
    for commit in commits
):
    raise SystemExit(0)

# Cherry-pick/retry may rewrite OIDs.  In that case bind delivery to the
# final prepared tree over the union of every path touched by the immutable
# sequence.  Comparing mode+object handles deletes, symlinks and executable
# bits; a metadata-only sequence has no content proof and therefore fails.
paths = set()
for commit in commits:
    parent = git("rev-parse", "--verify", commit + "^").strip().decode()
    if not parent:
        raise SystemExit(1)
    changed = git("diff", "--name-only", "-z", "--no-renames", parent, commit)
    paths.update(item for item in changed.split(b"\0") if item)
if not paths:
    raise SystemExit(1)

def tree_entry(revision, raw_path):
    result = subprocess.run(
        ["git", "--literal-pathspecs", "-C", worktree, "ls-tree", "-z", revision, "--", os.fsdecode(raw_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(1)
    return result.stdout

for raw_path in sorted(paths):
    if tree_entry(source_head, raw_path) != tree_entry(remote_head, raw_path):
        raise SystemExit(1)
PY
}

_close_delivery_and_transition() {
  local governance_repo sessions_repo isolated_worktree isolate_push_script
  local sem_basename close_receipt delivery_state publish_digest="" prepare_digest=""
  local source_base source_head source_status source_commits source_origin actual_origin target_ref common_dir remote_main_sha
  local terminal_kind terminal_ref terminal_sha claims_json verified_json push_status=0
  [ -f "$SEM_FILE" ] && [ ! -L "$SEM_FILE" ] \
    || fail "close: точный .open semaphore исчез или стал небезопасным; terminal transition запрещён" 7
  sem_basename=$(basename -- "$SEM_FILE")
  [ "$sem_basename" = "$AGENT-$SESSION_ID.open" ] \
    || fail "close: имя semaphore не связано точно с agent/session_id" 7
  close_receipt="$SEM_FILE.closed"
  isolated_worktree=$(_unique_record_field "$SEM_FILE" isolated_worktree || true)

  # A crash after link(2) but before unlink(2) leaves two names for the exact
  # prepared receipt.  Finish only that inode-bound transition before trying
  # to resolve a worktree that may already have been removed.  An unrelated
  # or malformed destination fails closed and never gets overwritten.
  if [ -e "$close_receipt" ] || [ -L "$close_receipt" ]; then
    delivery_state=$(_close_delivery_state "$SEM_FILE" "$SESSION_ID" || true)
    if [ -n "$isolated_worktree" ]; then
      [ "$delivery_state" = "cleaned" ] \
        || fail "close: .closed link существует без exact delivery+cleanup receipt; не перезаписываю" 7
    else
      [ "$delivery_state" = "none" ] \
        || fail "close: non-isolated .closed link содержит неожиданный delivery journal" 7
    fi
    _rename_open_to_closed "$SEM_FILE" "$close_receipt" \
      || fail "close: interrupted terminal transition не связан с exact receipt; .open сохранён" 7
    return 0
  fi

  if delivery_state=$(_close_delivery_state "$SEM_FILE" "$SESSION_ID"); then
    :
  else
    fail "close: staged delivery receipt отсутствует, частичен или повреждён" 7
  fi
  if [ "${MACHINE_CLOSE_MODE:-0}" != "1" ]; then
    sessions_repo=$(git -C "$ORZ_SESSIONS_DIR" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$sessions_repo" ] \
      || fail "close: sessions checkout не доказан; clean/terminal transition запрещён" 7
    if [ "$sessions_repo" != "$isolated_worktree" ]; then
      _repo_head_has_publish_proof "$sessions_repo" "sessions checkout" \
        || fail "close: ORZ/session delivery не подтверждена; .open/lease/pointer сохранены" 7
    fi
  fi

  # Resume begins from the durable semaphore receipt, not from a worktree that
  # may already be gone.  The published stage was written only after every
  # terminal/scope/remote decision succeeded under this same persistent lock.
  if [ "$delivery_state" != "none" ]; then
    [ -n "$isolated_worktree" ] \
      || fail "close: staged isolate receipt найден у non-isolated semaphore" 7
    [ "$(_unique_record_field "$SEM_FILE" close_delivery_worktree || true)" = "$isolated_worktree" ] \
      || fail "close: staged worktree identity не совпадает с semaphore" 7
    common_dir=$(_unique_record_field "$SEM_FILE" close_delivery_common_dir || true)
    source_head=$(_unique_record_field "$SEM_FILE" close_delivery_source_head || true)
    terminal_sha=$(_unique_record_field "$SEM_FILE" close_delivery_terminal_sha256 || true)
    prepare_digest=$(_unique_record_field "$SEM_FILE" close_delivery_prepare_digest || true)
    CLOSING_WORKTREE="$isolated_worktree"

    if [ "$delivery_state" = "prepared" ]; then
      _prepared_source_snapshot_matches "$SEM_FILE" "$CLOSING_WORKTREE" \
        || fail "close retry: PREPARED source/head/scope/terminal snapshot изменился; push запрещён" 7
      isolate_push_script="$IWE_ROOT/$GOV_REPO/scripts/isolate-push.sh"
      [ -x "$isolate_push_script" ] \
        || fail "close retry: isolate-push.sh недоступен; PREPARED сохранён" 7
      push_status=0
      _publish_prepared_source "$SEM_FILE" "$CLOSING_WORKTREE" "$isolate_push_script" \
        || push_status=$?
      [ "$push_status" -eq 0 ] \
        || fail "close retry: exact prepared commit set не опубликован (код $push_status); PREPARED/worktree сохранены" 7
      _prepared_source_snapshot_matches "$SEM_FILE" "$CLOSING_WORKTREE" \
        || fail "close: source/head/scope/terminal изменился во время isolate-push; publish receipt не пишу" 7
      timeout 10 git -C "$CLOSING_WORKTREE" fetch --quiet origin \
        '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null \
        || fail "close: isolate-push завершился, но fresh origin/main proof не получен" 7
      remote_main_sha=$(git -C "$CLOSING_WORKTREE" rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null) \
        || fail "close: remote main SHA после isolate-push не читается" 7
      _prepared_source_set_has_publish_proof "$SEM_FILE" "$CLOSING_WORKTREE" \
        || fail "close: не каждый PREPARED source commit доказан fresh origin/main exact OID или итоговым tree proof" 7
      _claimed_commits_have_publish_proof "$SEM_FILE" \
        || fail "close: additional note-commit claim не имеет publish proof" 7
      verified_json=$(_unique_record_field "$SEM_FILE" close_delivery_source_commits || true)
      source_status=$(_unique_record_field "$SEM_FILE" close_delivery_source_status_sha256 || true)
      terminal_sha=$(_unique_record_field "$SEM_FILE" close_delivery_terminal_sha256 || true)
      publish_digest=$(_record_close_published "$SEM_FILE" "$SESSION_ID" "$prepare_digest" \
        "$remote_main_sha" "$verified_json" "$source_head" "$source_status" "$terminal_sha") \
        || fail "close: publish proof не записан durable; PREPARED/worktree сохранены" 7
      [ "$(_close_delivery_state "$SEM_FILE" "$SESSION_ID" || true)" = "published" ] \
        || fail "close: записанный PUBLISHED receipt не прошёл self-check" 7
      delivery_state="published"
      [ "${IWE_SESSION_GUARD_FAULT_POINT:-}" != "after-published" ] \
        || fail "close test fault: after-published" 99
    fi

    if [ "$delivery_state" = "published" ]; then
      publish_digest=$(_unique_record_field "$SEM_FILE" close_publish_digest || true)
      [ -n "$publish_digest" ] || fail "close retry: publish digest отсутствует" 7
      if [ -d "$CLOSING_WORKTREE" ] && [ ! -L "$CLOSING_WORKTREE" ]; then
        _prepared_source_snapshot_matches "$SEM_FILE" "$CLOSING_WORKTREE" \
          || fail "close retry: worktree/source/terminal изменился после PUBLISHED; не удаляю" 7
        timeout 60 git -C "$CLOSING_WORKTREE" worktree remove "$CLOSING_WORKTREE" 2>/dev/null \
          || fail "close retry: published worktree не удалён; .open сохранён" 7
      fi
      _worktree_absent_and_unregistered "$common_dir" "$CLOSING_WORKTREE" \
        || fail "close retry: worktree отсутствует не полностью или всё ещё зарегистрирован; .open сохранён" 7
      [ "${IWE_SESSION_GUARD_FAULT_POINT:-}" != "after-worktree-remove" ] \
        || fail "close test fault: after-worktree-remove" 99
      _record_close_cleanup "$SEM_FILE" "$SESSION_ID" "$publish_digest" \
        || fail "close retry: cleanup proof не записан; published stage сохранён" 7
      [ "$(_close_delivery_state "$SEM_FILE" "$SESSION_ID" || true)" = "cleaned" ] \
        || fail "close retry: CLEANED receipt не прошёл self-check" 7
      delivery_state="cleaned"
    fi
    publish_digest=$(_unique_record_field "$SEM_FILE" close_publish_digest || true)
    _worktree_absent_and_unregistered "$common_dir" "$CLOSING_WORKTREE" \
      || fail "close: cleanup receipt не подтверждается текущим git registry" 7
    [ "${IWE_SESSION_GUARD_FAULT_POINT:-}" != "after-cleanup-stage" ] \
      || fail "close test fault: after-cleanup-stage" 99
    _prepare_close_receipt "$SEM_FILE" "${RESULT_ARG:-не указано}" "${DEFER_ARG:-нет}" "$publish_digest" "$terminal_sha" \
      || fail "close: staged receipt подтверждён, но checklist не подготовлен; retry безопасен" 7
    [ "${IWE_SESSION_GUARD_FAULT_POINT:-}" != "after-checklist-prepare" ] \
      || fail "close test fault: after-checklist-prepare" 99
    _rename_open_to_closed "$SEM_FILE" "$close_receipt" \
      || fail "close: terminal link/unlink не прошёл; staged .open сохранён для retry" 7
    return 0
  fi

  governance_repo=$(semaphore_governance_worktree "$SEM_FILE" || true)
  [ -n "$governance_repo" ] \
    || fail "close: governance checkout не доказан; clean/terminal transition запрещён" 7

  # A non-isolated governance checkout and the independent sessions repo must
  # already have their exact HEAD reachable from origin/main.  Missing origin
  # or a missing tracking ref is absence of proof, never implicit `clean`.
  if [ -z "$isolated_worktree" ]; then
    _repo_head_has_publish_proof "$governance_repo" "governance checkout" \
      || fail "close: governance delivery не подтверждена; .open/lease/pointer сохранены" 7
  fi
  if [ -z "$isolated_worktree" ]; then
    _claimed_commits_have_publish_proof "$SEM_FILE" \
      || fail "close: один из session-owned commits не имеет точного publish proof; .open сохранён" 7
  fi

  if [ -n "$isolated_worktree" ]; then
    CLOSING_WORKTREE="$isolated_worktree"
    [ "$governance_repo" = "$CLOSING_WORKTREE" ] \
      || fail "close: isolated_worktree не совпадает с governance checkout; ничего не публикую" 7
    isolate_push_script="$IWE_ROOT/$GOV_REPO/scripts/isolate-push.sh"
    [ -x "$isolate_push_script" ] \
      || fail "close: isolate-push.sh недоступен; .open и worktree сохранены" 7
    source_origin=$(git -C "$CLOSING_WORKTREE" remote get-url origin 2>/dev/null) \
      || fail "close: source origin отсутствует; PREPARED не пишу" 7
    source_origin=$(normalize_remote_url "$source_origin")
    [ -n "$source_origin" ] || fail "close: normalized source origin пуст" 7
    timeout 10 git -C "$CLOSING_WORKTREE" fetch --quiet origin \
      '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null \
      || fail "close: PREPARED требует fresh origin/main; .open/worktree сохранены" 7
    source_head=$(git -C "$CLOSING_WORKTREE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
      || fail "close: source HEAD isolated worktree не читается" 7
    source_base=$(git -C "$CLOSING_WORKTREE" merge-base "$source_head" refs/remotes/origin/main 2>/dev/null) \
      || fail "close: source base для immutable commit set не вычислен" 7
    common_dir=$(git -C "$CLOSING_WORKTREE" rev-parse --git-common-dir 2>/dev/null) \
      || fail "close: git common-dir isolated worktree не читается" 7
    case "$common_dir" in
      /*) ;;
      *) common_dir="$CLOSING_WORKTREE/$common_dir" ;;
    esac
    common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) \
      || fail "close: git common-dir isolated worktree не канонизируется" 7
    actual_origin=$(git -C "$CLOSING_WORKTREE" remote get-url origin 2>/dev/null) \
      || fail "close: source origin исчез до PREPARED" 7
    actual_origin=$(normalize_remote_url "$actual_origin")
    [ "$actual_origin" = "$source_origin" ] \
      || fail "close: source origin изменился во время PREPARED snapshot" 7
    target_ref="refs/heads/main"
    source_status=$(_worktree_clean_status_sha "$CLOSING_WORKTREE" || true)
    [ -n "$source_status" ] \
      || fail "close: isolated worktree не полностью clean (включая ignored/untracked); PREPARED не пишу" 7
    source_commits=$(_isolated_source_commits_json "$CLOSING_WORKTREE" "$source_base" "$source_head" || true)
    [ -n "$source_commits" ] \
      || fail "close: полный ordered source commit set не сериализуется" 7
    claims_json=$(_session_commit_claims_json "$SEM_FILE") \
      || fail "close: полный expected commit set не сериализуется" 7
    [ -n "${TERMINAL_PROOF_KIND:-}" ] && [ -n "${TERMINAL_PROOF_REFERENCE:-}" ] \
      && [ -n "${TERMINAL_PROOF_SHA256:-}" ] \
      || fail "close: immutable terminal proof не зафиксирован до PREPARED" 7
    prepare_digest=$(_record_close_prepared "$SEM_FILE" "$SESSION_ID" "$CLOSING_WORKTREE" \
      "$common_dir" "$source_base" "$source_head" "$source_status" "$source_commits" \
      "$claims_json" "$TERMINAL_PROOF_KIND" "$TERMINAL_PROOF_REFERENCE" "$TERMINAL_PROOF_SHA256" \
      "$source_origin" "$target_ref") \
      || fail "close: PREPARED receipt не записан durable; push не запускался" 7
    [ "$(_close_delivery_state "$SEM_FILE" "$SESSION_ID" || true)" = "prepared" ] \
      || fail "close: PREPARED receipt не прошёл self-check; push не запускался" 7
    [ "${IWE_SESSION_GUARD_FAULT_POINT:-}" != "after-prepared" ] \
      || fail "close test fault: after-prepared" 99
    _close_delivery_and_transition
    return 0
  fi

  [ -n "${TERMINAL_PROOF_SHA256:-}" ] \
    || fail "close: immutable terminal proof отсутствует у non-isolated close" 7
  _prepare_close_receipt "$SEM_FILE" "${RESULT_ARG:-не указано}" "${DEFER_ARG:-нет}" "" "$TERMINAL_PROOF_SHA256" \
    || fail "close: не удалось атомарно подготовить identity-bound receipt; .open сохранён" 7
  [ "${IWE_SESSION_GUARD_FAULT_POINT:-}" != "after-checklist-prepare" ] \
    || fail "close test fault: after-checklist-prepare" 99
  _rename_open_to_closed "$SEM_FILE" "$close_receipt" \
    || fail "close: terminal rename .open→.closed не прошёл; .open сохранён" 7
}

# --- NOTE-SCHEDULED-DRAIN (producer attestation under session authority) ---
if [ "$CMD" = "note-scheduled-drain" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] \
    || fail "note-scheduled-drain не принимает positional arguments" 1
  _owner_pid_is_live_ancestor "$OWNER_PID" \
    || fail "note-scheduled-drain: --owner-pid не является живым предком attester-процесса" 1
  SEM_FILE=$(resolve_semaphore_by_session_id "$AGENT" "$SESSION_ID_ARG" "" "") \
    || fail "note-scheduled-drain: exact session_id не резолвится" 1
  NOTE_DRAIN_WAIT="${IWE_SESSION_TRANSITION_WAIT_SEC:-10}"
  [[ "$NOTE_DRAIN_WAIT" =~ ^[0-9]+$ ]] && [ "$NOTE_DRAIN_WAIT" -le 30 ] \
    || fail "note-scheduled-drain: lock wait должен быть целым 0..30 секунд" 1
  IWE_SESSION_TRANSITION_WAIT_SEC="$NOTE_DRAIN_WAIT"
  acquire_session_transition_lock "$SEM_FILE"
  LOCKED_DRAIN_SESSION_ID=$(_locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" || true)
  [ "$LOCKED_DRAIN_SESSION_ID" = "$SESSION_ID_ARG" ] \
    || fail "note-scheduled-drain: semaphore изменился после resolve" 1
  [ "$(_close_delivery_state "$SEM_FILE" "$SESSION_ID_ARG" || true)" = "none" ] \
    || fail "note-scheduled-drain: close transition уже подготовлен; proof mutation запрещена" 1
  _append_scheduled_drain_proof "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" \
    "$OWNER_PID" "$SCHEDULED_RUN_ID" "$(now_iso)" \
    || fail "note-scheduled-drain: proof не записан или post-fsync validation не прошла" 1
  release_session_transition_lock \
    || fail "note-scheduled-drain: proof записан, но transition lock не освободился" 1
  echo "Scheduled drain proof recorded: $AGENT/$SESSION_ID_ARG"
  exit 0
fi

# --- HEARTBEAT (exact no-create mutator under session authority) ---
if [ "$CMD" = "heartbeat" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] \
    || fail "heartbeat не принимает positional arguments" 1
  _owner_pid_is_live_ancestor "$OWNER_PID" \
    || fail "heartbeat: --owner-pid не является живым предком guard-процесса" 1
  SEM_FILE=$(resolve_semaphore_by_session_id "$AGENT" "$SESSION_ID_ARG" "" "") \
    || fail "heartbeat: exact session_id не резолвится" 1
  HEARTBEAT_WAIT="${IWE_SESSION_TRANSITION_WAIT_SEC:-10}"
  [[ "$HEARTBEAT_WAIT" =~ ^[0-9]+$ ]] && [ "$HEARTBEAT_WAIT" -le 30 ] \
    || fail "heartbeat: lock wait должен быть целым 0..30 секунд" 1
  IWE_SESSION_TRANSITION_WAIT_SEC="$HEARTBEAT_WAIT"
  acquire_session_transition_lock "$SEM_FILE"
  LOCKED_HEARTBEAT_SESSION_ID=$(_locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" || true)
  [ "$LOCKED_HEARTBEAT_SESSION_ID" = "$SESSION_ID_ARG" ] \
    || fail "heartbeat: semaphore изменился после resolve" 1
  [ "$(_close_delivery_state "$SEM_FILE" "$SESSION_ID_ARG" || true)" = "none" ] \
    || fail "heartbeat: close transition уже подготовлен" 1
  _append_heartbeat_atomic "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" "$OWNER_PID" "$(now_iso)" \
    || fail "heartbeat: atomic write/fsync/post-validation не прошли" 1
  release_session_transition_lock \
    || fail "heartbeat: запись завершена, но transition lock не освободился" 1
  echo "Heartbeat recorded: $AGENT/$SESSION_ID_ARG"
  exit 0
fi

# --- MACHINE-CLOSE (narrow publish-only terminal path) ---
if [ "$CMD" = "machine-close" ]; then
  SEM_FILE=$(resolve_semaphore_by_session_id "$AGENT" "$SESSION_ID_ARG" "" "") \
    || fail "machine-close: exact session_id не резолвится" 3
  acquire_scheduled_admission_lock
  acquire_session_transition_lock "$SEM_FILE"
  LOCKED_MACHINE_SESSION=$(_locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" 1 || true)
  [ "$LOCKED_MACHINE_SESSION" = "$SESSION_ID_ARG" ] \
    || fail "machine-close: semaphore identity изменилась после lock" 7
  MACHINE_IDENTITY=$(_machine_close_identity_lines "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" || true)
  [ "$(printf '%s\n' "$MACHINE_IDENTITY" | wc -l | tr -d ' ')" = "4" ] \
    || fail "machine-close: требуется exact machine-publish-only semaphore schema" 7
  MACHINE_OWNER_PID=$(printf '%s\n' "$MACHINE_IDENTITY" | sed -n '1p')
  WP=$(printf '%s\n' "$MACHINE_IDENTITY" | sed -n '2p')
  SLUG=$(printf '%s\n' "$MACHINE_IDENTITY" | sed -n '3p')
  MACHINE_WORKTREE=$(printf '%s\n' "$MACHINE_IDENTITY" | sed -n '4p')
  if MACHINE_STATE=$(_close_delivery_state "$SEM_FILE" "$SESSION_ID_ARG"); then
    :
  else
    fail "machine-close: staged delivery receipt частичен или повреждён" 7
  fi
  if [ "$MACHINE_STATE" = "none" ]; then
    _owner_pid_is_live_ancestor "$MACHINE_OWNER_PID" \
      || fail "machine-close: initial transition требует живой записанный owner PID как ancestor" 7
    [ -d "$MACHINE_WORKTREE" ] && [ ! -L "$MACHINE_WORKTREE" ] \
      || fail "machine-close: исходный isolated worktree уже отсутствует/небезопасен; initial close запрещён" 7
    [ "$(git -C "$MACHINE_WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)" = "$MACHINE_WORKTREE" ] \
      || fail "machine-close: isolated worktree не является exact git checkout" 7
  fi
  SESSION_ID="$SESSION_ID_ARG"
  ORZ_SESSIONS_DIR="$ORZ_DIR"
  RESULT_ARG="machine-published"
  DEFER_ARG="нет"
  TERMINAL_PROOF_KIND="sentinel"
  TERMINAL_PROOF_REFERENCE="declared-machine-publish-only:$SLUG"
  TERMINAL_PROOF_SHA256=$(_terminal_proof_snapshot_sha "$TERMINAL_PROOF_KIND" "$TERMINAL_PROOF_REFERENCE" || true)
  [ -n "$TERMINAL_PROOF_SHA256" ] \
    || fail "machine-close: immutable machine terminal sentinel не сформирован" 7
  MACHINE_CLOSE_MODE=1
  _close_delivery_and_transition
  release_session_transition_lock \
    || fail "machine-close: terminal transition завершён, но exact lock не освободился" 7
  _cleanup_closed_session_projections "$SEM_FILE" "$AGENT" "$SESSION_ID" \
    || echo "⚠️  machine-close: terminal receipt создан, но projection CAS не завершён" >&2
  if _agent_has_other_open_session "$AGENT"; then
    MACHINE_REPORT_IDLE=0
  else
    MACHINE_REPORT_IDLE=1
  fi
  release_scheduled_admission_lock \
    || fail "machine-close: terminal transition завершён, но admission lock не освободился" 7
  if [ "$MACHINE_REPORT_IDLE" -eq 1 ] && [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality unassigned \
      "$AGENT" idle "" "" 2>/dev/null || true
  fi
  echo "Machine CLOSE: $WP/$SLUG опубликован и закрыт ✅"
  exit 0
fi

# --- CLOSE ---
if [ "$CMD" = "close" ]; then
  if [ -n "$HOUSEKEEPING" ]; then
    [[ "$HOUSEKEEPING" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] \
      || fail "close --housekeeping: reason должен быть безопасным токеном длиной 1..128" 1
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    acquire_scheduled_admission_lock
    acquire_session_transition_lock "$HK_FILE"
    [ -e "$HK_FILE" ] && [ ! -L "$HK_FILE" ] \
      || fail "close --housekeeping: нет безопасной active session '${HOUSEKEEPING}' для $AGENT" 3
    HK_LOCKED_ID=$(_locked_open_identity "$HK_FILE" "$AGENT" "" 1 || true)
    [ -n "$HK_LOCKED_ID" ] \
      || fail "close --housekeeping: identity изменилась после lock; mutation запрещена" 1
    HK_SNAPSHOT=$(_owned_semaphore_snapshot_sha "$HK_FILE" 1 || true)
    [ -n "$HK_SNAPSHOT" ] \
      || fail "close --housekeeping: exact immutable snapshot не получен" 1
    _rename_owned_semaphore_cas "$HK_FILE" "$HK_FILE.closed" "$HK_SNAPSHOT" \
      || fail "close --housekeeping: no-clobber terminal transition не прошёл; open сохранён" 1
    _cleanup_closed_session_projections "$HK_FILE" "$AGENT" "$HK_LOCKED_ID" "$HOUSEKEEPING" \
      || echo "⚠️  close --housekeeping: terminal receipt создан, но lease projection не прошла identity CAS" >&2
    release_session_transition_lock \
      || fail "close --housekeeping: terminal transition завершён, но session lock не освободился" 1
    release_scheduled_admission_lock \
      || fail "close --housekeeping: terminal transition завершён, но admission lock не освободился" 1
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
  acquire_session_transition_lock "$SEM_FILE"
  LOCKED_SESSION_ID=$(_locked_open_identity "$SEM_FILE" "$AGENT" "${SESSION_ID_ARG:-}" 1 || true)
  [ -n "$LOCKED_SESSION_ID" ] \
    || fail "close: semaphore изменился после resolve или identity неоднозначна; mutation запрещена" 7
  if CLOSE_RESUME_STATE=$(_close_delivery_state "$SEM_FILE" "$LOCKED_SESSION_ID"); then
    :
  else
    fail "close: staged delivery state частичен/повреждён; mutation запрещена" 7
  fi
  WP_FROM_SEM=$(grep "^wp: " "$SEM_FILE" | cut -d' ' -f2- || true)
  WP="${WP:-$WP_FROM_SEM}"
  SLUG_FROM_SEM=$(grep "^slug: " "$SEM_FILE" | cut -d' ' -f2- || true)
  SLUG="${SLUG:-$SLUG_FROM_SEM}"
  TASK_FROM_SEM=$(grep "^task: " "$SEM_FILE" | cut -d' ' -f2- || true)
  TASK="${TASK:-$TASK_FROM_SEM}"
  SESSION_ID="$LOCKED_SESSION_ID"
  PERSONALITY_FROM_SEM=$(grep "^personality: " "$SEM_FILE" | cut -d' ' -f2- || true)
  PERSONALITY_FROM_SEM="${PERSONALITY_FROM_SEM:-unassigned}"

  ORZ_BASENAME=$(grep "^orz_file: " "$SEM_FILE" | cut -d' ' -f2- || true)
  # Read back the directory `open` actually resolved via gov_repo_dir() (found
  # in code review 2026-08-12, same peer-session as the open-side fix): re-
  # deriving gov_repo_dir() here would resolve against THIS invocation's cwd,
  # which can differ from open's (a separate process, e.g. process-runner.py's
  # session-guard-release.sh handler) and silently point at the wrong
  # worktree. Semaphores written before this fix have no such field --
  # canonical $ORZ_DIR is the correct fallback for them, since that's where
  # open put the file at the time. Resolved BEFORE the orz_file fallback below
  # (WP-484 Ф149, peer-session code review) -- the fallback needs it to probe
  # for an existing daily-scheme file, and `set -u` makes an out-of-order read
  # here an unbound-variable crash, not a silent empty string.
  ORZ_SESSIONS_DIR=$(grep "^orz_sessions_dir: " "$SEM_FILE" | cut -d' ' -f2- || true)
  ORZ_SESSIONS_DIR="${ORZ_SESSIONS_DIR:-$ORZ_DIR}"
  if [ -z "$ORZ_BASENAME" ]; then
    # Fallback для старых семафоров без поля orz_file (открытых до появления
    # этого поля в коде). WP-484 Ф149 (peer-session 2026-09-02): после
    # переезда сессий на подпапку-на-сессию (WP-526 Ф2) реальный файл может
    # лежать по новой по-дневной схеме -- пробуем её первой, с фоллбэком на
    # старую плоскую. Проверяем оба возможных каталога (snapshot и
    # канонический): если сессия закрывается после того, как её worktree уже
    # убран, snapshot-каталог может не совпадать с тем, где реально лежит
    # daily-файл.
    OPENED_DATE=$(grep "^opened_at: " "$SEM_FILE" | cut -d' ' -f2- | cut -dT -f1 || true)
    OPENED_DATE="${OPENED_DATE:-$(now_date)}"
    if [[ "$OPENED_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      DAILY_CANDIDATE="${OPENED_DATE:0:7}/${OPENED_DATE:8:2}/${SLUG:-$WP}/report.md"
      if [ -f "$ORZ_SESSIONS_DIR/$DAILY_CANDIDATE" ] || [ -f "$ORZ_DIR/$DAILY_CANDIDATE" ]; then
        ORZ_BASENAME="$DAILY_CANDIDATE"
      fi
    fi
    if [ -z "$ORZ_BASENAME" ]; then
      ORZ_BASENAME="${OPENED_DATE:0:7}/${OPENED_DATE}-${SLUG:-$WP}.md"
    fi
  fi
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

  DEFERRED_NO_REFLECTION_EVENT=""
  SLUG_MARKER_TO_REMOVE=""
  POST_CLOSE_CANCEL_MODE=""
  POST_CLOSE_EXCLUDE_RUN_ID=""
  POST_CLOSE_FORCED_RUN_ID=""
  if [ "$CLOSE_RESUME_STATE" = "none" ]; then
  SCOPE_DIRTY=$(session_scope_dirty_paths "$SEM_FILE")
  if [ -n "$SCOPE_DIRTY" ]; then
    echo "Session CLOSE: в зарегистрированной области остались незакоммиченные файлы:" >&2
    printf '%s\n' "$SCOPE_DIRTY" >&2
    fail "Сначала зафиксируй и отправь перечисленные файлы. Семафор остаётся активным." 7
  fi

  # Quick Close — не текстовая декларация: именно терминальная карточка раннера
  # доказывает, что эта сессия прошла обязательный процесс. Сопоставление по slug
  # не даёт чужой параллельной карточке закрыть текущую сессию. Для isolate-сессии
  # карточка создаётся в том же worktree, что и код (isolated_worktree в
  # семафоре), не обязательно рядом с ORZ: канонический checkout не обязан
  # содержать её untracked-копию.
  #
  # dirname($ORZ_SESSIONS_DIR) here used to BE the isolated worktree, back when
  # an isolated session's ORZ lived at "$ISOLATED_WORKTREE_PATH/sessions/...".
  # WP-526 Ф2 moved ORZ content out to the separate MC-sessions repo, so
  # $ORZ_SESSIONS_DIR is MC-sessions itself now and its dirname is just
  # $IWE_ROOT — never the actual isolated worktree — for every isolated
  # session, regardless of which repo the code changes landed in. Same root
  # cause session_scope_dirty_paths() already fixed above (WP-526 Ф2 comment,
  # "use it directly... no dirname()"): read `isolated_worktree:` from the
  # semaphore directly instead of inferring it from an unrelated path. Found
  # live 06.09 (WP-484): two isolated closes both blocked on "no terminal
  # RUN-quick-close card" despite the card sitting, committed and pushed,
  # exactly where `open --isolate` put it.
  RUNNER_CARD_DIRS=("$IWE_ROOT/$GOV_REPO/inbox/agent/tasks")
  SESSION_GOVERNANCE_WORKTREE=$(semaphore_governance_worktree "$SEM_FILE" || true)
  if [ -n "$SESSION_GOVERNANCE_WORKTREE" ] \
     && [ "$SESSION_GOVERNANCE_WORKTREE" != "$IWE_ROOT/$GOV_REPO" ]; then
    RUNNER_CARD_DIRS+=("$SESSION_GOVERNANCE_WORKTREE/inbox/agent/tasks")
  fi
  RUNNER_CARDS=()
  for runner_dir in "${RUNNER_CARD_DIRS[@]}"; do
    for card in "$runner_dir"/RUN-quick-close-"${SLUG}"*.md; do
      [ -f "$card" ] && RUNNER_CARDS+=("$card")
    done
  done

  # WP-484 V(b) (01.09, пир-сессия с Kimi+Codex): SLUG глоб выше не различает
  # владельца -- две параллельные сессии с одинаковым именем задачи дадут
  # одинаковый SLUG, и completed-карточка чужой сессии молча закрывает ЭТОТ
  # close. HARNESS_SESSION_ID (уже используется ниже, в cancel-obligation
  # ветке WP-537) читается здесь один раз и фильтрует RUNNER_CARDS ДО того,
  # как его увидит любая из веток ниже -- предикат общий для всех них, не
  # копия в каждом цикле (третье совпадающее место было бы дублем, P2).
  # Fail-open, не fail-closed, когда HARNESS_SESSION_ID у ЭТОЙ сессии
  # неизвестен: комментарий Ф118 выше документирует независимую гонку, из-за
  # которой harness_session_id часто отсутствует в семафоре на вполне
  # легитимных close -- требовать его здесь безусловно превратило бы редкую
  # security-дыру в частую поломку обычного quick-close. Когда он ИЗВЕСТЕН,
  # карточка без owner_session_id (легаси, до 25.08) или с чужим
  # owner_session_id отбрасывается -- именно тот случай, где сравнение
  # реально возможно и должно быть строгим.
  HARNESS_SESSION_ID=$(grep "^harness_session_id: " "${SEM_FILE:-}" 2>/dev/null | cut -d' ' -f2- || true)
  if [ -n "$HARNESS_SESSION_ID" ] && [ ${#RUNNER_CARDS[@]} -gt 0 ]; then
    OWNED_CARDS=()
    for card in "${RUNNER_CARDS[@]}"; do
      CARD_OWNER=$(_card_field "$card" owner_session_id)
      if [ "$CARD_OWNER" = "$HARNESS_SESSION_ID" ]; then
        OWNED_CARDS+=("$card")
      else
        echo "Session CLOSE: пропускаю $card -- owner_session_id ($CARD_OWNER) не совпадает с этой сессией ($HARNESS_SESSION_ID)" >&2
      fi
    done
    RUNNER_CARDS=("${OWNED_CARDS[@]+"${OWNED_CARDS[@]}"}")
  fi
  RUNNER_OK=""
  TERMINAL_PROOF_MODE=""

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
  # ${SEM_FILE:-} (портировано из шаблона, T22, 30.08): T22 подключает это
  # окно отдельно под set -u без заглушки семафора; пустой путь -> grep не
  # находит совпадение -> обход корректно не срабатывает.
  if grep -q '^close_path: peer-session$' "${SEM_FILE:-}" 2>/dev/null; then
    RUNNER_OK="declared-peer-session:$SLUG"
    TERMINAL_PROOF_MODE="sentinel"
    FORCED_CARD="declared-peer-session:$SLUG"
    echo "Session CLOSE: close_path=peer-session объявлен при open — раннер не требуется (WP-484 Ф118)." >&2
  fi

  # WP-537 Ф30 (08.09, АрхГейт по варианту (б) Ф25.1, совет Kimi+Codex —
  # оба независимо выбрали этот вариант). Тот же паттерн, что close_path:
  # peer-session выше: `open --close-path publish-only` объявляет заранее,
  # что весь жизненный цикл этой изолированной копии -- открыть, закоммитить,
  # запушить, закрыть -- один узкий служебный акт (протолкнуть файл в origin
  # из-под заморозки канона), а не интерактивная работа, которой нужен
  # ритуал quick-close. Назначение -- для мест, где `open --isolate` вызывается
  # ИСКЛЮЧИТЕЛЬНО ради публикации (не для целой сессии под фризом, как в
  # freeze-fallback peer-conversation) -- предотвращает саму находку
  # Ф25.1/Ф26 (осиротевший семафор второго/третьего слага одного разговора),
  # а не только лечит её постфактум маркером (Ф28/Ф29 выше, который остаётся
  # защитным слоем на случай пропущенного close_path).
  if grep -q '^close_path: publish-only$' "${SEM_FILE:-}" 2>/dev/null; then
    RUNNER_OK="declared-publish-only:$SLUG"
    TERMINAL_PROOF_MODE="sentinel"
    FORCED_CARD="declared-publish-only:$SLUG"
    echo "Session CLOSE: close_path=publish-only объявлен при open — раннер не требуется (WP-537 Ф30)." >&2
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
    TERMINAL_PROOF_MODE="completed"
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
      TERMINAL_PROOF_MODE="release-step"
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
      TERMINAL_PROOF_MODE="archive-cancelled"
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
      DEFERRED_NO_REFLECTION_EVENT="$ARCHIVE_EVENT"
      echo "wp-archive-run отменён, push подтверждён -- terminal proof принят; ledger будет записан после terminal transition (WP-537)" >&2
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
      TERMINAL_PROOF_MODE="blocked-witness"
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
    DEFERRED_NO_REFLECTION_EVENT="$FORCE_EVENT"
    echo "force-no-reflection: terminal proof принят ($FORCED_CARD); ledger будет записан после terminal transition" >&2
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
    # HARNESS_SESSION_ID уже вычислен выше (V(b) owner-фильтр RUNNER_CARDS).
    OBLIGATION_CLI="$IWE_ROOT/$GOV_REPO/scripts/close_obligation.py"
    if [ -n "$HARNESS_SESSION_ID" ] && [ -f "$OBLIGATION_CLI" ]; then
      CANCEL_STATUS=$(python3 "$OBLIGATION_CLI" cancel-status --session-id "$HARNESS_SESSION_ID" 2>/dev/null) || CANCEL_STATUS=""
      if [ -n "$CANCEL_STATUS" ] && [ "$(printf '%s' "$CANCEL_STATUS" | jq -r '.cancelled // false' 2>/dev/null)" = "true" ]; then
        RUNNER_OK="cancel-obligation:$HARNESS_SESSION_ID"
        TERMINAL_PROOF_MODE="sentinel"
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

  # WP-537 Ф29 (07.09, по решению пилота после ревью Fable): slug -> run_id
  # маркер вместо эвристики "тот же владелец + тот же WP". process-runner.py
  # держит обязательство quick-close на весь harness-разговор, а не на слаг --
  # когда второй/третий слаг того же разговора получает "already_completed",
  # раннер теперь пишет marker-файл, называющий run_id, который РЕАЛЬНО
  # удовлетворил именно ЭТОТ слаг (_write_slug_satisfied_marker в
  # process-runner.py) -- источник истины сам раннер, не WP/owner-угадывание
  # постфактум. Читаем маркер до heuristic-фолбэка ниже (он остаётся только
  # для карточек, заведённых ДО этого деплоя, у которых маркера ещё нет).
  #
  # Ф29.1 (08.09, финальное холодное ревью перед закрытием сессии, Critical):
  # ключ маркера -- голый $SLUG, без привязки к владельцу, а файл никогда не
  # удалялся -- та же коллизия слага между независимыми разговорами, что уже
  # задокументирована как реальный риск для V(b) (:2602) и Ф28 (:2916), плюс
  # маркер от давно закрытой чужой сессии молча переживал её и мог
  # удовлетворить чужой close сколь угодно позже. Сверка владельца и WP теми
  # же helper'ами, что уже проверены в Ф28.1 -- при неизвестном
  # HARNESS_SESSION_ID сравнивать не с чем (fail-open, тот же принцип, что
  # везде в этом файле); маркер удаляется после успешного использования
  # (best-effort -- падение unlink не должно ронять close), чтобы не жить
  # вечно.
  if [ -z "$RUNNER_OK" ]; then
    SLUG_MARKER="$IWE_ROOT/.iwe-runtime/quick-close-slug-satisfied/quick-close-${SLUG}.satisfied_by"
    if [ -f "$SLUG_MARKER" ] && [ -n "$HARNESS_SESSION_ID" ]; then
      MARKER_RUN_ID=$(cat "$SLUG_MARKER" 2>/dev/null || true)
      if [[ "$MARKER_RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
        MARKER_WP_NUM=$(printf '%s' "$WP" | sed -E 's/^[Ww][Pp]-//')
        for runner_dir in "${RUNNER_CARD_DIRS[@]}"; do
          MARKER_CARD="$runner_dir/RUN-${MARKER_RUN_ID}.md"
          [ -f "$MARKER_CARD" ] || continue
          grep -q '^process_id: quick-close$' "$MARKER_CARD" || continue
          grep -q '^status: completed$' "$MARKER_CARD" || continue
          [ "$(_card_field "$MARKER_CARD" owner_session_id)" = "$HARNESS_SESSION_ID" ] || continue
          [ -n "$MARKER_WP_NUM" ] && [ "$(_quick_close_card_wp "$MARKER_CARD")" = "$MARKER_WP_NUM" ] || continue
          RUNNER_OK="$MARKER_CARD"
          TERMINAL_PROOF_MODE="marker-completed"
          echo "Session CLOSE: у slug '$SLUG' нет своей карточки, но раннер отметил её обязательство удовлетворённым прогоном $MARKER_RUN_ID ($MARKER_CARD) -- признаю терминальным (WP-537 Ф29, slug-satisfied marker)." >&2
          SLUG_MARKER_TO_REMOVE="$SLUG_MARKER"
          break 2
        done
      fi
    fi
  fi

  # WP-537 Ф25.1/Ф26 -> Ф28 (07.09, пир-сессия 2026-09-07-13, Kimi+Codex).
  # Legacy-фолбэк: применяется только к карточкам без своего slug-satisfied
  # маркера (Ф29 выше) -- заведённым до его деплоя. Owner-terminality как
  # последний защитный слой. Раннер держит обязательство
  # quick-close на весь harness-разговор, а не на слаг: первый completed-прогон
  # отвечает "already_completed" всем следующим слагам того же разговора и
  # своей карточки им не заводит -- семафоры второго/третьего слага сиротели.
  # Условия входа намеренно узкие: (1) ни одна ветка выше не сработала;
  # (2) у ЭТОГО слага нет вообще ни одной собственной карточки владельца --
  # cancelled/running-карточка слага должна дойти до своей диагностики ниже,
  # а не маскироваться чужой старой completed (ревью 07.09, High);
  # (3) harness id известен (fail-open как у V(b)); (4) карточка того же
  # владельца, completed, и того же WP по _quick_close_card_wp -- иначе
  # completed-карточка WP-A того же длинного разговора закрыла бы WP-B.
  # Read-only: чужие карточки не трогаются, закрывается только свой семафор.
  # Стоит после cancel-obligation, чтобы ни одна штатная ветка (и их
  # ledger-события) не перехватывалась раньше времени.
  if [ -z "$RUNNER_OK" ] && [ ${#RUNNER_CARDS[@]} -eq 0 ] && [ -n "$HARNESS_SESSION_ID" ]; then
    WP_NUM=$(printf '%s' "$WP" | sed -E 's/^[Ww][Pp]-//')
    if [ -z "$WP_NUM" ]; then
      echo "Session CLOSE: owner-terminality не применяю -- WP этой сессии неизвестен (нет --wp и wp: в семафоре)" >&2
    else
      for runner_dir in "${RUNNER_CARD_DIRS[@]}"; do
        for card in "$runner_dir"/RUN-quick-close-*.md; do
          [ -f "$card" ] || continue
          grep -q '^process_id: quick-close$' "$card" || continue
          grep -q '^status: completed$' "$card" || continue
          [ "$(_card_field "$card" owner_session_id)" = "$HARNESS_SESSION_ID" ] || continue
          CARD_WP_NUM=$(_quick_close_card_wp "$card")
          [ -n "$CARD_WP_NUM" ] && [ "$CARD_WP_NUM" = "$WP_NUM" ] || continue
          RUNNER_OK="$card"
          TERMINAL_PROOF_MODE="owner-completed"
          echo "Session CLOSE: у slug '$SLUG' нет своей карточки, но обязательство этого разговора для WP-$WP_NUM уже выполнено completed-прогоном под другим слагом ($card) -- признаю терминальным (WP-537 Ф28, owner-terminality)." >&2
          break 2
        done
      done
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
    POST_CLOSE_CANCEL_MODE="happy"
    POST_CLOSE_EXCLUDE_RUN_ID=$(grep "^run_id: " "$RUNNER_OK" | head -1 | cut -d' ' -f2- || true)
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
    POST_CLOSE_CANCEL_MODE="forced"
    POST_CLOSE_FORCED_RUN_ID=$(grep "^run_id: " "$FORCED_CARD" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  fi

  audit_runner_cards

  if [ -f "$RUNNER_OK" ] && [ ! -L "$RUNNER_OK" ]; then
    TERMINAL_PROOF_KIND="file"
    TERMINAL_PROOF_REFERENCE=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RUNNER_OK")
    [ -n "$TERMINAL_PROOF_MODE" ] \
      || fail "close: internal terminal-card mode отсутствует" 7
    TERMINAL_EXPECTED_OWNER="${HARNESS_SESSION_ID:-$SESSION_ID}"
    TERMINAL_PROOF_SHA256=$(_terminal_card_snapshot_sha "$TERMINAL_PROOF_REFERENCE" \
      "$TERMINAL_PROOF_MODE" "$TERMINAL_EXPECTED_OWNER" "$WP" "$SLUG" || true)
  else
    TERMINAL_PROOF_KIND="sentinel"
    TERMINAL_PROOF_REFERENCE="$RUNNER_OK"
    TERMINAL_PROOF_SHA256=$(_terminal_proof_snapshot_sha "$TERMINAL_PROOF_KIND" "$TERMINAL_PROOF_REFERENCE" || true)
  fi
  [ -n "$TERMINAL_PROOF_SHA256" ] \
    || fail "close: terminal proof не удалось снять как immutable owned snapshot; никаких terminal mutation не выполнено" 7
  else
    echo "Session CLOSE: продолжаю exact staged transition ($CLOSE_RESUME_STATE); mutable card/scope уже связаны delivery digest." >&2
  fi

  # cancel-session and audit above are retry-safe runner operations: their
  # failures either block here (audit) or stay visible warnings (idempotent
  # cancellation).  The irreversible session transition starts only now,
  # under one exact-session lock.  Delivery and worktree cleanup finish
  # before `.open` can become `.closed`.
  _close_delivery_and_transition
  release_session_transition_lock \
    || fail "Session CLOSE завершил terminal transition, но exact lock не освободился" 7

  _cleanup_closed_session_projections "$SEM_FILE" "$AGENT" "$SESSION_ID" \
    || echo "⚠️  closed receipt создан, но lease/pointer projection не прошла identity CAS" >&2
  if _agent_has_other_open_session "$AGENT"; then
    CLOSE_REPORT_IDLE=0
  else
    CLOSE_REPORT_IDLE=1
  fi

  # These are replayable projections/cleanup, never evidence for the terminal
  # decision.  Run them only after `.closed` is authoritative and with the
  # authority FDs already closed, so ledger's detached publisher cannot keep a
  # session lock alive.
  if [ -n "$DEFERRED_NO_REFLECTION_EVENT" ] && [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" \
      session_closed_no_reflection "$DEFERRED_NO_REFLECTION_EVENT" session-guard \
      || echo "⚠️  terminal close завершён, но no-reflection ledger projection не записана" >&2
  fi
  if [ "$POST_CLOSE_CANCEL_MODE" = "happy" ]; then
    (cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" \
      cancel-session quick-close "$SESSION_ID" --exclude "$POST_CLOSE_EXCLUDE_RUN_ID") \
      2>&1 || echo "cancel-session (happy path) не прошёл — terminal close уже завершён" >&2
  elif [ "$POST_CLOSE_CANCEL_MODE" = "forced" ]; then
    if [ -n "$POST_CLOSE_FORCED_RUN_ID" ]; then
      (cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" \
        cancel "$POST_CLOSE_FORCED_RUN_ID") 2>&1 \
        || echo "адресный cancel принятой карточки не прошёл — terminal close уже завершён" >&2
    fi
    (cd "$IWE_ROOT/$GOV_REPO" && python3 "$IWE_ROOT/$GOV_REPO/scripts/process-runner.py" \
      cancel-session quick-close "$SESSION_ID") 2>&1 \
      || echo "cancel-session (force path) не прошёл — terminal close уже завершён" >&2
  fi
  [ -z "$SLUG_MARKER_TO_REMOVE" ] || rm -f "$SLUG_MARKER_TO_REMOVE" 2>/dev/null || true

  # Only a completed terminal rename may revoke the lease/pointer and report
  # the agent idle.  These are projections of `.closed`, not its authority.
  if [ "$CLOSE_REPORT_IDLE" -eq 1 ] && [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality "$PERSONALITY_FROM_SEM" \
      "$AGENT" idle "" "" 2>/dev/null || true
  fi
  echo "Session CLOSE: $WP → $ORZ_FILE ✅"
  # version-handshake (WP-484 Ф124/Ф125 план Этапа 0, линия 1, wiring 3а) --
  # same best-effort surfacing as the open-side call above.
  IWE_VERSION_SCRIPT="$IWE_ROOT/scripts/iwe-version.sh"
  [ -x "$IWE_VERSION_SCRIPT" ] && "$IWE_VERSION_SCRIPT" 2>/dev/null || true

  # Warn if local commits are not pushed in repos touched by this session
  _warn_unpushed() {
    local repo="$1"
    local ahead
    ahead=$(git -C "$repo" rev-list --left-only --count HEAD...origin/main 2>/dev/null || echo "")
    if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
      echo "⚠️  $ahead незапушенных коммита в $(basename "$repo"). Выполни: git -C $repo push" >&2
    fi
  }
  # Terminal transition above guarantees this exact receipt exists.
  _sem_read="$SEM_FILE.closed"
  _seen_repos=""
  _warn_unpushed_once() {
    local repo="$1"
    [ -n "$repo" ] || return 0
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    printf '%s\n' "$_seen_repos" | grep -qxF "$repo" && return 0
    _seen_repos="${_seen_repos}${repo}"$'\n'
    _warn_unpushed "$repo"
  }

  # Governance and session content are separate repositories after WP-526.
  # Read both identities from the semaphore instead of guessing a repository
  # from a repo-relative `file:` path. If an old semaphore has neither checkout
  # field, preserve the canonical governance fallback.
  _governance_repo=$(semaphore_governance_worktree "$_sem_read" || true)
  if [ -n "$_governance_repo" ]; then
    _warn_unpushed_once "$_governance_repo"
  elif ! grep -qE '^(governance_worktree|isolated_worktree): ' "$_sem_read" 2>/dev/null; then
    _warn_unpushed_once "$IWE_ROOT/$GOV_REPO"
  fi
  # ORZ_SESSIONS_DIR is the authoritative location close actually selected:
  # it stays on the snapshot repo in the normal case and is reassigned to the
  # canonical fallback when that snapshot no longer contains this ORZ.
  _sessions_dir="${ORZ_SESSIONS_DIR:-$ORZ_DIR}"
  _sessions_repo=$(git -C "$_sessions_dir" rev-parse --show-toplevel 2>/dev/null || true)
  _warn_unpushed_once "$_sessions_repo"

  # `file:` remains repo-relative and can name a third repository not covered
  # by either explicit identity (for example the IWE root). Preserve the old
  # best-effort discovery for every schema generation; dedupe keeps the two
  # explicit repositories above from producing duplicate warnings.
  while IFS= read -r _line; do
    [[ "$_line" =~ ^file:\ (.*) ]] || continue
    _repo=$(git -C "$IWE_ROOT/$(dirname "${BASH_REMATCH[1]}")" rev-parse --show-toplevel 2>/dev/null || true)
    _warn_unpushed_once "$_repo"
  done < <(cat "$_sem_read" 2>/dev/null || true)

  # Best-effort атрибуция ТОЛЬКО для закрытий, обошедших process-runner.py
  # (FORCED_CARD непустой на каждом из 4 bypass-путей выше: peer-session,
  # auto-archive-cancelled, force-no-reflection, cancel-obligation) --
  # r23_verdict их не видит, R23-серия покрывала лишь ~7% реальных закрытий
  # (WP-484 Ф128/Ф131). Условие обязательно: без него событие писалось бы и
  # для нормального завершённого раннера, задваивая r23_verdict тем же
  # смыслом под другим именем (найдено cold-review Ф133, High). Никогда не
  # проваливает close.
  if [ -n "${FORCED_CARD:-}" ] && [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    _cp_from_sem=$(grep "^close_path: " "$_sem_read" 2>/dev/null | cut -d' ' -f2- || echo "unknown")
    _direct_event=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "close_path": sys.argv[4]}))
' "$WP" "$SLUG" "$AGENT" "$_cp_from_sem" 2>/dev/null) || _direct_event=""
    if [ -n "$_direct_event" ]; then
      bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_closed_direct "$_direct_event" session-guard \
        >/dev/null 2>&1 || echo "  ⚠️  ledger session_closed_direct не записан (best-effort, не блокирует close)" >&2
    fi

    # Which bypass path closed this session (WP-484, 05.09). Classified from the
    # evidence FORCED_CARD already carries, not from a flag the caller could set
    # wrong: the two synthetic values name their own channel, the two real cards
    # are told apart by the step they stopped on. A future fifth bypass lands in
    # `unclassified` and still gets its hours recorded (ledger-append.sh degrades
    # the unknown name to "unknown" and keeps the original) -- losing the hours
    # would be the worse failure of the two.
    _close_channel="unclassified"
    case "$FORCED_CARD" in
      declared-peer-session:*) _close_channel="peer-session" ;;
      cancel-obligation:*)     _close_channel="cancel-obligation" ;;
      *)
        if [ -f "$FORCED_CARD" ]; then
          if grep -q '^current_step: wp-archive-run$' "$FORCED_CARD"; then
            _close_channel="auto-archive-cancelled"
          elif grep -q '^current_step: blocked-witness-unavailable$' "$FORCED_CARD"; then
            _close_channel="force-no-reflection"
          fi
        fi
        ;;
    esac

    # Every channel goes through the same call, including `auto-archive-cancelled`.
    # The first cut skipped that one structurally, reasoning that its card sits at
    # `current_step: wp-archive-run` and `session-ledger-append` runs earlier in
    # quick-close.yaml, so the runner must already have written the event. Cold
    # review 05.09 broke that reasoning: step ORDER is not step SUCCESS -- the
    # ledger handler returns `{"status":"error"}` with exit 0 by contract ("never
    # fails Quick Close"), and the YAML `next:` transition is not gated on it, so
    # the pipeline reaches wp-archive-run even when nothing was actually written.
    # Deciding from evidence instead of from ordering: emit_session_closed checks
    # the ledger itself (by session_file, which the runner's own events carry) and
    # skips only when the event is really there.
    emit_session_closed "$_close_channel" "$_sem_read" "$WP" "$SLUG" "$AGENT"
  fi

  # Deliberately OUTSIDE the ledger block above: releasing the close obligation has
  # nothing to do with whether ledger-append.sh exists, and an unmigrated template
  # install (no ledger writer) would otherwise silently keep the obligation forever
  # (cold review 06.09, Medium). The evidence used here is the semaphore's own
  # `close_path`, which is what actually makes this a peer session -- not the
  # channel classification, which is derived inside that block for a different
  # purpose. Why the clear belongs to the close and not to the calling skill: see
  # the clear_peer_session_obligation() docstring.
  if grep -q '^close_path: peer-session$' "$_sem_read" 2>/dev/null; then
    clear_peer_session_obligation "$_sem_read" "$SLUG"
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
  acquire_session_transition_lock "$SEM_FILE"
  LOCKED_NOTE_SESSION_ID=$(_locked_open_identity "$SEM_FILE" "$NOTE_AGENT" "${SESSION_ID_ARG:-}" || true)
  [ -n "$LOCKED_NOTE_SESSION_ID" ] \
    || fail "note-file: semaphore изменился после resolve или уже закрывается" 1
  [ "$(_close_delivery_state "$SEM_FILE" "$LOCKED_NOTE_SESSION_ID" || true)" = "none" ] \
    || fail "note-file: close transition уже подготовлен; scope frozen" 1
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

# --- NOTE-COMMIT (WP-537, peer session 2026-09-05-24 with Kimi) ---
#
#   session-guard.sh note-commit <sha> [--repo <name>] [--agent|--wp|--slug|--session-id ...]
#
# Records "this session produced this commit in this repo" in the semaphore, so
# commit-push.sh can verify the claim "my work is already published" against the
# session's OWN commits instead of the state of the whole branch.
#
# Why it is needed: the confirmed_clean_repos branch of commit-push.sh reads the
# `file:` registry to scope its cleanliness check, but still answers "delivered?"
# with `git rev-list @{u}..HEAD` over the entire branch. In a shared checkout one
# unpushed commit from a NEIGHBOURING session rejects this session's honest
# claim. Deriving the SHA after the fact (`git log -1 -- <my files>`) was
# rejected in the same peer session: it answers "who last touched the file", not
# "is my commit delivered", and can pass falsely once a newer pushed commit by
# someone else touches the same file.
#
# Repo-qualified on purpose: one semaphore mixes repo-relative `file:` entries
# from several repositories with no separator, so a bare `commit: <sha>` would
# inherit exactly that ambiguity.
if [ "$CMD" = "note-commit" ]; then
  COMMIT_SHA="${POSITIONAL[0]:-}"
  [ -z "$COMMIT_SHA" ] && fail "note-commit: не передан <sha> коммита" 1
  NOTE_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$NOTE_AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") \
      || fail "note-commit: --session-id $SESSION_ID_ARG не резолвится (см. диагностику выше)" 1
  else
    SEM_FILE=$(select_semaphore "$NOTE_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
      fail "note-commit: нет открытой сессии для агента '$NOTE_AGENT' (уточни --wp/--slug/--session-id)" 1
    fi
  fi
  acquire_session_transition_lock "$SEM_FILE"
  LOCKED_NOTE_SESSION_ID=$(_locked_open_identity "$SEM_FILE" "$NOTE_AGENT" "${SESSION_ID_ARG:-}" || true)
  [ -n "$LOCKED_NOTE_SESSION_ID" ] \
    || fail "note-commit: semaphore изменился после resolve или уже закрывается" 1
  [ "$(_close_delivery_state "$SEM_FILE" "$LOCKED_NOTE_SESSION_ID" || true)" = "none" ] \
    || fail "note-commit: close transition уже подготовлен; commit claims frozen" 1
  # $IWE_ROOT is itself a git repository, but it is not a directory INSIDE
  # $IWE_ROOT -- `--repo IWE` therefore resolved to $IWE_ROOT/IWE and was
  # refused with "не git-репозиторий", which reads as "no such repo" for a
  # repo that plainly exists (WP-537, 06.09: the workaround was to drop the
  # flag and call from the root). `iwe-root` is the name the READERS of this
  # claim already use for it (commit-push.sh / gather-session-facts.sh
  # resolve_repo_dir, WP-525 Ф4), so it is the spelling recorded below --
  # the root's basename is accepted as an alias for the same directory.
  NC_ROOT_ALIAS="iwe-root"
  NC_ROOT_BASENAME=$(basename "$IWE_ROOT")
  if [ -n "$REPO_ARG" ]; then
    # cold review: ".." or a leading "/" would resolve outside $IWE_ROOT while
    # the failure message below still (falsely) claims the check happened.
    case "$REPO_ARG" in
      */*|*..*) fail "note-commit: --repo '$REPO_ARG' должен быть именем каталога внутри $IWE_ROOT без '/' и '..'" 1 ;;
    esac
    if [ "$REPO_ARG" = "$NC_ROOT_ALIAS" ] || [ "$REPO_ARG" = "$NC_ROOT_BASENAME" ]; then
      NC_REPO_DIR="$IWE_ROOT"
    else
      NC_REPO_DIR="$IWE_ROOT/$REPO_ARG"
    fi
    git -C "$NC_REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
      || fail "note-commit: '$REPO_ARG' не git-репозиторий внутри $IWE_ROOT (сам корневой репозиторий заявляется как --repo $NC_ROOT_ALIAS)" 1
  else
    NC_REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$NC_REPO_DIR" ] \
      || fail "note-commit: текущий каталог вне git-контекста и --repo не задан — репозиторий определить нечем" 1
  fi
  if [ "$(realpath "$NC_REPO_DIR" 2>/dev/null || echo "$NC_REPO_DIR")" = "$(realpath "$IWE_ROOT" 2>/dev/null || echo "$IWE_ROOT")" ]; then
    NC_REPO_NAME="$NC_ROOT_ALIAS"
  else
    NC_REPO_NAME=$(basename "$NC_REPO_DIR")
  fi
  # The semaphore line is "commit: <repo> <sha>", split by the reader on the
  # first space (commit-push.sh: c_entry%%' '*). A space in the name would
  # silently corrupt that split and drop the claim into ahead-only with no
  # diagnostic anywhere -- reject it here where the cause is still visible.
  case "$NC_REPO_NAME" in
    *' '*) fail "note-commit: имя репозитория '$NC_REPO_NAME' содержит пробел — формат семафора 'commit: <repo> <sha>' это не переживёт" 1 ;;
  esac
  # Full 40-char form only: a short SHA recorded today can become ambiguous as
  # the repo grows, and the reader resolves it long after this session is gone.
  NC_FULL_SHA=$(git -C "$NC_REPO_DIR" rev-parse --verify --quiet "${COMMIT_SHA}^{commit}" 2>/dev/null) \
    || fail "note-commit: '$COMMIT_SHA' не резолвится в коммит репозитория '$NC_REPO_NAME'" 1
  NC_ENTRY="commit: $NC_REPO_NAME $NC_FULL_SHA"
  # Idempotent: the same commit may legitimately be reported twice (a retried
  # close step), and a duplicated entry would be verified twice for nothing.
  if ! grep -qxF "$NC_ENTRY" "$SEM_FILE" 2>/dev/null; then
    echo "$NC_ENTRY" >> "$SEM_FILE"
  fi
  echo "Noted commit: $NC_REPO_NAME $NC_FULL_SHA"
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

# --- FENCING TOKEN (WP-530 Ф24 п.5, ArchGate 06.09) ---
#
# Until 06.09 this primitive had no ownership-change token at all: a lock past
# its TTL was reclaimed by `rm -rf` on the lockdir, and the previous holder got
# no signal whatsoever -- it went on writing to a file it no longer held. The
# gateway lock (gateway-lock.py, fencingToken) and the publish lease
# (publish-lease.sh, epoch) both already had one; the most frequently used
# primitive of the three did not. Cold review during the ArchGate called this a
# sharper hole than the cross-host one the gate was convened for.
#
# The token is <monotonic epoch>.<nonce>. The epoch lives OUTSIDE the lockdir
# (a sibling `.epoch` file) so it survives reclaim and keeps the fencing order
# a fencing token is supposed to give. The nonce covers the one case a bare
# counter cannot: if the whole hot-file-locks directory is wiped, the counter
# restarts at 1 and a token from a long-dead holder would compare equal again.
_hot_lock_meta_field() {  # _hot_lock_meta_field <lockdir> <field>
  grep "^$2: " "$1/meta" 2>/dev/null | head -1 | cut -d' ' -f2-
}

if [ "$CMD" = "lock-hot-file" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "lock-hot-file: missing path argument" 1
  LOCK_HOLDER_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  mkdir -p "$HOT_LOCK_DIR"
  LOCK_SLUG=$(_hot_lock_slug "$HOT_PATH")
  LOCK_PATH="$HOT_LOCK_DIR/$LOCK_SLUG.lockdir"
  EPOCH_FILE="$HOT_LOCK_DIR/$LOCK_SLUG.epoch"
  ATTEMPT=0
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    if [ -f "$LOCK_PATH/meta" ]; then
      HELD_AT=$(_hot_lock_meta_field "$LOCK_PATH" "locked_at")
      HELD_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$HELD_AT" +%s 2>/dev/null \
        || date -u -d "$HELD_AT" +%s 2>/dev/null || echo 0)
      AGE=$(( $(date +%s) - HELD_EPOCH ))
      if [ "$AGE" -gt "$HOT_LOCK_TTL_SEC" ]; then
        echo "lock-hot-file: stale lock on '$HOT_PATH' (age ${AGE}s > ttl ${HOT_LOCK_TTL_SEC}s) — reclaiming" >&2
        # Rename, then delete: `rm -rf` straight on the live path could delete
        # a FRESH lockdir a third session created in the window between our
        # staleness check and our delete (the same race with_isolate_lock
        # documents above). `mv` is atomic -- exactly one reclaimer wins, the
        # loser's mv fails and it simply re-enters the loop.
        HOT_STALE_PATH="$LOCK_PATH.stale.$$.$(date +%s)"
        if mv "$LOCK_PATH" "$HOT_STALE_PATH" 2>/dev/null; then
          rm -rf "$HOT_STALE_PATH"
          continue  # we just cleared it ourselves -- try mkdir again right away
        fi
        # mv failed: another session's reclaim won this race (cold-review,
        # WP-530 Ф25 follow-up, 06.09). This used to fall through to a bare
        # `continue` here too, skipping BOTH the >30-attempt cap and the
        # backoff below -- a session that keeps losing the reclaim race could
        # spin on `mkdir` indefinitely, never tripping the safety net this
        # loop exists to provide. Falling through now counts it as a normal
        # attempt instead.
      fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -gt 30 ]; then
      HOLDER=$(cat "$LOCK_PATH/agent" 2>/dev/null || echo "unknown")
      fail "lock-hot-file: '$HOT_PATH' held by '$HOLDER' for >30s, giving up — retry shortly" 1
    fi
    sleep 1
  done
  # Only the winner of the atomic mkdir above ever reads or writes the epoch
  # file, so the increment needs no lock of its own.
  HOT_LOCK_PREV_EPOCH=$(cat "$EPOCH_FILE" 2>/dev/null || echo 0)
  case "$HOT_LOCK_PREV_EPOCH" in
    ''|*[!0-9]*) HOT_LOCK_PREV_EPOCH=0 ;;
  esac
  HOT_LOCK_EPOCH=$((HOT_LOCK_PREV_EPOCH + 1))
  HOT_LOCK_NEW_TOKEN="$HOT_LOCK_EPOCH.$(date +%s)-$$-${RANDOM}"
  printf '%s\n' "$HOT_LOCK_EPOCH" > "$EPOCH_FILE"
  {
    echo "locked_at: $(now_iso)"
    echo "agent: $LOCK_HOLDER_AGENT"
    echo "token: $HOT_LOCK_NEW_TOKEN"
  } > "$LOCK_PATH/meta"
  echo "$LOCK_HOLDER_AGENT" > "$LOCK_PATH/agent"
  echo "Locked: $HOT_PATH"
  echo "token: $HOT_LOCK_NEW_TOKEN"
  exit 0
fi

# check-hot-lock <path> --token <t> -- "am I still the holder?". This is the
# half that makes the token worth having: a holder that was reclaimed can now
# find out BEFORE it writes, instead of discovering it never (WP-530 Ф24 п.5).
if [ "$CMD" = "check-hot-lock" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "check-hot-lock: missing path argument" 1
  [ -z "$HOT_LOCK_TOKEN" ] && fail "check-hot-lock: нужен --token (значение, напечатанное lock-hot-file)" 1
  LOCK_PATH="$HOT_LOCK_DIR/$(_hot_lock_slug "$HOT_PATH").lockdir"
  if [ ! -d "$LOCK_PATH" ]; then
    fail "check-hot-lock: замка на '$HOT_PATH' больше нет — он снят или отобран, токен $HOT_LOCK_TOKEN недействителен" 1
  fi
  HOT_LOCK_CURRENT_TOKEN=$(_hot_lock_meta_field "$LOCK_PATH" "token")
  if [ "$HOT_LOCK_CURRENT_TOKEN" != "$HOT_LOCK_TOKEN" ]; then
    HOLDER=$(cat "$LOCK_PATH/agent" 2>/dev/null || echo "unknown")
    fail "check-hot-lock: замок на '$HOT_PATH' отобран — сейчас держит '$HOLDER' (токен ${HOT_LOCK_CURRENT_TOKEN:-отсутствует}), у тебя $HOT_LOCK_TOKEN. Перечитай файл и возьми замок заново" 1
  fi
  echo "Lock held: $HOT_PATH (token $HOT_LOCK_TOKEN)"
  exit 0
fi

if [ "$CMD" = "unlock-hot-file" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "unlock-hot-file: missing path argument" 1
  LOCK_PATH="$HOT_LOCK_DIR/$(_hot_lock_slug "$HOT_PATH").lockdir"
  # Without a token the old behaviour stands (any caller may clear the lock):
  # existing callers pass no token, and refusing them would break unlock for
  # everyone. WITH a token the unlock becomes owner-checked -- a holder whose
  # lock was reclaimed no longer silently deletes the lock of whoever took it
  # over next.
  if [ -n "$HOT_LOCK_TOKEN" ] && [ -d "$LOCK_PATH" ]; then
    HOT_LOCK_CURRENT_TOKEN=$(_hot_lock_meta_field "$LOCK_PATH" "token")
    if [ "$HOT_LOCK_CURRENT_TOKEN" != "$HOT_LOCK_TOKEN" ]; then
      HOLDER=$(cat "$LOCK_PATH/agent" 2>/dev/null || echo "unknown")
      fail "unlock-hot-file: замок на '$HOT_PATH' уже не наш — держит '$HOLDER' (токен ${HOT_LOCK_CURRENT_TOKEN:-отсутствует}), не снимаю" 1
    fi
  fi
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

  # WP-530 (пир-сессия 2026-08-30-01): CAS-конфликт раньше жил только в stderr
  # вызывающего и терялся -- о гонках узнавали из пересказа пилота. Теперь
  # каждый конфликт оставляет машинный след в дневном ledger. Best-effort:
  # телеметрия не меняет exit-семантику конфликта и молчит, если
  # ledger-append.sh недоступен (немигрированная установка шаблона).
  # TELEMETRY_LOST (Kimi, раунд 3): молчаливая потеря следа неотличима от
  # «следа нет, потому что конфликта нет» -- при недоступном ledger пилот
  # должен видеть в stderr, что конфликт остался без машинной записи.
  emit_write_conflict() {  # $1=expected $2=actual
    local ledger_append="$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh"
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({
        "file": sys.argv[1], "expected": sys.argv[2], "actual": sys.argv[3],
        "agent": sys.argv[4]}))' \
      "$GUARD_PATH" "$1" "$2" "${AGENT:-${IWE_AGENT:-unknown}}" 2>/dev/null)
    if [ -z "$payload" ] || [ ! -x "$ledger_append" ] \
       || ! bash "$ledger_append" day "$(date +%F)" wp_context_write_conflict \
            "$payload" session-guard >/dev/null 2>&1; then
      echo "TELEMETRY_LOST: wp_context_write_conflict не записан в ledger ($GUARD_PATH)" >&2
    fi
  }
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

  # WP-530 Ф24 п.5: keep the fencing token of THIS acquisition. Without it the
  # command below could run against a lock that was reclaimed as stale
  # mid-edit, and neither this caller nor the new holder would ever know.
  GUARD_LOCK_TOKEN=$(bash "$0" lock-hot-file "$GUARD_PATH" ${AGENT:+--agent "$AGENT"} | sed -n 's/^token: //p')
  [ -n "$GUARD_LOCK_TOKEN" ] || fail "wp-context-guarded-edit: lock-hot-file не вернул fencing token" 1

  # `set -e` (top of file) means a failing GUARD_CMD below would otherwise
  # jump straight past unlock-hot-file, leaving the lockdir on disk until its
  # TTL expires -- caught by cold-context review: the error path (a caller
  # like day-close-5g-apply.sh legitimately exiting 1 for LINE_NOT_FOUND) is
  # the COMMON case here, not an edge case, so this isn't optional hardening.
  # A trap fires on any exit from this subshell, not just a plain failing
  # command -- unlike guarding just the one line with `set +e`.
  trap 'bash "$0" unlock-hot-file "$GUARD_PATH" --token "$GUARD_LOCK_TOKEN" >/dev/null 2>&1' EXIT

  if [ "$EXPECTED_ABSENT" = "1" ]; then
    if [ -f "$GUARD_PATH" ]; then
      emit_write_conflict "absent" "exists"
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
      emit_write_conflict "$EXPECTED_HASH" "${ACTUAL_HASH:-missing}"
      {
        echo "CONFLICT"
        echo "expected_hash: $EXPECTED_HASH"
        echo "actual_hash: ${ACTUAL_HASH:-missing}"
        echo "file: $GUARD_PATH"
      } >&2
      exit 1
    fi
  fi

  # The hash check above proves the file did not change; this proves we are
  # still the holder allowed to change it. Both are needed: a lock reclaimed
  # as stale lets a second writer into the critical section without the file
  # having changed yet.
  if ! bash "$0" check-hot-lock "$GUARD_PATH" --token "$GUARD_LOCK_TOKEN" >/dev/null 2>&1; then
    {
      echo "LOCK_LOST"
      echo "file: $GUARD_PATH"
      echo "token: $GUARD_LOCK_TOKEN"
      echo "замок был отобран (протух по TTL или снят) до записи — перечитай файл и повтори"
    } >&2
    exit 1
  fi

  set +e
  "${GUARD_CMD[@]}"
  GUARD_STATUS=$?
  set -e
  # Same check after the write: if the lock changed hands WHILE the command
  # ran, the write happened outside the protection the caller thinks it had.
  # A warning, not a failure -- the command's own exit status is the caller's
  # contract, and the write is already on disk either way.
  if ! bash "$0" check-hot-lock "$GUARD_PATH" --token "$GUARD_LOCK_TOKEN" >/dev/null 2>&1; then
    echo "LOCK_LOST_DURING_WRITE: замок на '$GUARD_PATH' сменил владельца во время записи (token $GUARD_LOCK_TOKEN) — проверь результат" >&2
  fi
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
    # Explicit --session-id is how a caller reaches a session that isn't its
    # own (renewing "my own currently open session" resolves via --wp/--slug
    # below instead, with no session_id known in advance) — no scripted
    # caller in this repo uses `renew --session-id` at all, only ad-hoc
    # interactive use. Require the intent to be explicit.
    if [ "$RENEW_FOREIGN" != "1" ] || [ -z "$UNFREEZE_REASON" ]; then
      fail "renew --session-id продлевает семафор ПО ID, не обязательно свой -- требуется явное '--foreign --reason \"...\"'. Если сессия действительно твоя, продли через --wp/--slug без --session-id." 1
    fi
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
  acquire_session_transition_lock "$SEM_FILE"
  RENEW_SESSION_ID=$(_locked_open_identity "$SEM_FILE" "$RENEW_AGENT" "${SESSION_ID_ARG:-}" || true)
  [ -n "$RENEW_SESSION_ID" ] \
    || fail "renew: semaphore изменился после resolve или уже закрывается" 3
  [ "$(_close_delivery_state "$SEM_FILE" "$RENEW_SESSION_ID" || true)" = "none" ] \
    || fail "renew: close transition уже подготовлен; lease не продлевается" 3
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
  release_session_transition_lock \
    || fail "renew: lease опубликована, но exact session lock не освободился" 1
  echo "Lease RENEW: $(basename "$SEM_FILE") — права на коммит продлены на $((LEASE_SEC / 60)) мин"
  if [ "$RENEW_FOREIGN" = "1" ] && [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    _renew_event=$(python3 -c '
import json, sys
print(json.dumps({"agent": sys.argv[1], "session_id": sys.argv[2], "reason": sys.argv[3]}))
' "$RENEW_AGENT" "$RENEW_SESSION_ID" "$UNFREEZE_REASON" 2>/dev/null) || _renew_event=""
    [ -n "$_renew_event" ] && bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_renewed_foreign "$_renew_event" session-guard \
      >/dev/null 2>&1 || echo "  ⚠️  ledger session_renewed_foreign не записан (best-effort, не блокирует renew)" >&2
  fi
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
  # WP-484 line AC (31.08, peer-session with Kimi+Codex): one `git ls-files`
  # for the whole tree instead of one per file inside validate_orz -- see the
  # comment at its "git tracked" check for the measured cost this replaces.
  # Trade-off, found by diffing a live before/after benchmark rather than by
  # inspection: this is a single snapshot taken before the scan starts, not
  # a live per-file index query. A file committed by a concurrent session
  # during the ~2min scan can show as untracked against this snapshot even
  # though it is tracked by the time its line prints. That is not a false
  # defect -- it just routes that file through the (unchanged) remote-refs
  # fallback below instead of the fast path, which still finds it and logs
  # the existing "✓ ...accepted as equivalent" note instead of an error.
  AUDIT_TRACKED_SET=$(mktemp)
  git -C "$ORZ_DIR" ls-files > "$AUDIT_TRACKED_SET" 2>/dev/null
  find "$ORZ_DIR" -maxdepth 2 -mindepth 2 -name '*.md' -type f ! -name '00-index.md' -newermt "$SINCE" 2>/dev/null | while read -r orz; do
    tmp_errors=$(mktemp)
    # No `agent` extraction here (WP-484 line AC, 31.08): validate_orz's own
    # "agent value" check (§3 inside the function) always re-derives the
    # value from this same file and compared it against whatever the caller
    # passed -- at this call site that was always the file's own value fed
    # back in, so the comparison could never fail. Passing "" trips
    # validate_orz's `[ -n "$agent" ]` guard and skips the comparison
    # outright, reproducing that same always-pass outcome without redoing
    # the `grep|sed|head` extraction per file. A first attempt here passed
    # the literal "unknown" instead, which broke the no-op and started
    # flagging every file with a real agent: value as a false mismatch --
    # caught by diffing this session's before/after benchmark output
    # file-by-file, not by inspection.
    if ! validate_orz "$orz" "" "$ORZ_DIR" "$AUDIT_TRACKED_SET" >"$tmp_errors" 2>&1 && [ -s "$tmp_errors" ]; then
      echo "  $(basename "$orz"):"
      sed 's/^/    /' "$tmp_errors"
    fi
    rm -f "$tmp_errors"
  done
  rm -f "$AUDIT_TRACKED_SET"
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

# --- RECOVER-ORPHANED (WP-484 Ф49) ---
# Recovery is a two-file transition (semaphore + ledger), so ordering alone
# cannot make it crash-safe.  A stable recovery_id plus an explicit
# `.recovery-pending` state makes both crash windows retryable: a retry scans
# every day ledger for that id, appends only when absent, verifies the durable
# event, and only then marks the quarantine `.recovered`.
_recovery_identity_event() {  # <state-file> <base-quarantine-file> <terminal-sha>
  python3 - "$1" "$2" "$IWE_ROOT" "$3" <<'PY'
import datetime
import fcntl
import hashlib
import json
import os
import re
import stat
import sys

state_path, base_path, iwe_root, terminal_sha = sys.argv[1:]
if not re.fullmatch(r"[0-9a-f]{64}", terminal_sha):
    raise SystemExit("invalid terminal proof digest")
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(state_path, flags)
except OSError as error:
    raise SystemExit("cannot open recovery state: %s" % error)
try:
    fcntl.flock(fd, fcntl.LOCK_SH)
    info = os.fstat(fd)
    current = os.lstat(state_path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size <= 0
        or info.st_size > 1024 * 1024
    ):
        raise SystemExit("recovery state is not an owned regular file")
    if stat.S_ISLNK(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit("recovery state pathname changed")
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    raw = b"".join(chunks)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise SystemExit("recovery state content is truncated or malformed")
    text = raw.decode("utf-8")
finally:
    os.close(fd)

def unique(key):
    prefix = key + ": "
    values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise SystemExit("expected exactly one non-empty %s" % key)
    return values[0]

identity = {key: unique(key) for key in (
    "agent", "wp", "slug", "opened_at", "created_at", "session_id",
    "isolated_worktree",
)}
harness_values = [
    line[len("harness_session_id: "):]
    for line in text.splitlines()
    if line.startswith("harness_session_id: ")
]
if len(harness_values) > 1 or (harness_values and not harness_values[0]):
    raise SystemExit("invalid harness_session_id")
identity["harness_session_id"] = harness_values[0] if harness_values else ""
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", identity["agent"]):
    raise SystemExit("invalid agent identity")
if not re.fullmatch(r"WP-[1-9][0-9]*", identity["wp"]):
    raise SystemExit("invalid WP identity")
for key in ("slug", "session_id"):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", identity[key]):
        raise SystemExit("invalid %s identity" % key)
if identity["harness_session_id"] and not re.fullmatch(
    r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", identity["harness_session_id"]
):
    raise SystemExit("invalid harness_session_id identity")
for key in ("opened_at", "created_at"):
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", identity[key]):
        raise SystemExit("invalid %s" % key)
    try:
        datetime.datetime.strptime(identity[key], "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise SystemExit("invalid %s" % key)

base_name = os.path.basename(base_path)
expected_prefix = "%s-%s.open.orphaned-" % (identity["agent"], identity["session_id"])
if not base_name.startswith(expected_prefix) or len(base_name) == len(expected_prefix):
    raise SystemExit("quarantine filename is not bound to agent/session_id")
worktree = os.path.realpath(identity["isolated_worktree"])
store = os.path.realpath(os.path.join(iwe_root, ".iwe-runtime", "isolated-worktrees"))
if not worktree.startswith(store + os.sep) or not os.path.isdir(worktree):
    raise SystemExit("isolated_worktree is outside the managed store or absent")

original_path = os.path.relpath(base_path, iwe_root)
reason = base_name.split(".open.orphaned-", 1)[1]
operation_material = json.dumps(
    {"original_path": original_path, "terminal_proof_sha256": terminal_sha, **identity},
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
event = {
    "recovery_id": hashlib.sha256(operation_material).hexdigest(),
    "original_path": original_path,
    "quarantine_reason": reason,
    "wp": identity["wp"],
    "slug": identity["slug"],
    "session_id": identity["session_id"],
    "agent": identity["agent"],
    "harness_session_id": identity["harness_session_id"],
    "terminal_proof_sha256": terminal_sha,
}
print(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
PY
}

_recovery_event_in_ledger() {  # <ledger-root> <recovery-id>: 0 found, 1 absent, 2 unreadable
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

try:
    import yaml
except ImportError as error:
    print("PyYAML unavailable: %s" % error, file=sys.stderr)
    raise SystemExit(2)

root, recovery_id = sys.argv[1:]
day_root = os.path.join(root, "day")
if not os.path.isdir(day_root):
    raise SystemExit(1)
for directory, names, files in os.walk(day_root):
    names.sort()
    for name in sorted(files):
        if not name.endswith(".yaml"):
            continue
        path = os.path.join(directory, name)
        try:
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("not a regular ledger file")
            with open(path, encoding="utf-8") as source:
                document = yaml.safe_load(source)
            if not isinstance(document, dict) or not isinstance(document.get("events"), list):
                raise ValueError("invalid ledger structure")
        except Exception as error:
            print("cannot verify recovery ledger %s: %s" % (path, error), file=sys.stderr)
            raise SystemExit(2)
        for event in document["events"]:
            if not isinstance(event, dict) or event.get("kind") != "session_recovered_closed":
                continue
            data = event.get("data")
            if isinstance(data, dict) and data.get("recovery_id") == recovery_id:
                raise SystemExit(0)
raise SystemExit(1)
PY
}

_recover_orphaned_locked() {
  local event_json recovery_id stored_recovery_id terminal_sha fields_json
  local ledger_script ledger_root ledger_rc=0 snapshot_sha
  [ -f "$ORPHAN_FILE" ] && [ ! -L "$ORPHAN_FILE" ] \
    || fail "recover-orphaned: состояние исчезло или стало небезопасным: $ORPHAN_FILE" 1

  if [ "$ORPHAN_FILE" = "$BASE_ORPHAN_FILE" ]; then
    terminal_sha=$(_orphaned_worktree_terminal_outcome_proven "$ORPHAN_FILE" || true)
    [ -n "$terminal_sha" ] \
      || fail "recover-orphaned: exact terminal card+owner+WP+slug proof не найден; карантин оставлен без изменений" 1
    event_json=$(_recovery_identity_event "$ORPHAN_FILE" "$BASE_ORPHAN_FILE" "$terminal_sha") \
      || fail "recover-orphaned: identity карантина неполна/неоднозначна; файл оставлен без изменений" 1
    recovery_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["recovery_id"])' "$event_json") \
      || fail "recover-orphaned: recovery_id не вычислен" 1
    fields_json=$(python3 - "$recovery_id" "$terminal_sha" <<'PY'
import json
import sys
print(json.dumps({
    "recovery_version": "terminal-proof/v1",
    "recovery_id": sys.argv[1],
    "recovery_terminal_sha256": sys.argv[2],
}, separators=(",", ":")))
PY
    ) || fail "recover-orphaned: PREPARED receipt не сериализован" 1
    _append_close_fields_atomic "$ORPHAN_FILE" "$fields_json" \
      || fail "recover-orphaned: PREPARED receipt не записан; quarantine неизменен" 1
    snapshot_sha=$(_owned_semaphore_snapshot_sha "$ORPHAN_FILE" || true)
    [ -n "$snapshot_sha" ] \
      || fail "recover-orphaned: PREPARED snapshot не зафиксирован; quarantine остаётся на месте" 1
    _rename_owned_semaphore_cas "$ORPHAN_FILE" "$PENDING_ORPHAN_FILE" "$snapshot_sha" \
      || fail "recover-orphaned: не удалось перевести карантин в recovery-pending" 1
    ORPHAN_FILE="$PENDING_ORPHAN_FILE"
  else
    [ "$(_unique_record_field "$ORPHAN_FILE" recovery_version || true)" = "terminal-proof/v1" ] \
      || fail "recover-orphaned: pending/recovered state не имеет exact PREPARED receipt" 1
    terminal_sha=$(_unique_record_field "$ORPHAN_FILE" recovery_terminal_sha256 || true)
    stored_recovery_id=$(_unique_record_field "$ORPHAN_FILE" recovery_id || true)
    event_json=$(_recovery_identity_event "$ORPHAN_FILE" "$BASE_ORPHAN_FILE" "$terminal_sha") \
      || fail "recover-orphaned: pending identity/terminal digest повреждён" 1
    recovery_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["recovery_id"])' "$event_json") \
      || fail "recover-orphaned: pending recovery_id не вычислен" 1
    [ "$stored_recovery_id" = "$recovery_id" ] \
      || fail "recover-orphaned: pending recovery_id не связан с exact identity/proof" 1
  fi

  ledger_script="$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh"
  [ -f "$ledger_script" ] && [ ! -L "$ledger_script" ] \
    || fail "recover-orphaned: ledger-append.sh недоступен; recovery-pending сохранён для повтора" 1
  ledger_root="${IWE_LEDGER_DIR:-$IWE_ROOT/$GOV_REPO/machine/ledger}"
  if _recovery_event_in_ledger "$ledger_root" "$recovery_id"; then
    ledger_rc=0
  else
    ledger_rc=$?
    [ "$ledger_rc" -eq 1 ] \
      || fail "recover-orphaned: ledger нельзя надёжно проверить; recovery-pending сохранён" 1
    IWE_LEDGER_DIR="$ledger_root" bash "$ledger_script" day "$(now_date)" \
      session_recovered_closed "$event_json" session-guard 195>&- 196>&- \
      || fail "recover-orphaned: ledger append не завершён; recovery-pending сохранён для безопасного повтора" 1
    _recovery_event_in_ledger "$ledger_root" "$recovery_id" \
      || fail "recover-orphaned: ledger writer вернул успех без проверяемого recovery_id; recovery-pending сохранён" 1
  fi

  if [ "$ORPHAN_FILE" = "$RECOVERED_ORPHAN_FILE" ]; then
    echo "Recovered: $(basename "$BASE_ORPHAN_FILE") уже имеет подтверждённый terminal ledger event (idempotent retry)."
    return 0
  fi
  snapshot_sha=$(_owned_semaphore_snapshot_sha "$PENDING_ORPHAN_FILE" || true)
  [ -n "$snapshot_sha" ] \
    && _rename_owned_semaphore_cas "$PENDING_ORPHAN_FILE" "$RECOVERED_ORPHAN_FILE" "$snapshot_sha" \
    || fail "recover-orphaned: ledger подтверждён, но финальный rename не прошёл; recovery-pending сохранён для повтора" 1
  echo "Recovered: $(basename "$BASE_ORPHAN_FILE") — exact terminal proof и ledger recovery_id подтверждены; карантин помечен .recovered и не возвращён в .open."
}

if [ "$CMD" = "recover-orphaned" ]; then
  ORPHAN_ARG="${POSITIONAL[0]:-}"
  [ -z "$ORPHAN_ARG" ] && fail "recover-orphaned: missing path argument" 1
  case "$ORPHAN_ARG" in
    /*) ORPHAN_REQUEST="$ORPHAN_ARG" ;;
    *)  ORPHAN_REQUEST="$SESSION_DIR/$ORPHAN_ARG" ;;
  esac
  case "$ORPHAN_REQUEST" in
    *.recovery-pending) RAW_BASE_ORPHAN_FILE="${ORPHAN_REQUEST%.recovery-pending}" ;;
    *.recovered) RAW_BASE_ORPHAN_FILE="${ORPHAN_REQUEST%.recovered}" ;;
    *.orphaned-*) RAW_BASE_ORPHAN_FILE="$ORPHAN_REQUEST" ;;
    *) fail "recover-orphaned: ожидается карантинный суффикс .orphaned-*" 1 ;;
  esac
  BASE_ORPHAN_FILE=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.normpath(sys.argv[1])))' "$RAW_BASE_ORPHAN_FILE")
  PENDING_ORPHAN_FILE="${BASE_ORPHAN_FILE}.recovery-pending"
  RECOVERED_ORPHAN_FILE="${BASE_ORPHAN_FILE}.recovered"
  # Admission must stay fenced while the visible hold moves through pending
  # and while its exact ledger recovery_id is verified.  Pending is also read
  # by the unlocked admission/pre-commit scanners, so a crash retains the hold.
  acquire_scheduled_admission_lock
  ORPHAN_STATE_COUNT=0
  ORPHAN_FILE=""
  for ORPHAN_CANDIDATE in "$BASE_ORPHAN_FILE" "$PENDING_ORPHAN_FILE" "$RECOVERED_ORPHAN_FILE"; do
    if [ -e "$ORPHAN_CANDIDATE" ] || [ -L "$ORPHAN_CANDIDATE" ]; then
      ORPHAN_STATE_COUNT=$((ORPHAN_STATE_COUNT + 1))
      ORPHAN_FILE="$ORPHAN_CANDIDATE"
    fi
  done
  if [ "$ORPHAN_STATE_COUNT" -eq 0 ]; then
    fail "recover-orphaned: файл не найден: $ORPHAN_REQUEST" 1
  fi
  [ "$ORPHAN_STATE_COUNT" -eq 1 ] \
    || fail "recover-orphaned: найдено несколько состояний одного quarantine; ничего не перезаписываю" 1

  CANON_FILE=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ORPHAN_FILE")
  CANON_DIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SESSION_DIR")
  case "$CANON_FILE" in
    "$CANON_DIR"/*) : ;;
    *) fail "recover-orphaned: '$ORPHAN_FILE' вне каталога семафоров ($SESSION_DIR)" 1 ;;
  esac
  [ -L "$ORPHAN_FILE" ] \
    && fail "recover-orphaned: '$ORPHAN_FILE' — символическая ссылка, не карантинный файл" 1
  ORIGINAL_OPEN_FILE="${BASE_ORPHAN_FILE%%.orphaned-*}"
  acquire_session_transition_lock "$ORIGINAL_OPEN_FILE"
  _recover_orphaned_locked
  release_session_transition_lock \
    || fail "recover-orphaned: terminal state записан, но exact session lock не освободился" 1
  release_scheduled_admission_lock \
    || fail "recover-orphaned: terminal state записан, но admission lock не освободился" 1
  exit 0
fi

# A registered directory covers everything under it (QUICKCLOSE-GAPS1 п.2, found
# live 04.08): a peer-conversation opens ONE session directory and then writes a
# dozen files into it as the run goes on. Before this, every one of those files
# needed its own note-file call right before the commit -- 13 calls for a single
# session, and the gate blocked whatever was forgotten, even though `open` had
# already claimed that exact directory. A directory entry is stored with a
# trailing slash, so it can never be confused with a file of the same name.
_frozen_quarantine_commit_barrier() {  # <newline-separated ACTIVE semaphores>
  ACTIVE_SEMAPHORES="$1" python3 - "$SESSION_DIR" <<'PY'
import glob
import hashlib
import os
import re
import stat
import subprocess
import sys
import uuid

directory = sys.argv[1]
active_paths = [item for item in os.environ.get("ACTIVE_SEMAPHORES", "").splitlines() if item]

def snapshot(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_nlink != 1
            or info.st_size <= 0
            or info.st_size > 1024 * 1024
            or stat.S_ISLNK(current.st_mode)
            or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise ValueError("unsafe identity")
        raw = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk
    finally:
        os.close(fd)
    if len(raw) != info.st_size or b"\0" in raw or not raw.endswith(b"\n"):
        raise ValueError("malformed content")
    text = raw.decode("utf-8")
    verify_fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        verify = os.fstat(verify_fd)
        verify_path = os.lstat(path)
        verify_raw = b""
        while True:
            chunk = os.read(verify_fd, 65536)
            if not chunk:
                break
            verify_raw += chunk
        if (
            not stat.S_ISREG(verify.st_mode)
            or verify.st_uid != os.geteuid()
            or stat.S_ISLNK(verify_path.st_mode)
            or (verify.st_dev, verify.st_ino, verify.st_nlink, verify.st_size)
            != (info.st_dev, info.st_ino, 1, info.st_size)
            or (verify_path.st_dev, verify_path.st_ino) != (verify.st_dev, verify.st_ino)
            or hashlib.sha256(verify_raw).digest() != hashlib.sha256(raw).digest()
        ):
            raise ValueError("changed during scan")
    finally:
        os.close(verify_fd)
    return text

def unique(text, key, optional=False):
    prefix = key + ": "
    values = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
    if optional and not values:
        return ""
    if len(values) != 1 or not values[0]:
        raise ValueError("missing/duplicate " + key)
    return values[0]

active_wps = set()
for path in active_paths:
    try:
        text = snapshot(path)
        housekeeping_lines = [line for line in text.splitlines() if line.startswith("housekeeping:")]
        if housekeeping_lines:
            agent = unique(text, "agent")
            reason = unique(text, "housekeeping")
            session_lines = [line for line in text.splitlines() if line.startswith("session_id:")]
            if (
                unique(text, "slug") != reason
                or os.path.basename(path) != "%s-housekeeping-%s.open" % (agent, reason)
                or any(line.startswith("wp:") for line in text.splitlines())
                or any(line.startswith("scheduled_owner:") for line in text.splitlines())
                or len(session_lines) > 1
                or (session_lines and (not session_lines[0].startswith("session_id: ") or not session_lines[0][len("session_id: "):]))
            ):
                raise ValueError("malformed housekeeping")
            continue
        wp = unique(text, "wp").upper()
        if not re.fullmatch(r"WP-[1-9][0-9]*", wp):
            raise ValueError("bad active wp")
        active_wps.add(wp)
    except (OSError, UnicodeError, ValueError):
        print("cannot classify active semaphore while enforcing quarantine: " + path, file=sys.stderr)
        raise SystemExit(2)

staged_result = subprocess.run(
    ["git", "diff", "--cached", "--name-only", "-z", "--no-renames"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
if staged_result.returncode != 0:
    raise SystemExit(2)
staged = [item.decode("utf-8") for item in staged_result.stdout.split(b"\0") if item]

paths = set(glob.glob(os.path.join(directory, "*.open.orphaned-scheduled-drained")))
paths.update(glob.glob(os.path.join(directory, "*.open.orphaned-*.recovery-pending")))
for path in sorted(paths):
    try:
        text = snapshot(path)
        agent = unique(text, "agent")
        session = unique(text, "session_id")
        wp = unique(text, "wp").upper()
        if not re.fullmatch(r"WP-[1-9][0-9]*", wp):
            raise ValueError("bad wp")
        base = os.path.basename(path)
        if not base.startswith("%s-%s.open.orphaned-" % (agent, session)):
            raise ValueError("filename mismatch")
        if path.endswith(".orphaned-scheduled-drained"):
            parsed = uuid.UUID(session)
            if parsed.version != 4 or str(parsed) != session:
                raise ValueError("bad scheduled UUID")
            if unique(text, "scheduled_owner") != "wp-run-scheduled-tsekh1/v1":
                raise ValueError("bad scheduled owner")
            if unique(text, "scheduled_drain_proof") != "process-group-empty/v1":
                raise ValueError("bad scheduled proof")
        else:
            if unique(text, "recovery_version") != "terminal-proof/v1":
                raise ValueError("bad pending recovery receipt")
            if not re.fullmatch(r"[0-9a-f]{64}", unique(text, "recovery_id")):
                raise ValueError("bad recovery id")
            if not re.fullmatch(r"[0-9a-f]{64}", unique(text, "recovery_terminal_sha256")):
                raise ValueError("bad terminal digest")
        scope = []
        for line in text.splitlines():
            if not line.startswith("file: "):
                continue
            value = line[len("file: "):]
            if not value or value.startswith("/") or value == ".." or value.startswith("../"):
                raise ValueError("unsafe scope")
            scope.append(value)
    except (OSError, UnicodeError, ValueError):
        print("malformed frozen/pending quarantine blocks commit: " + path, file=sys.stderr)
        raise SystemExit(2)

    same_wp = wp in active_wps
    overlaps = any(
        staged_path == entry or (entry.endswith("/") and staged_path.startswith(entry))
        for staged_path in staged
        for entry in scope
    )
    if same_wp or overlaps or (staged and not scope):
        print("quarantine hold blocks commit: %s (WP=%s)" % (path, wp), file=sys.stderr)
        raise SystemExit(1)
PY
}

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

# A close keeps its session-transition lock while isolate-push cherry-picks
# the immutable PREPARED commit set into a disposable worktree.  The Git hook
# runs in another process and must not trust that inherited descriptor (nor an
# environment bypass): a caller can invoke the hook independently.  Instead,
# this narrow reader validates one PREPARED record from a single owned-file
# snapshot, binds the current disposable worktree to isolate-push's durable
# attempt passport, proves that the staged index is exactly the current source
# commit's tree delta, and then rechecks both immutable snapshots.  It grants
# only this invocation of session-guard's scope check; the surrounding Git
# hook continues with its other checks.
_prepared_isolate_push_hook_authorized() {  # <closing semaphore>
  local semaphore="$1" session_id
  session_id=$(_unique_record_field "$semaphore" session_id 2>/dev/null) || return 1
  [ -n "$session_id" ] || return 1
  python3 - "$semaphore" 3< <(
    _close_delivery_state "$semaphore" "$session_id" prepared-hook-json
  ) <<'PY' 2>/dev/null
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

semaphore = sys.argv[1]
try:
    with os.fdopen(3, "r", encoding="utf-8") as prepared_stream:
        prepared = json.load(prepared_stream)
except (OSError, ValueError):
    raise SystemExit(1)

required = {
    "state", "semaphore_sha256", "semaphore_dev", "semaphore_ino",
    "session_id", "worktree", "common_dir", "origin", "target_ref",
    "source_commits", "scope",
}
if set(prepared) != required or prepared["state"] != "prepared":
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{64}", prepared["semaphore_sha256"]):
    raise SystemExit(1)
if not isinstance(prepared["semaphore_dev"], int) or not isinstance(prepared["semaphore_ino"], int):
    raise SystemExit(1)
if not isinstance(prepared["session_id"], str) or not prepared["session_id"]:
    raise SystemExit(1)


def read_owned_snapshot(path, maximum=1024 * 1024, require_newline=True):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(descriptor)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_nlink != 1
            or info.st_size <= 0
            or info.st_size > maximum
            or stat.S_ISLNK(current.st_mode)
            or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise ValueError("unsafe owned snapshot")
        chunks = []
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
        if (
            len(raw) != info.st_size
            or b"\0" in raw
            or (require_newline and not raw.endswith(b"\n"))
        ):
            raise ValueError("invalid snapshot bytes")
        raw.decode("utf-8")
        return raw, info.st_dev, info.st_ino
    finally:
        os.close(descriptor)


def snapshot_matches(
    path, expected_raw, expected_dev, expected_ino,
    maximum=1024 * 1024, require_newline=True,
):
    try:
        raw, device, inode = read_owned_snapshot(path, maximum, require_newline)
    except (OSError, UnicodeDecodeError, ValueError):
        return False
    return raw == expected_raw and device == expected_dev and inode == expected_ino


try:
    semaphore_raw, semaphore_dev, semaphore_ino = read_owned_snapshot(semaphore)
except (OSError, UnicodeDecodeError, ValueError):
    raise SystemExit(1)
if (
    semaphore_dev != prepared["semaphore_dev"]
    or semaphore_ino != prepared["semaphore_ino"]
    or hashlib.sha256(semaphore_raw).hexdigest() != prepared["semaphore_sha256"]
):
    raise SystemExit(1)

source_worktree = prepared["worktree"]
common_dir = prepared["common_dir"]
origin = prepared["origin"]
source_commits = prepared["source_commits"]
scope = prepared["scope"]
if (
    not isinstance(source_worktree, str)
    or not os.path.isabs(source_worktree)
    or os.path.realpath(source_worktree) != source_worktree
    or not isinstance(common_dir, str)
    or not os.path.isabs(common_dir)
    or os.path.realpath(common_dir) != common_dir
    or not isinstance(origin, str)
    or not origin
    or prepared["target_ref"] != "refs/heads/main"
    or not isinstance(source_commits, list)
    or not source_commits
    or len(source_commits) != len(set(source_commits))
    or any(not isinstance(item, str) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", item) for item in source_commits)
    or not isinstance(scope, list)
    or not scope
    or len(scope) != len(set(scope))
):
    raise SystemExit(1)


def safe_scope_path(value):
    if not isinstance(value, str) or not value or "\0" in value or "\n" in value or os.path.isabs(value):
        return False
    candidate = value[:-1] if value.endswith("/") else value
    return bool(candidate) and all(part not in {"", ".", ".."} for part in candidate.split("/"))


if any(not safe_scope_path(value) for value in scope):
    raise SystemExit(1)


def git_bytes(*arguments, literal=False):
    command = ["git"]
    if literal:
        command.append("--literal-pathspecs")
    command.extend(["-C", current_worktree])
    command.extend(arguments)
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("git command failed")
    return result.stdout


try:
    current_reported = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if current_reported.returncode != 0:
        raise RuntimeError("not a worktree")
    current_worktree = os.path.realpath(current_reported.stdout.decode("utf-8").strip())
    attempt_id = os.path.basename(current_worktree)
    source_parent = os.path.dirname(source_worktree)
    expected_store = os.path.realpath(os.path.join(source_parent, ".isolate-push-tmp"))
    if (
        os.path.dirname(current_worktree) != expected_store
        or not re.fullmatch(r"attempt-[0-9]+-[0-9]+-[0-9a-fA-F]{8}", attempt_id)
        or os.path.basename(source_parent) != "isolated-worktrees"
    ):
        raise RuntimeError("not the prepared isolate-push attempt")

    actual_common_raw = git_bytes("rev-parse", "--git-common-dir").decode("utf-8").strip()
    if not os.path.isabs(actual_common_raw):
        actual_common_raw = os.path.join(current_worktree, actual_common_raw)
    if os.path.realpath(actual_common_raw) != common_dir:
        raise RuntimeError("wrong git common-dir")

    def normalize_remote(value):
        value = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", "", value)
        value = re.sub(r"^[^@/]*@", "", value)
        value = value.replace(":", "/", 1)
        return re.sub(r"\.git$", "", value)

    actual_origin = git_bytes("remote", "get-url", "origin").decode("utf-8").strip()
    if normalize_remote(actual_origin) != origin:
        raise RuntimeError("wrong origin")

    cherry_pick = git_bytes("rev-parse", "--verify", "CHERRY_PICK_HEAD^{commit}").decode("ascii").strip()
    if cherry_pick not in source_commits:
        raise RuntimeError("pick outside prepared commit set")

    registry = os.path.join(os.path.dirname(source_parent), "isolate-push-attempts")
    passport_path = os.path.join(registry, attempt_id + ".json")
    passport_raw, passport_dev, passport_ino = read_owned_snapshot(
        passport_path, 256 * 1024, False
    )
    passport = json.loads(passport_raw.decode("utf-8"))
    if (
        not isinstance(passport, dict)
        or passport.get("owner") != "isolate-push"
        or passport.get("attempt_id") != attempt_id
        or passport.get("status") != "active"
        or passport.get("target_branch") != "main"
        or passport.get("source_commits") != [cherry_pick]
        or not isinstance(passport.get("source_worktree"), str)
        or os.path.realpath(passport["source_worktree"]) != source_worktree
        or not isinstance(passport.get("worktree_path"), str)
        or os.path.realpath(passport["worktree_path"]) != current_worktree
    ):
        raise RuntimeError("attempt passport mismatch")

    staged_raw = git_bytes("diff", "--cached", "--name-only", "-z", "--no-renames", "HEAD")
    touched_raw = git_bytes("diff-tree", "--no-commit-id", "--name-only", "-z", "-r", "--no-renames", cherry_pick)
    staged = [item for item in staged_raw.split(b"\0") if item]
    touched = [item for item in touched_raw.split(b"\0") if item]
    if not staged or len(staged) != len(set(staged)) or set(staged) != set(touched):
        raise RuntimeError("staged path set differs from source commit")
    if git_bytes("diff", "--name-only", "-z"):
        raise RuntimeError("unstaged change in publish worktree")
    if git_bytes("ls-files", "--others", "--exclude-standard", "-z"):
        raise RuntimeError("untracked path in publish worktree")
    if git_bytes("ls-files", "--others", "--ignored", "--exclude-standard", "-z"):
        raise RuntimeError("ignored path in publish worktree")

    def in_scope(path):
        return any(path == entry or (entry.endswith("/") and path.startswith(entry)) for entry in scope)

    decoded_staged = [item.decode("utf-8") for item in staged]
    if any(not safe_scope_path(path) or not in_scope(path) for path in decoded_staged):
        raise RuntimeError("staged path outside immutable scope")

    def tree_entry(revision, raw_path):
        output = git_bytes("ls-tree", "-z", revision, "--", raw_path.decode("utf-8"), literal=True)
        if not output:
            return None
        records = [item for item in output.split(b"\0") if item]
        if len(records) != 1 or b"\t" not in records[0]:
            raise RuntimeError("ambiguous tree entry")
        metadata, returned_path = records[0].split(b"\t", 1)
        parts = metadata.split(b" ")
        if len(parts) != 3 or returned_path != raw_path:
            raise RuntimeError("tree entry path mismatch")
        return parts[0], parts[2]

    def index_entry(raw_path):
        output = git_bytes("ls-files", "--stage", "-z", "--", raw_path.decode("utf-8"), literal=True)
        if not output:
            return None
        records = [item for item in output.split(b"\0") if item]
        if len(records) != 1 or b"\t" not in records[0]:
            raise RuntimeError("ambiguous index entry")
        metadata, returned_path = records[0].split(b"\t", 1)
        parts = metadata.split(b" ")
        if len(parts) != 3 or parts[2] != b"0" or returned_path != raw_path:
            raise RuntimeError("index entry path mismatch")
        return parts[0], parts[1]

    for raw_path in staged:
        if index_entry(raw_path) != tree_entry(cherry_pick, raw_path):
            raise RuntimeError("index content differs from source commit")

    if not snapshot_matches(
        passport_path, passport_raw, passport_dev, passport_ino, 256 * 1024, False
    ):
        raise RuntimeError("attempt passport changed during decision")
    if not snapshot_matches(semaphore, semaphore_raw, semaphore_dev, semaphore_ino):
        raise RuntimeError("prepared semaphore changed during decision")
except (OSError, UnicodeDecodeError, ValueError, RuntimeError):
    raise SystemExit(1)
PY
}

# Sets ACTIVE/EXPIRED (newline-separated semaphore paths) from every *.open
# file under SESSION_DIR. Split out of pre-commit-check (WP-530 Ф22) because
# post-merge-check needs the same "who's currently allowed to write" list to
# decide whether an incoming merge stayed inside a session's declared scope.
list_active_semaphores() {
  ALL_OPEN=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  ACTIVE=""
  EXPIRED=""
  CLOSING=""
  for sem in $ALL_OPEN; do
    sem_agent=$(_unique_record_field "$sem" agent || true)
    sem_identity=""
    if [ -n "$sem_agent" ]; then
      sem_identity=$(_locked_open_identity "$sem" "$sem_agent" "" || true)
    fi
    sem_close_state="invalid"
    case "$sem_identity" in
      housekeeping:*) sem_close_state="none" ;;
      '') ;;
      *) sem_close_state=$(_close_delivery_state "$sem" "$sem_identity" || true) ;;
    esac
    if [ "$sem_close_state" != "none" ]; then
      # Invalid/ambiguous files and staged close transitions never grant
      # commit authority.  They remain visible in CLOSING so pre-commit can
      # fail closed instead of silently treating a malformed writer as active.
      CLOSING="${CLOSING}${sem}"$'\n'
    elif lease_valid "$sem"; then
      ACTIVE="${ACTIVE}${sem}"$'\n'
    else
      EXPIRED="${EXPIRED}${sem}"$'\n'
    fi
  done
  ACTIVE="${ACTIVE%$'\n'}"
  EXPIRED="${EXPIRED%$'\n'}"
  CLOSING="${CLOSING%$'\n'}"
}

# Emits a merge_scope_widened ledger event (WP-530 Ф22, observability-only --
# never blocks) for every path in $1 (newline-separated) that no ACTIVE
# semaphore declares. $2 is the commit-ish to record as the audit fingerprint
# (MERGE_HEAD sha for a resolved conflict, the merge commit's own sha for a
# clean/fast-forward merge picked up by post-merge-check).
emit_merge_scope_widened() {
  local paths="$1" fingerprint="$2" widened="" p
  list_active_semaphores
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    local found=0
    for sem in $ACTIVE; do
      scope_has_path "$sem" "$p" && { found=1; break; }
    done
    [ "$found" -eq 0 ] && widened="${widened}${p}"$'\n'
  done <<< "$paths"
  widened="${widened%$'\n'}"
  [ -z "$widened" ] && return 0
  [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ] || return 0
  # Observability must never be the thing that breaks a commit/merge under
  # `set -e` (this function runs inline inside pre-commit-check, whose own
  # caller does `... || exit $?`): a non-hex fingerprint or a python3 failure
  # (missing binary, non-UTF8 path from git diff -z) degrades to a still-
  # valid, still-informative ledger event instead of propagating.
  [[ "$fingerprint" =~ ^[0-9a-f]+$ ]] || fingerprint="unknown"
  local paths_json
  paths_json=$(printf '%s\n' "$widened" | python3 -c "import sys,json; print(json.dumps([l for l in sys.stdin.read().split(chr(10)) if l]))" 2>/dev/null) \
    || paths_json="[]"
  bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" merge_scope_widened \
    "{\"fingerprint\":\"$fingerprint\",\"paths\":$paths_json}" session-guard 2>/dev/null || true
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
  list_active_semaphores
  PREPARED_HOOK_AUTHORITY=""
  PREPARED_HOOK_AMBIGUOUS=0
  for sem in $CLOSING; do
    if _prepared_isolate_push_hook_authorized "$sem"; then
      if [ -n "$PREPARED_HOOK_AUTHORITY" ]; then
        PREPARED_HOOK_AMBIGUOUS=1
        break
      fi
      PREPARED_HOOK_AUTHORITY="$sem"
    fi
  done
  if _frozen_quarantine_commit_barrier "$ACTIVE"; then
    :
  else
    QUARANTINE_RC=$?
    case "$QUARANTINE_RC" in
      1) echo "🚫 SESSION-GUARD: коммит пересекает замороженную/ожидающую recovery сессию; formal recovery обязателен." >&2 ;;
      *) echo "🚫 SESSION-GUARD: quarantine hold неоднозначен или изменился во время проверки; fail closed." >&2 ;;
    esac
    exit 6
  fi
  if [ "$PREPARED_HOOK_AMBIGUOUS" -ne 0 ]; then
    echo "🚫 SESSION-GUARD: несколько PREPARED sessions претендуют на один isolate-push commit; fail closed." >&2
    exit 6
  fi
  if [ -n "$PREPARED_HOOK_AUTHORITY" ]; then
    echo "SESSION-GUARD: exact PREPARED isolate-push commit подтверждён ($(basename "$PREPARED_HOOK_AUTHORITY"))."
    exit 0
  fi

  # Check 6a (WP-539, peer-session 2026-08-18-08-wp539-tsekh1-sync): an active
  # session can register an isolated worktree and still
  # have its git commands run out of the canonical checkout by inertia (an
  # absolute path in a script, or cwd lost between separate Bash tool calls) --
  # `open` recording the worktree was never enough on its own, nothing checked
  # that later git operations actually executed there. Live-confirmed via git
  # reflog: two unpushed commits (WP-537, WP-484 sessions) landed straight in
  # the canonical checkout despite both semaphores naming a worktree.
  # Scope: only fires when at least one ACTIVE semaphore names a worktree
  # (`governance_worktree` under `.claude/worktrees/` or
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
      sem_dir=$(semaphore_governance_worktree "$sem" || true)
      [ -z "$sem_dir" ] && continue
      sem_toplevel="$sem_dir"
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

  # WP-545/WP-530 (2026-09-05): merge-aware scope. Was an unconditional
  # carve-out (any active merge skipped the entire scope gate -- exit 0
  # before the per-file loop). ArchGate WP-530 (Ф21, peer-session
  # 2026-09-05-17 with Kimi, cold-reviewed by Fable) narrows it: only paths
  # git's own merge actually brought in skip the check; a file the session
  # staged by hand during a stopped merge still goes through the normal
  # scope loop below (the old carve-out let that slide too -- found live as
  # a silent index/tree divergence risk on 05.09, same class the note-file
  # gate below exists to catch for ordinary files).
  #
  # Two stages, because .git/MERGE_HEAD does not exist yet at the
  # pre-merge-commit hook stage for a merge git can finish automatically
  # (verified live, git 2.50.1 -- same finding as .githooks/pre-commit's
  # Check 8):
  #   (i)  IWE_HOOK_IS_MERGE=1 (exported by .githooks/pre-merge-commit):
  #        this hook fires INSIDE the single `git merge` invocation, before
  #        control returns to the caller's shell -- there is no window for
  #        a manual `git add` to land between "git prepared the merge tree"
  #        and "this hook ran." The index already equals the merge result,
  #        so the merge set is simply everything staged vs HEAD.
  #   (ii) MERGE_HEAD present (merge stopped -- conflicts, or a caller ran
  #        `git merge --no-commit` -- resumed later via plain `git commit`,
  #        which this same pre-commit hook also guards): here the caller DID
  #        regain shell control, so the merge set is the intersection of
  #        "their side changed this path" (three-dot HEAD...MERGE_HEAD --
  #        two-dot is symmetric and would also match paths that changed only
  #        on OUR side) and "this path is actually staged differently from
  #        HEAD". A conflict resolved byte-for-byte back to HEAD produces no
  #        --cached diff and correctly drops out here; a file additionally
  #        hand-edited during the stopped merge stays in scope-gate
  #        territory below -- which is the point of the intersection.
  #        Known narrow gap: an octopus merge stores multiple parents under
  #        MERGE_HEAD, so `rev-parse --verify` fails to resolve a single rev
  #        and this branch does not fire -- fails safe (those paths fall
  #        through to the ordinary, stricter scope check), not a hole.
  MERGE_FILES=()
  if [ -n "${IWE_HOOK_IS_MERGE:-}" ]; then
    while IFS= read -r -d '' f; do MERGE_FILES+=("$f"); done \
      < <(git diff --cached --name-only -z --no-renames 2>/dev/null)
  elif git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    THEIR_SIDE=()
    while IFS= read -r -d '' f; do THEIR_SIDE+=("$f"); done \
      < <(git diff --name-only -z --no-renames HEAD...MERGE_HEAD 2>/dev/null)
    STAGED_VS_HEAD=()
    while IFS= read -r -d '' f; do STAGED_VS_HEAD+=("$f"); done \
      < <(git diff --cached --name-only -z --no-renames HEAD 2>/dev/null)
    # "${ARR[@]+"${ARR[@]}"}", not "${ARR[@]}": macOS ships bash 3.2 (GPLv3
    # freeze) where iterating a zero-length array under `set -u` is an
    # unbound-variable error, fixed only in bash 4.4+ (2016) -- same class
    # that live-crashed session-guard.sh close on 16.08 (bug-2026-08-16-
    # session-guard-close-bash32-empty-array-unbound.md), same fix already
    # applied elsewhere in this file for the same reason.
    for f in "${THEIR_SIDE[@]+"${THEIR_SIDE[@]}"}"; do
      for g in "${STAGED_VS_HEAD[@]+"${STAGED_VS_HEAD[@]}"}"; do
        if [ "$f" = "$g" ]; then
          MERGE_FILES+=("$f")
          break
        fi
      done
    done
    # Observability, not enforcement (WP-530 Ф22 ArchGate decision): record
    # which merge-brought paths land outside every active session's declared
    # scope, but never block on it -- blocking a merge resolution is exactly
    # the stuck-operation class this whole fix exists to remove.
    if [ "${#MERGE_FILES[@]}" -gt 0 ]; then
      emit_merge_scope_widened "$(printf '%s\n' "${MERGE_FILES[@]}")" "$(git rev-parse MERGE_HEAD)"
    fi
  fi

  is_merge_file() {
    local needle="$1" hay
    for hay in "${MERGE_FILES[@]+"${MERGE_FILES[@]}"}"; do
      [ "$hay" = "$needle" ] && return 0
    done
    return 1
  }

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

    if is_merge_file "$f"; then
      continue
    fi

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

# --- GIT POST-MERGE CHECK (WP-530 Ф22) ---
# Fast-forward and clean non-FF merges never reach pre-commit-check's own
# ledger emission (branch (ii) above only fires when MERGE_HEAD is on disk --
# a fast-forward moves HEAD without ever writing one, and a clean non-FF
# merge auto-commits through pre-merge-commit/IWE_HOOK_IS_MERGE before
# MERGE_HEAD would matter). This is the other half of the same
# observability contract, run from .githooks/post-merge. Never blocks --
# post-merge fires after the merge already succeeded, there is nothing left
# to gate.
if [ "$CMD" = "post-merge-check" ]; then
  RANGE_BASE=""
  if git rev-parse -q --verify ORIG_HEAD >/dev/null 2>&1 \
    && [ "$(git rev-parse ORIG_HEAD)" != "$(git rev-parse HEAD)" ]; then
    RANGE_BASE=$(git rev-parse ORIG_HEAD)
  elif git rev-parse -q --verify 'HEAD@{1}' >/dev/null 2>&1; then
    RANGE_BASE=$(git rev-parse 'HEAD@{1}')
  fi
  if [ -n "$RANGE_BASE" ]; then
    CHANGED=$(git diff --name-only -z --no-renames "$RANGE_BASE" HEAD 2>/dev/null | tr '\0' '\n')
    [ -n "$CHANGED" ] && emit_merge_scope_widened "$CHANGED" "$(git rev-parse HEAD)"
  fi
  exit 0
fi

fail "Unknown command: $CMD (use: open, close, audit, renew, note-file, note-commit, recover-orphaned, pre-commit-check, post-merge-check)"
