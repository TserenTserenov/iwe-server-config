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
#   close --abandon-prepared --i-understand-loss-risk # manual recovery (WP-484, peer-session
#         --source-commit <oid> [--source-commit ...] # with Codex): PREPARED tree-proof cannot
#                                                      # pass when a later legitimate REPLACE lands
#                                                      # on the same paths the snapshot touched —
#                                                      # this swaps the cryptographic proof for an
#                                                      # explicit, audited human attestation. Every
#                                                      # commit in close_delivery_source_commits
#                                                      # must be named via --source-commit, exactly
#                                                      # (partial confirmation refused); recorded
#                                                      # forever as close_publish_proof=
#                                                      # manual-abandon-attestation/v1, never as the
#                                                      # normal isolate-push proof.
#   audit [--since YYYY-MM-DD] [--cleanup-orphans [--quarantine-dead-interactive]]
#                                                      # --quarantine-dead-interactive (WP-530 Ф53):
#                                                      # opt-in terminal path for ordinary semaphores
#                                                      # whose owner pid is gone on this host, lease
#                                                      # expired and heartbeat stale -> renamed to
#                                                      # .open.orphaned-dead-interactive, evidence kept
#   renew [--wp WP-N] [--slug "..."] [--agent ...]    # продлить право на коммит
#   pre-commit-check
#   note-file <path> [--agent ...]
#   note-file --forget <path> [--agent ...]           # снять заявку на путь, которого нигде нет
#                                                      # (файл создан и удалён/переименован до
#                                                      # коммита); отказ, если путь есть на диске,
#                                                      # в HEAD/индексе или в заявленном коммите
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

# Peer session 2026-09-21-04-wp537-wp7-fmt-decisions-followup (Claude+Codex),
# WP-7 Ф161: every ancestry check this script's publish-proof path runs --
# `merge-base --is-ancestor` and friends (rev-list, cherry, patch-id) -- must
# be blind to local replacement refs and legacy grafts, or a prepared copy
# with a locally-replaced tip can make an undelivered commit look published.
# These two exports cover every plain `git` call below (the four subprocess
# blocks further down that explicitly rebuild os.environ already set
# GIT_NO_REPLACE_OBJECTS themselves and are unaffected by this; they still
# need GIT_GRAFT_FILE added individually, see those blocks).
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts

# P1(b), WP-484 п.19: several unsynced copies of this script exist on a given
# host at once (canonical, FMT-exocortex-template, iwe-local-config); when
# `open` writes a semaphore with one copy and `close` reads it with another,
# a mismatch in the field set they expect surfaces only indirectly -- as a
# generic "governance checkout не доказан" failure with no clue which script
# wrote what (the WP-573 incident, 14.09, took a multi-agent investigation to
# even locate). Stamping the writer's own schema version into every semaphore
# makes that skew directly greppable instead of requiring archaeology.
# Bump only when the semaphore's field set changes in a way `close` needs to
# know about (a new required field, a removed one) -- not on every edit here.
readonly GUARD_SCHEMA_VERSION=1

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
#
# WP-530 Ф56 (peer-session 2026-09-18-10, consensus Claude+Kimi+Codex, rounds
# 3-5): the `pwd` fallback below and gov_repo_dir()'s own canonical fallback
# disagreed on the exact same case -- cwd outside any git repo. A session
# opened that way (interactive `claude-code-...` semaphore, 2026-09-18 09:09,
# WP-484) sailed through this check (pwd never matches a frozen path) while
# `open` still wrote `governance_worktree: <canon>` from gov_repo_dir(), the
# one that decides the ACTUAL write target. Checking gov_repo_dir()'s result
# alone would close that gap but silently reopen a different one Codex found
# live-testing an `IWE_FROZEN_CANONICAL_PATH="$IWE_ROOT"` override: from cwd
# = $IWE_ROOT itself (a real git repo whose origin isn't DS-my-strategy's),
# gov_repo_dir() falls back to the DS-my-strategy canonical path, which is
# NOT in that override's frozen set, and the raw cwd (which IS the frozen
# path today) would never get checked at all. Kimi's residual worry -- could
# gov_repo_dir() return a path candidate #1 wouldn't already have seen? -- is
# closed by construction: every git-repo path gov_repo_dir() can return came
# from its own `git rev-parse --show-toplevel` of this same cwd, the exact
# call candidate #1 already makes; the only value it can add is its
# canonical-path fallback, never $IWE_ROOT or any other frozen path #1 missed.
# Checking both inside this one function -- not two independent call sites --
# keeps a single choke point while covering both real incidents.
frozen_checkout_match() {
  [ "${#FROZEN_CANONICAL_PATHS[@]}" -gt 0 ] || return 0
  local cwd_toplevel gov_candidate candidate real frozen frozen_real
  cwd_toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  gov_candidate="$(gov_repo_dir)"
  for candidate in "$cwd_toplevel" "$gov_candidate"; do
    [ -n "$candidate" ] || continue
    real=$(realpath "$candidate" 2>/dev/null || echo "$candidate")
    for frozen in "${FROZEN_CANONICAL_PATHS[@]}"; do
      frozen_real=$(realpath "$frozen" 2>/dev/null || echo "$frozen")
      if [ "$real" = "$frozen_real" ]; then
        echo "$candidate"
        return 0
      fi
    done
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

_runtime_harness_session_id() {  # <agent>; guard UUID and harness UUID are distinct identities
  local native="${CLAUDE_CODE_SESSION_ID:-}"
  [ "$1" != "codex" ] || native="${CODEX_THREAD_ID:-$native}"
  [ -n "$native" ] || return 0
  [[ "$native" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || return 1
  printf '%s\n' "$native"
}

_legacy_codex_harness_session_id() {  # <semaphore>; scoped compatibility for pre-native-ID opens
  python3 - "$1" <<'PY'
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

path = Path(sys.argv[1])
try:
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > 65536
            or path.resolve() != path.absolute()):
        raise ValueError("unsafe semaphore")
    lines = path.read_text().splitlines()

    def field(key):
        values = [line[len(key) + 2:] for line in lines if line.startswith(key + ": ")]
        if len(values) != 1 or not values[0]:
            raise ValueError("missing or ambiguous " + key)
        return values[0]

    if any(line.startswith("harness_session_id:") for line in lines):
        raise ValueError("stored harness identity cannot be replaced")
    native = os.environ.get("CODEX_THREAD_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", native):
        raise ValueError("native Codex identity is absent or malformed")
    if (field("agent") != "codex" or os.environ.get("IWE_AGENT") != "codex"
            or field("session_id") != os.environ.get("IWE_SESSION_ID")):
        raise ValueError("exact guard identity does not match caller")
    worktree = Path(field("governance_worktree"))
    actual = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                            check=True, capture_output=True, text=True, timeout=5).stdout.strip()
    if not worktree.is_absolute() or worktree.resolve() != Path(actual).resolve():
        raise ValueError("caller is outside the recorded worktree")
    print(native)
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    print("legacy Codex harness identity refused: " + str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
}

_declared_governance_card_dir() {  # <declared worktree> <canonical governance repo>
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import subprocess
import sys

def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True, text=True, timeout=5).stdout.strip()

try:
    candidate, canonical = map(Path, sys.argv[1:])
    if not candidate.is_absolute() or candidate.resolve() != candidate:
        raise ValueError("governance worktree must be an exact absolute path")
    if Path(git(candidate, "rev-parse", "--show-toplevel")) != candidate:
        raise ValueError("declared path is not a worktree root")
    common = (candidate / git(candidate, "rev-parse", "--git-common-dir")).resolve()
    expected = (canonical / git(canonical, "rev-parse", "--git-common-dir")).resolve()
    entries = git(canonical, "worktree", "list", "--porcelain", "-z").split("\0")
    if common != expected or entries.count("worktree " + str(candidate)) != 1:
        raise ValueError("declared worktree is not registered in the governance repository")
    print(candidate / "inbox" / "agent" / "tasks")
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    print("governance card route refused: " + str(exc), file=sys.stderr)
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
  # WP-538 Ф9 cold-review round 2 (Codex, 19.09): the compact sweep summary
  # tells the pilot to "search by pass key" in $ZOMBIE_REGISTRY, but nothing
  # ever wrote the pass key into a registry record -- recorded_at is a
  # SEPARATE, independently-computed timestamp (this function's own
  # dt.datetime.now() call), close to but not equal to the caller's
  # _SWEEP_PASS_KEY, so grepping for the pass key found nothing. pass_key is
  # optional (6th arg) so this function's own contract stays correct for any
  # future caller outside a sweep pass, same reasoning as _session_guard_notify's
  # queue-or-immediate fallback below.
  local reason="$1" semaphore="$2" opened_epoch="$3" age_seconds="$4" action="$5" pass_key="${6:-}"
  mkdir -p "$(dirname "$ZOMBIE_REGISTRY")"

  # The enclosing orphan-sweep lock makes check-then-append idempotent.
  python3 - "$ZOMBIE_REGISTRY" "$reason" "$semaphore" \
    "$opened_epoch" "$age_seconds" "$action" "$pass_key" <<'PY'
import datetime as dt
import json
import sys

path, reason, semaphore, opened_epoch, age_seconds, action, pass_key = sys.argv[1:]
event = {
    "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "reason": reason,
    "source": "session-guard.sh audit --cleanup-orphans",
    "semaphore": semaphore,
    "opened_epoch": int(opened_epoch),
    "age_seconds": int(age_seconds),
    "action": action,
    "pass_key": pass_key or None,
}
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

_SWEEP_NOTIFY_PENDING_FILE="$IWE_ROOT/.iwe-runtime/sweep-notify-pending.log"

# WP-538 Ф9 cold-review round 2 (Codex, 19.09): v2's pending file held one
# base64-opaque message per line -- a pass recovered on the NEXT run could
# only be counted as "some number of events", never broken down by
# type, because nothing said whether a recovered message was an escalation
# or a quarantine. One JSON record per line (matching $ZOMBIE_REGISTRY's own
# convention) carries that type alongside the semaphore and pass key,
# json.dumps already escapes embedded newlines so the file stays
# line-delimited the same way base64 did. A persistence failure stops this
# event before it reaches the in-memory queue: otherwise a later SIGKILL could
# still lose the only copy.
_sweep_notify_pending_append() {  # <message> <type> <semaphore> <pass key> <reason> <opened epoch> <age seconds> <action>
  if ! python3 - "$_SWEEP_NOTIFY_PENDING_FILE" "$1" "$2" "$3" "$4" \
    "${5:-}" "${6:-0}" "${7:-0}" "${8:-$2}" 2>/dev/null <<'PY'
import datetime as dt
import json
import os
import sys

path, message, type_, semaphore, pass_key, reason, opened_epoch, age_seconds, action = sys.argv[1:]
record = dict(
    recorded_at=dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    type=type_,
    semaphore=semaphore,
    pass_key=pass_key or None,
    message=message,
    reason=reason,
    opened_epoch=int(opened_epoch),
    age_seconds=int(age_seconds),
    action=action,
)
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    stream.flush()
    os.fsync(stream.fileno())
PY
  then
    echo "WARN: could not persist a queued sweep notification for crash recovery" >&2
    return 1
  fi
}

# WP-538 Ф9 cold-review (Codex, 19.09): the first version of this queue lost
# a notification permanently if the process died (or iwe-tg failed) between
# append_zombie_event marking an event "escalated"/quarantined and the flush
# at the end of the loop -- the dedup guard at each call site means a later
# pass never re-enters that code path for the same semaphore, so nothing
# would ever regenerate the lost message. This loads whatever a PRIOR pass
# persisted but never confirmed-delivered, before this pass resets/adds
# anything of its own -- the leftover rides along with (or becomes) this
# pass's summary. _sweep_flush_notify_queue only clears the file on confirmed
# delivery (tg_rc=0); an interruption or delivery failure leaves it for the
# next call to pick up again.
# Recovers both the message text (for the queue) and its type (for the
# _SWEEP_NOTIFY_*_COUNT breakdown below) from the JSON pending file in one
# python3 pass -- printing "type<TAB>base64(message)" keeps the bash side a
# plain read loop with no risk of a message's own newlines/tabs breaking the
# line format, and avoids spawning python3 once per pending line.
_sweep_notify_pending_load() {
  [ -s "$_SWEEP_NOTIFY_PENDING_FILE" ] || return 0
  local recovered type_ pass_key b64msg msg
  recovered=$(python3 - "$_SWEEP_NOTIFY_PENDING_FILE" "$ZOMBIE_REGISTRY" <<'PY'
import base64
import datetime as dt
import json
import os
import sys

pending_path, registry_path = sys.argv[1:]
known = set()
try:
    with open(registry_path, "r", encoding="utf-8") as stream:
        for line in stream:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            known.add((event.get("semaphore"), event.get("action")))
except FileNotFoundError:
    pass

with open(pending_path, "r", encoding="utf-8") as stream:
    records = [json.loads(line) for line in stream if line.strip()]

os.makedirs(os.path.dirname(registry_path), exist_ok=True)
seen = set()
with open(registry_path, "a", encoding="utf-8") as registry:
    for record in records:
        type_ = record.get("type", "")
        semaphore = record.get("semaphore", "")
        action = record.get("action") or type_
        dedup_key = (semaphore, action)
        if dedup_key in seen:
            continue
        seen.add(dedup_key)
        if dedup_key not in known:
            event = {
                "recorded_at": record.get("recorded_at")
                or dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                "reason": record.get("reason") or "recovered_pending_notification_without_original_audit",
                "source": "session-guard.sh audit --cleanup-orphans",
                "semaphore": semaphore,
                "opened_epoch": int(record.get("opened_epoch") or 0),
                "age_seconds": int(record.get("age_seconds") or 0),
                "action": action,
                "pass_key": record.get("pass_key"),
                "audit_recovered": True,
            }
            registry.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
            registry.flush()
            os.fsync(registry.fileno())
            known.add(dedup_key)
        message = str(record.get("message", ""))
        encoded = base64.b64encode(message.encode("utf-8")).decode("ascii")
        print(f"{type_}\t{record.get('pass_key') or ''}\t{encoded}")
PY
  ) || {
    echo "WARN: could not reconcile queued sweep notifications with $ZOMBIE_REGISTRY; retained for retry" >&2
    _SWEEP_NOTIFY_CAN_FLUSH=0
    return 0
  }
  while IFS=$'\t' read -r type_ pass_key b64msg; do
    [ -n "$b64msg" ] || continue
    msg=$(printf '%s' "$b64msg" | base64 -d 2>/dev/null) || continue
    _SWEEP_NOTIFY_QUEUE+=("$msg")
    [ -n "$pass_key" ] && _SWEEP_NOTIFY_PASS_KEYS+=("$pass_key")
    case "$type_" in
      escalated) _SWEEP_NOTIFY_ESCALATED_COUNT=$((_SWEEP_NOTIFY_ESCALATED_COUNT + 1)) ;;
      quarantined) _SWEEP_NOTIFY_QUARANTINED_COUNT=$((_SWEEP_NOTIFY_QUARANTINED_COUNT + 1)) ;;
    esac
  done <<< "$recovered"
}

_session_guard_notify() {  # <message> <semaphore> <type> <pass key> [reason opened_epoch age action]
  local msg="$1" semaphore="$2" type="$3" pass_key="$4"
  local reason="${5:-}" opened_epoch="${6:-0}" age_seconds="${7:-0}" action="${8:-$type}"
  # WP-538 Ф9 (19.09): a sweep pass queues into _SWEEP_NOTIFY_QUEUE instead
  # of sending here -- _sweep_flush_notify_queue sends the one summary after
  # the loop. Outside a sweep (array unset) this falls straight through to
  # immediate delivery, same as before Ф9 -- callers of this function only
  # exist inside the sweep today, but the fallback keeps the function correct
  # on its own contract rather than depending on that. type/pass_key are only
  # meaningful for the queued path (crash-recovery breakdown, round 2
  # cold-review) and are unused on the immediate-delivery fallback.
  if declare -p _SWEEP_NOTIFY_QUEUE >/dev/null 2>&1; then
    _sweep_notify_pending_append "$msg" "$type" "$semaphore" "$pass_key" \
      "$reason" "$opened_epoch" "$age_seconds" "$action"
    _SWEEP_NOTIFY_QUEUE+=("$msg")
    declare -p _SWEEP_NOTIFY_PASS_KEYS >/dev/null 2>&1 || _SWEEP_NOTIFY_PASS_KEYS=()
    [ -n "$pass_key" ] && _SWEEP_NOTIFY_PASS_KEYS+=("$pass_key")
    case "$type" in
      escalated) _SWEEP_NOTIFY_ESCALATED_COUNT=$((_SWEEP_NOTIFY_ESCALATED_COUNT + 1)) ;;
      quarantined) _SWEEP_NOTIFY_QUARANTINED_COUNT=$((_SWEEP_NOTIFY_QUARANTINED_COUNT + 1)) ;;
    esac
    return 0
  fi
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
      3) echo "WARN: session-guard alert quarantined by the allowlist gate (not delivered), only in log: $semaphore" >&2 ;;
      *) echo "WARN: iwe-tg failed (rc=$tg_rc), session-guard alert only in log: $semaphore" >&2 ;;
    esac
  else
    echo "INFO: iwe-tg unavailable, session-guard alert only in log: $semaphore" >&2
  fi
}

notify_zombie_escalation() {  # <semaphore> <age seconds> <pass key> <reason> <opened epoch>
  local semaphore="$1" age_seconds="$2" pass_key="$3" reason="$4" opened_epoch="$5"
  # Human text (WP-538 addressee policy, peer-session 2026-09-03-05): what
  # happened, who owns the next step, when it resolves on its own -- this is
  # a fully automatic transition (see the comment above ZOMBIE_REGISTRY), so
  # the pilot owns nothing here beyond "read if curious".
  local age_h=$(( age_seconds / 3600 ))
  _session_guard_notify "Осиротевшая сессия IWE: $(basename -- "$semaphore") уже ${age_h}ч не подтверждает, что за ней кто-то следит. Защитный барьер оставлен на месте: нужен точный terminal/drain proof или ручной разбор." \
    "$semaphore" "escalated" "$pass_key" "$reason" "$opened_epoch" "$age_seconds" "escalated"
}

# WP-530 Ф53 (2026-09-19, peer-session 2026-09-18-10 Claude+Kimi+Codex, ArchGate
# DRR-f53-single-writer-canon.md): the first terminal path for an ordinary
# (non-scheduled) interactive semaphore whose owner is gone. Before this phase
# `_classify_dead_semaphore` could only escalate: exact `close` needs a publish
# proof the dead owner never produced, and nothing else may touch `.open` --
# 46 such semaphores had accumulated on two hosts and every one of them kept
# fencing unrelated commits through pre-commit-check. Deliberately opt-in
# (`audit --cleanup-orphans --quarantine-dead-interactive`): existing callers
# (kimi-wp-run-scheduled.sh:86) keep the escalate-only behaviour until the
# review date in the DRR.
#
# Liveness proof, all four required, evaluated under the session transition
# lock the caller already holds: (1) the recorded pid no longer exists on THIS
# host -- a reused pid looks alive and therefore never quarantines, which is
# the safe direction; (2) the semaphore names this host, or predates the host
# field; (3) the commit lease has expired; (4) the last heartbeat, when one was
# ever recorded, is older than IWE_HEARTBEAT_STALE_SEC. This is a liveness
# proof only: the rename lifts fencing, it never claims the session's work was
# published -- the file body, its `.lease` and any worktree stay on disk for
# manual review, and the decision is appended to the zombie registry.
IWE_HEARTBEAT_STALE_SEC="${IWE_HEARTBEAT_STALE_SEC:-1800}"
# A non-numeric threshold would make `[ N -lt abc ]` return 2 and skip the
# "fresh heartbeat" refusal -- the one direction this proof must never fail in.
[[ "$IWE_HEARTBEAT_STALE_SEC" =~ ^[0-9]+$ ]] \
  || fail "IWE_HEARTBEAT_STALE_SEC должен быть целым числом секунд (получено: '$IWE_HEARTBEAT_STALE_SEC')" 1
DEAD_INTERACTIVE_SUFFIX=".orphaned-dead-interactive"

_semaphore_last_field() {  # <semaphore> <key>
  grep "^$2: " "$1" 2>/dev/null | tail -1 | cut -d' ' -f2- || true
}

_iso_to_epoch() {  # <ISO-8601 UTC>; prints nothing when unparseable
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null || true
}

_dead_interactive_refusal() {  # <semaphore> <reason>
  echo "INFO: $(basename -- "$1") not quarantined ($2); remains .open" >&2
}

_quarantine_dead_interactive() {  # <semaphore> <observed dead pid>
  local semaphore="$1" pid="$2"
  local host lease_deadline heartbeat_at heartbeat_epoch now snapshot destination epoch age worktree reason
  now=$(date +%s)
  if kill -0 "$pid" 2>/dev/null; then
    _dead_interactive_refusal "$semaphore" "pid $pid is alive again"; return 1
  fi
  host=$(_semaphore_last_field "$semaphore" host)
  if [ -n "$host" ] && [ "$host" != "$(hostname)" ]; then
    _dead_interactive_refusal "$semaphore" "recorded host $host is not $(hostname)"; return 1
  fi
  lease_deadline=$(lease_deadline_epoch "$semaphore") \
    || { _dead_interactive_refusal "$semaphore" "no parseable opened_at"; return 1; }
  if [ "$now" -lt "$lease_deadline" ]; then
    _dead_interactive_refusal "$semaphore" "lease still valid for $(( lease_deadline - now ))s"; return 1
  fi
  heartbeat_at=$(_semaphore_last_field "$semaphore" heartbeat_at)
  if [ -n "$heartbeat_at" ]; then
    heartbeat_epoch=$(_iso_to_epoch "$heartbeat_at")
    if [ -z "$heartbeat_epoch" ]; then
      _dead_interactive_refusal "$semaphore" "unparseable heartbeat_at $heartbeat_at"; return 1
    fi
    if [ $(( now - heartbeat_epoch )) -lt "$IWE_HEARTBEAT_STALE_SEC" ]; then
      _dead_interactive_refusal "$semaphore" "heartbeat $heartbeat_at is fresh"; return 1
    fi
  fi
  snapshot=$(_owned_semaphore_snapshot_sha "$semaphore" 0) \
    || { _dead_interactive_refusal "$semaphore" "no exclusive owned snapshot (close in progress or foreign file)"; return 1; }
  destination="${semaphore}${DEAD_INTERACTIVE_SUFFIX}"
  _rename_owned_semaphore_cas "$semaphore" "$destination" "$snapshot" \
    || { _dead_interactive_refusal "$semaphore" "CAS rename refused, file changed underneath"; return 1; }
  epoch=$(semaphore_epoch "$destination" || echo 0)
  age=$(( now - epoch ))
  [ "$age" -lt 0 ] && age=0
  # The rename is already terminal at this point; a registry failure must be
  # loud, not swallowed, but it cannot undo the transition.
  # The durable pending record is written before the audit record. If SIGKILL
  # lands between them, the next pass restores the missing audit from pending
  # before it scans *.open. That matters here because the quarantine rename
  # already removed this semaphore from the next scan.
  worktree=$(_semaphore_last_field "$destination" isolated_worktree)
  [ -n "$worktree" ] || worktree=$(_semaphore_last_field "$destination" governance_worktree)
  reason="dead_interactive_owner_proven:pid=$pid:lease_expired=$lease_deadline:heartbeat=${heartbeat_at:-absent}:snapshot=$snapshot"
  notify_dead_quarantine "$destination" "$age" "$worktree" "${_SWEEP_PASS_KEY:-}" \
    "$reason" "$semaphore" "$epoch"
  append_zombie_event \
    "$reason" \
    "$semaphore" "$epoch" "$age" "quarantined" "${_SWEEP_PASS_KEY:-}" \
    || {
      _SWEEP_NOTIFY_CAN_FLUSH=0
      echo "WARN: quarantine of $(basename -- "$semaphore") is done but not recorded in $ZOMBIE_REGISTRY; notification retained for retry" >&2
    }
  echo "QUARANTINED: $(basename -- "$semaphore") -> $(basename -- "$destination") (pid $pid dead, lease expired, heartbeat ${heartbeat_at:-absent}); worktree retained: ${worktree:-unknown}"
}

notify_dead_quarantine() {  # <quarantined path> <age> <worktree> <pass key> <reason> <original semaphore> <opened epoch>
  local age_h=$(( $2 / 3600 ))
  _session_guard_notify "Мёртвая сессия IWE переведена в карантин: $(basename -- "$1") (возраст ${age_h}ч; процесс-владелец не существует, аренда истекла, пульса нет). Барьер на коммиты снят, файл и улики сохранены. Незакоммиченная работа, если была, лежит в ${3:-неизвестной копии} — разобрать вручную." \
    "$6" "quarantined" "$4" "$5" "$7" "$2" "quarantined"
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

_cancel_dead_session_quick_close_runs() {  # <semaphore>
  # Ф42/Ф43 (2026-09-15, peer-session with Kimi, canon-sync-prevention):
  # the semaphore itself stays .open (dead-PID evidence is never fencing --
  # see the callers below), but any quick-close run this dead owner started
  # is orphaned right now, not at whatever later moment a foreign
  # `start quick-close` happens to hit reap_orphan_cards()'s admission-limit
  # trigger (process-runner.py, docstring on that function) or a human
  # notices the uncommitted RUN-quick-close-*.md card sitting in the canon
  # (31 of 57 dirty Mac paths were exactly this on 15.09). cancel-session
  # only cancels non-terminal cards it can prove belong to this session_id
  # -- it never touches the semaphore, so this stays exactly as
  # conservative as the escalation at each call site.
  local semaphore="$1" session_id runner
  session_id=$(grep '^session_id: ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [ -n "$session_id" ] || return 0
  runner="$IWE_ROOT/$GOV_REPO/scripts/process-runner.py"
  [ -f "$runner" ] || return 0
  (cd "$IWE_ROOT/$GOV_REPO" && python3 "$runner" cancel-session quick-close "$session_id") \
    2>&1 || echo "WARNING: cancel-session для мёртвой сессии $session_id не прошёл (не блокирует sweep)" >&2
}

_classify_pid_identity_mismatch() {  # <semaphore> <pid> <observed comm>
  # Ф43 (2026-09-15, peer-session with Kimi): `kill -0 $pid` only proves
  # SOME process holds this pid right now -- the pid-reuse case found live
  # yesterday (a claude-code semaphore's pid had been reassigned to an
  # unrelated `node` process, WP-484 close-proof-drift session) sailed
  # straight past the sweep loop's fast "alive, continue" path with no
  # escalation at all, because that path never checked WHICH process. This
  # is the same escalate-only contract as _classify_dead_semaphore right
  # below -- the semaphore stays .open, only a Telegram notice and (for the
  # non-scheduled case) an orphan-card sweep for this session_id happen
  # automatically.
  local semaphore="$1" pid="$2" observed_comm="$3" target epoch age
  [ -f "$semaphore" ] && [ ! -L "$semaphore" ] || return 0
  # Cold-review Critical/High (2026-09-15): the caller reads pid+comm BEFORE
  # taking the transition lock -- re-confirm both under the lock, the same
  # anti-TOCTOU discipline _classify_dead_semaphore already applies to its
  # own `kill -0` re-check right below. A resolved mismatch (pid rotated
  # again, or the semaphore already got closed) must not escalate on a
  # snapshot that is no longer true.
  pid=$(grep '^pid: ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  observed_comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  case "$observed_comm" in
    *claude*) return 0 ;;  # mismatch resolved (or pid died) since the snapshot
  esac

  # Same distinct class as _classify_dead_semaphore's scheduled_owner branch:
  # even proven identity mismatch on a scheduler-owned semaphore only freezes
  # after the exact drain contract, never cancels quick-close runs directly
  # (_freeze_scheduled_drained itself requires the pid to be truly dead, so a
  # live-but-wrong-process pid always fails that check and falls through to
  # escalate-only below -- structurally identical to the dead-PID sibling on
  # purpose, not copy-paste).
  if grep -q '^scheduled_owner:' "$semaphore" 2>/dev/null; then
    target="${semaphore}.orphaned-scheduled-drained"
    if _freeze_scheduled_drained "$semaphore" "$target"; then
      echo "WARNING: exact scheduled drain proven despite live pid $pid (identity mismatch, comm=$observed_comm); semaphore frozen, worktree retained" >&2
      _SWEEP_SCHEDULED_FROZEN=$((_SWEEP_SCHEDULED_FROZEN + 1))
      return 0
    fi
    epoch=$(semaphore_epoch "$semaphore" || echo 0)
    age=$(( $(date +%s) - epoch ))
    [ "$age" -lt 0 ] && age=0
    if ! zombie_registry_has_action "$semaphore" "escalated"; then
      # Notify-before-append (Codex round 2, 19.09) -- see the comment at
      # _quarantine_dead_interactive's call site for the SIGKILL-window
      # reasoning; identical fix, same call-order swap, at every classify site.
      notify_zombie_escalation "$semaphore" "$age" "${_SWEEP_PASS_KEY:-}" \
        "scheduled_owner_pid_identity_mismatch:${pid}:${observed_comm}" "$epoch"
      append_zombie_event "scheduled_owner_pid_identity_mismatch:${pid}:${observed_comm}" \
        "$semaphore" "$epoch" "$age" "escalated" "${_SWEEP_PASS_KEY:-}"
      _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    fi
    echo "WARNING: scheduled owner pid $pid is alive but comm ($observed_comm) does not match; exact drain proof absent; $(basename "$semaphore") remains .open" >&2
    _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
    return 0
  fi

  epoch=$(semaphore_epoch "$semaphore" || echo 0)
  age=$(( $(date +%s) - epoch ))
  [ "$age" -lt 0 ] && age=0
  # zombie_registry_has_action's dedup key is (semaphore, action) only, not
  # reason -- if this mismatch later resolves into a confirmed-dead pid
  # (_classify_dead_semaphore), that second escalation is silently skipped
  # (cold-review Medium, 2026-09-15). Not fixed here: pre-existing dedup
  # design, only newly reachable as a two-reason sequence by this patch.
  if ! zombie_registry_has_action "$semaphore" "escalated"; then
    notify_zombie_escalation "$semaphore" "$age" "${_SWEEP_PASS_KEY:-}" \
      "pid_identity_mismatch:${pid}:${observed_comm}" "$epoch"
    append_zombie_event "pid_identity_mismatch:${pid}:${observed_comm}" \
      "$semaphore" "$epoch" "$age" "escalated" "${_SWEEP_PASS_KEY:-}"
    _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    # Unlike _classify_dead_semaphore's generic branch (cold-review Critical,
    # 2026-09-15: cancelling there would be a NEW behavior on an existing,
    # already-tuned false-positive-prone path, reverted), a proven identity
    # mismatch is stronger evidence than a bare dead-PID check -- the kernel
    # would not have handed this pid to an unrelated process while the
    # original owner was still alive, so cancelling this session's orphaned
    # quick-close runs here is not a new risk class.
    _cancel_dead_session_quick_close_runs "$semaphore"
  fi
  echo "WARNING: pid $pid is alive but comm ($observed_comm) does not match the recorded owner; $(basename "$semaphore") remains .open, manual review required" >&2
  _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
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
      notify_zombie_escalation "$semaphore" "$age" "${_SWEEP_PASS_KEY:-}" \
        "scheduled_owner_without_exact_drain_proof" "$epoch"
      append_zombie_event "scheduled_owner_without_exact_drain_proof" \
        "$semaphore" "$epoch" "$age" "escalated" "${_SWEEP_PASS_KEY:-}"
      _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    fi
    echo "WARNING: scheduled owner pid $pid is dead, but exact drain proof is absent; $(basename "$semaphore") remains .open" >&2
    _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
    return 0
  fi

  # WP-530 Ф53: opt-in terminal path, proof and refusal reasons live in
  # _quarantine_dead_interactive; a refusal falls through to escalate-only.
  if [ "${QUARANTINE_DEAD_INTERACTIVE:-0}" = "1" ] \
    && _quarantine_dead_interactive "$semaphore" "$pid"; then
    _SWEEP_DEAD_QUARANTINED=$((_SWEEP_DEAD_QUARANTINED + 1))
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
    notify_zombie_escalation "$semaphore" "$age" "${_SWEEP_PASS_KEY:-}" \
      "dead_owner_without_terminal_or_drain_proof" "$epoch"
    append_zombie_event "dead_owner_without_terminal_or_drain_proof" \
      "$semaphore" "$epoch" "$age" "escalated" "${_SWEEP_PASS_KEY:-}"
    _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    # Cold-review Critical (2026-09-15): cancelling this session's quick-close
    # runs here (bare dead-PID, no terminal/scheduled-drain proof) would be a
    # NEW behavior change on an already-tuned false-positive-prone path, not
    # a refactor -- deliberately NOT wired up, unlike the pid-identity-
    # mismatch sibling below (_classify_pid_identity_mismatch), whose
    # evidence for death is strictly stronger (a live, unrelated process
    # holding the pid, not just kill -0 failing). This branch stays exactly
    # as conservative as before this patch: notify only, human decides.
  fi
  echo "WARNING: pid $pid is dead, but terminal/scheduled-drain proof is absent or changed; $(basename "$semaphore") remains .open" >&2
  _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
}

_sweep_orphaned_semaphores_body() {
  local semaphore pid epoch age agent comm
  _SWEEP_AMBIGUOUS=0
  _SWEEP_TERMINAL_REAPED=0
  _SWEEP_SCHEDULED_FROZEN=0
  _SWEEP_ZOMBIES_ESCALATED=0
  _SWEEP_DEAD_QUARANTINED=0
  # WP-538 Ф9 (19.09, Codex plan): one pass used to fire one Telegram message
  # per orphaned/quarantined semaphore -- a night with 26 stale sessions sent
  # 26 separate alerts. _session_guard_notify queues into this array instead
  # of sending immediately; _sweep_flush_notify_queue below sends ONE summary
  # after the loop. Per-semaphore detail is unaffected -- append_zombie_event
  # at each call site still writes the full record to ZOMBIE_REGISTRY
  # synchronously, during the loop, same as before this change.
  _SWEEP_NOTIFY_QUEUE=()
  # WP-538 Ф9 cold-review round 2 (Codex, 19.09): deliberately SEPARATE from
  # _SWEEP_ZOMBIES_ESCALATED/_SWEEP_DEAD_QUARANTINED above -- those two keep
  # meaning "fresh classifications this pass" for the plain-text "Semaphore
  # sweep: ..." line at the end of this function. These two count every
  # enqueue into _SWEEP_NOTIFY_QUEUE, fresh or recovered from a prior
  # interrupted pass, so the compact Telegram summary's type breakdown
  # (_sweep_flush_notify_queue) always sums to the queue length by
  # construction, including on a pass that recovers messages from a pass
  # that produced zero fresh classifications of its own.
  _SWEEP_NOTIFY_ESCALATED_COUNT=0
  _SWEEP_NOTIFY_QUARANTINED_COUNT=0
  _SWEEP_NOTIFY_PASS_KEYS=()
  _SWEEP_NOTIFY_CAN_FLUSH=1
  _SWEEP_PASS_KEY=$(date -u +%Y%m%dT%H%M%SZ)
  _sweep_notify_pending_load
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
        continue
      fi
      # Ф43 (2026-09-15): a live pid alone is not proof of the RIGHT owner --
      # PID reuse (dead original process, kernel hands the number to something
      # unrelated) sailed straight past this "alive, continue" path with no
      # escalation at all until a human noticed by hand (WP-484
      # close-proof-drift session, 15.09: a claude-code semaphore's pid had
      # been reassigned to an unrelated `node` process). Only agents that are
      # ever observed recording a numeric pid get checked -- currently only
      # claude-code (kimi/codex semaphores carry no pid field at all, see the
      # missing/invalid-pid branch below). `ps -o comm=` returns the full
      # binary path on macOS and a 15-char-truncated basename on Linux; a
      # substring match on "claude" is what's portable across both, and is
      # exactly the signal that caught yesterday's `node` mismatch. Depends
      # on Claude Code's current distribution shipping a binary/argv0 that
      # contains "claude" (verified live on both hosts, cold-review
      # 2026-09-15) -- a future distribution change (e.g. bare `node cli.js`)
      # would need this substring revisited, or every live session escalates.
      agent=$(grep '^agent: ' "$semaphore" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
      if [ "$agent" = "claude-code" ]; then
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        case "$comm" in
          *claude*) : ;;
          *)
            with_session_transition_lock "$semaphore" _classify_pid_identity_mismatch \
              "$semaphore" "$pid" "${comm:-<no such pid>}"
            ;;
        esac
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
      notify_zombie_escalation "$semaphore" "$age" "${_SWEEP_PASS_KEY:-}" \
        "missing_or_invalid_owner_pid" "$epoch"
      append_zombie_event "missing_or_invalid_owner_pid" "$semaphore" \
        "$epoch" "$age" "escalated" "${_SWEEP_PASS_KEY:-}"
      _SWEEP_ZOMBIES_ESCALATED=$((_SWEEP_ZOMBIES_ESCALATED + 1))
    fi

    if [ "$age" -gt 1800 ]; then
      echo "WARNING: semaphore $(basename "$semaphore") is ${age}s old without owner PID; age cannot fence a writer, kept .open for manual review" >&2
      _SWEEP_AMBIGUOUS=$((_SWEEP_AMBIGUOUS + 1))
    fi
  done < <(find "$SESSION_DIR" -name '*.open' -type f 2>/dev/null)
  _sweep_flush_notify_queue
  # WP-538 Ф9 cold-review (Codex, 19.09): the array is global-scope by design
  # (same as the other _SWEEP_* counters, read by the caller after this
  # function returns) -- left declared after this pass, it silently
  # swallowed any LATER, non-sweep call to _session_guard_notify in the same
  # process into a queue nothing would ever flush again. Unsetting it here
  # restores "not inside a sweep -> deliver immediately" for every call site
  # after this point, regardless of what this pass queued or sent.
  unset _SWEEP_NOTIFY_QUEUE
  unset _SWEEP_NOTIFY_PASS_KEYS
  echo "Semaphore sweep: terminal_reaped=$_SWEEP_TERMINAL_REAPED scheduled_frozen=$_SWEEP_SCHEDULED_FROZEN dead_quarantined=$_SWEEP_DEAD_QUARANTINED ambiguous=$_SWEEP_AMBIGUOUS zombies_escalated=$_SWEEP_ZOMBIES_ESCALATED"
}

# WP-538 Ф9 (19.09): sends the _SWEEP_NOTIFY_QUEUE collected by
# _session_guard_notify during this sweep pass as ONE Telegram message
# instead of one per semaphore. Below _SWEEP_QUARANTINE_SUMMARY_THRESHOLD
# items the original per-semaphore messages are reused verbatim (each
# already carries the WHY and the "разобрать вручную" caution -- quarantine
# is never implied to mean the work was published) so a normal, small pass
# reads exactly as before, just merged into one delivery. Above the
# threshold only counts + a pointer to ZOMBIE_REGISTRY are sent -- the
# per-semaphore append_zombie_event record made during the loop is already
# the detailed account, repeating all of it inline would make the one
# message as noisy as the many it replaces.
_SWEEP_QUARANTINE_SUMMARY_THRESHOLD=5

_sweep_flush_notify_queue() {
  local total=${#_SWEEP_NOTIFY_QUEUE[@]}
  [ "$total" -gt 0 ] || return 0
  if [ "${_SWEEP_NOTIFY_CAN_FLUSH:-1}" != "1" ]; then
    echo "WARN: sweep summary retained because its audit record is not durable yet" >&2
    return 0
  fi
  local summary unique_pass_keys pass_key_count pass_scope admission_digest admission_key
  unique_pass_keys=$(printf '%s\n' "${_SWEEP_NOTIFY_PASS_KEYS[@]}" | awk 'NF && !seen[$0]++')
  pass_key_count=$(printf '%s\n' "$unique_pass_keys" | awk 'NF { count++ } END { print count+0 }')
  if [ "$pass_key_count" -eq 1 ]; then
    pass_scope="за проход $unique_pass_keys"
  elif [ "$pass_key_count" -gt 1 ]; then
    pass_scope="из $pass_key_count проходов (ключи: $(printf '%s\n' "$unique_pass_keys" | awk 'BEGIN { sep="" } { printf "%s%s", sep, $0; sep=", " }'))"
  else
    pass_scope="за проход $_SWEEP_PASS_KEY"
  fi
  admission_digest=$(printf '%s\n' "${unique_pass_keys:-$_SWEEP_PASS_KEY}" | python3 -c '
import hashlib
import sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])
')
  admission_key="unexpected:session-guard:sweep-$admission_digest"
  if [ "$total" -le "$_SWEEP_QUARANTINE_SUMMARY_THRESHOLD" ]; then
    summary=$(printf '🔔 Сторож сессий: %d событий %s\n\n%s' \
      "$total" "$pass_scope" "$(printf '%s\n\n' "${_SWEEP_NOTIFY_QUEUE[@]}")")
  else
    # WP-538 Ф9 cold-review (Codex, 19.09): a bare count + "see the registry"
    # gave no way to find which registry entries belong to THIS pass, or
    # even whether it was mostly escalations or mostly quarantines.
    # Round 2 (Codex, 19.09): the first version read this breakdown from
    # _SWEEP_ZOMBIES_ESCALATED/_SWEEP_DEAD_QUARANTINED, which only count
    # FRESH classifications made during this pass -- a pass that recovers a
    # prior pass's undelivered queue (_sweep_notify_pending_load) showed
    # "6 событий ... осиротевшие: 0, в карантине: 0", accurate for nothing
    # new but silently wrong for the 6 it actually just sent. The dedicated
    # _SWEEP_NOTIFY_*_COUNT counters increment on every enqueue regardless of
    # origin (see their init comment above), so this breakdown always sums
    # to $total. The registry now also carries each record's own pass_key
    # (append_zombie_event), so "ищи по ключу прохода" is an actual grep,
    # not just a suggestion with nothing to match against.
    summary="🔔 Сторож сессий: $total событий $pass_scope (осиротевшие: $_SWEEP_NOTIFY_ESCALATED_COUNT, в карантине: $_SWEEP_NOTIFY_QUARANTINED_COUNT). Карантин не значит, что незакоммиченная работа этих сессий опубликована — каждая требует отдельного разбора. Подробности каждой — в $ZOMBIE_REGISTRY, ищи по указанному ключу прохода."
  fi
  if command -v iwe-tg >/dev/null 2>&1; then
    local tg_rc=0
    iwe-tg --source session-guard --admission-key "$admission_key" "$summary" || tg_rc=$?
    case "$tg_rc" in
      # WP-538 Ф9 cold-review (Codex, 19.09): only a CONFIRMED delivery
      # clears the crash-recovery file -- a quarantine or transport failure
      # must leave it in place so the next pass's _sweep_notify_pending_load
      # picks these same messages back up, instead of losing them the way
      # the first version of this queue did.
      0) rm -f "$_SWEEP_NOTIFY_PENDING_FILE" ;;
      3) echo "WARN: sweep summary quarantined by the allowlist gate (not delivered), $total events only in log/registry, retained for retry on the next pass" >&2 ;;
      *) echo "WARN: iwe-tg failed (rc=$tg_rc), sweep summary only in log/registry, retained for retry on the next pass" >&2 ;;
    esac
  else
    echo "INFO: iwe-tg unavailable, sweep summary only in log/registry, retained for retry on the next pass" >&2
  fi
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
QUARANTINE_DEAD_INTERACTIVE=0
FORCE_NO_REFLECTION=""
CANONICAL_OWNER=""
FORCE_FLAG=0
FORGET_FLAG=0
UNFREEZE_REASON=""
ISOLATE_FLAG=0
ABANDON_PREPARED=0
ABANDON_ACK=0
ABANDON_SOURCE_COMMITS=()
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
    --quarantine-dead-interactive) QUARANTINE_DEAD_INTERACTIVE=1; shift ;;
    --force)  FORCE_FLAG=1; shift ;;
    --forget) FORGET_FLAG=1; shift ;;
    --isolate) ISOLATE_FLAG=1; shift ;;
    # WP-484 (peer-session with Codex): manual recovery for a PREPARED close
    # snapshot whose tree-proof can never pass (a later legitimate REPLACE on
    # the same paths, not a lost commit) -- see header doc and
    # _record_close_abandoned. Three separate flags, not one combined switch,
    # so a caller cannot trigger the bypass by supplying only one of them
    # (WP-7 Ф83: no flag silently ignored -- each is validated independently
    # below).
    --abandon-prepared) ABANDON_PREPARED=1; shift ;;
    --i-understand-loss-risk) ABANDON_ACK=1; shift ;;
    --source-commit)
      if [[ $# -lt 2 || -z "$2" ]]; then
        fail "--source-commit требует непустое значение (SHA из close_delivery_source_commits)" 1
      fi
      ABANDON_SOURCE_COMMITS+=("$2"); shift 2 ;;
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

# WP-530 Ф53: the quarantine flag is meaningless anywhere else; refusing keeps
# the WP-7 Ф83 contract (no flag is ever silently ignored).
if [ "$QUARANTINE_DEAD_INTERACTIVE" -eq 1 ] && { [ "$CMD" != "audit" ] || [ "$CLEANUP_ORPHANS" -ne 1 ]; }; then
  fail "--quarantine-dead-interactive применим только к audit --cleanup-orphans" 1
fi

# --isolate and --canonical-owner are two different classes of session
# (interactive-writer-gets-its-own-copy vs. scheduled-job-owns-the-canonical-
# checkout-by-schedule) -- combining them silently would leave it ambiguous
# which one wins. Peer-session 2026-08-14-13-wp520-two-layer-closing-arch,
# consensus turn 3 (Codex): reject both together explicitly.
if [ "$ISOLATE_FLAG" = "1" ] && [ -n "$CANONICAL_OWNER" ]; then
  fail "--isolate и --canonical-owner взаимоисключающие: планировщик владеет каноническим чекаутом по расписанию (--canonical-owner), интерактивная сессия получает свою изолированную копию (--isolate) -- не оба сразу" 1
fi

# --abandon-prepared -- each of the three flags is meaningless alone, and the
# combined effect (skip cryptographic delivery proof) is deliberately not
# reachable by one flag on its own (see the flag's own comment above).
if [ "$ABANDON_PREPARED" -eq 1 ] && [ "$CMD" != "close" ]; then
  fail "--abandon-prepared применим только к close" 1
fi
if [ "$ABANDON_PREPARED" -eq 1 ] && [ "$ABANDON_ACK" -ne 1 ]; then
  fail "--abandon-prepared требует --i-understand-loss-risk: команда закрывает PREPARED-снимок БЕЗ криптографического доказательства доставки, под ответственность вызывающего" 1
fi
if [ "$ABANDON_PREPARED" -eq 1 ] && [ "${#ABANDON_SOURCE_COMMITS[@]}" -eq 0 ]; then
  fail "--abandon-prepared требует хотя бы один --source-commit <oid> -- список коммитов, доставку которых подтверждает оператор" 1
fi
if [ "$ABANDON_ACK" -eq 1 ] && [ "$ABANDON_PREPARED" -ne 1 ]; then
  fail "--i-understand-loss-risk без --abandon-prepared не имеет смысла" 1
fi
if [ "${#ABANDON_SOURCE_COMMITS[@]}" -gt 0 ] && [ "$ABANDON_PREPARED" -ne 1 ]; then
  fail "--source-commit применим только вместе с --abandon-prepared" 1
fi
if [ "$ABANDON_PREPARED" -eq 1 ] && [ -n "$HOUSEKEEPING" ]; then
  fail "--abandon-prepared несовместим с --housekeeping (housekeeping-сессии не пишут PREPARED-снимок)" 1
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

    # WP-7 Ф154 (2026-09-17): 4th live occurrence of the same mis-isolation
    # class as WP-484 Ф104 (silent repo substitution, fixed) and Ф140 (this
    # printf above, added so a wrong resolution would at least be visible).
    # Both incidents since (2026-08-25, 2026-09-17) show a human-readable
    # line is not enough under load -- the caller reads a wall of other
    # output and still misses it. This turns the same signal into a
    # structural check instead of a line to notice: when --wp is given and
    # the resolved repo looks like a governance repo (top-level inbox/),
    # its registered WP folder/file must actually be there, or open refuses
    # instead of silently isolating the wrong repo.
    #
    # Cold review (same phase) caught a false-positive before deploy: --wp
    # is documented and actually used bare-number, no "WP-" prefix (e.g.
    # `--wp 149` in inbox/bugs/blocker-2026-07-27-session-guard-stat-f-linux.md,
    # `--wp 289` in MC-sessions/2026-08/2026-08-09-wp289-actualize-closability.md)
    # alongside the "WP-N" form this session used. Check both spellings
    # instead of assuming the caller always types the prefix.
    if [ -n "$WP" ] && [ -d "$ISOLATE_BASE_DIR/inbox" ] && [ "$FORCE_FLAG" != "1" ]; then
      case "$WP" in
        WP-*) WP_INBOX_ALT="$WP" ;;
        *)    WP_INBOX_ALT="WP-$WP" ;;
      esac
      if [ ! -e "$ISOLATE_BASE_DIR/inbox/$WP" ] && [ ! -e "$ISOLATE_BASE_DIR/inbox/$WP.md" ] \
        && [ ! -e "$ISOLATE_BASE_DIR/inbox/$WP_INBOX_ALT" ] && [ ! -e "$ISOLATE_BASE_DIR/inbox/$WP_INBOX_ALT.md" ]; then
        if [ "$WP_INBOX_ALT" = "$WP" ]; then
          WP_INBOX_TRIED="inbox/$WP"
        else
          WP_INBOX_TRIED="inbox/$WP (и inbox/$WP_INBOX_ALT)"
        fi
        fail "--isolate: резолвнутый репозиторий ($ISOLATE_BASE_DIR) похож на governance-репо (есть inbox/), но $WP_INBOX_TRIED там нет -- open вызван не из того репозитория (cd в него перед --isolate). Если WP осознанно размещается не здесь (например, только что создаётся) -- повтори с --force." 1
      fi
    fi

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

    # Store and print the physical path. On macOS, mktemp commonly returns
    # /var/... while Git reports the same checkout as /private/var/.... A raw
    # spelling in the semaphore later made close compare one checkout as two
    # different governance worktrees and fail before publication.
    ISOLATED_WORKTREE_PATH=$(realpath "$ISOLATED_WORKTREE_PATH" 2>/dev/null) \
      || fail "--isolate: созданный worktree не удалось канонизировать" 1

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
  OPEN_HARNESS_SESSION_ID=$(_runtime_harness_session_id "$AGENT") \
    || fail "open: native harness session id is malformed" 1
  REUSE_EXISTING_SEMAPHORE=0
  if [ -e "$SEM_FILE" ] || [ -L "$SEM_FILE" ]; then
    _open_reentry_matches "$SEM_FILE" "$AGENT" "$SESSION_ID" "$WP" "${SLUG:-$WP}" \
      "$PERSONALITY" "${CLOSE_PATH:-unknown}" "${ISOLATED_WORKTREE_PATH:-$CURRENT_REPO_DIR}" \
      "${ISOLATED_WORKTREE_PATH:-}" "${ISOLATED_WORKTREE_BRANCH:-}" "$SCHEDULED_OWNER" \
      "$SCHEDULED_RUN_ID" "$EFFECTIVE_OWNER_PID" "$OPEN_HARNESS_SESSION_ID" \
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
    echo "guard_schema: $GUARD_SCHEMA_VERSION"
    # WP-484 Ф101 Находка 1: PostToolUse hooks (post-tool-use-scope-track.sh)
    # only see this env var, never WP/slug -- those are known only to the
    # code calling `open`, not to a hook firing on every later Write/Edit.
    # Recording it here lets the hook match its own semaphore by session
    # instead of a singleton current-<agent>.ptr that gets clobbered by a
    # second concurrent `open` of the same agent.
    [ -n "$OPEN_HARNESS_SESSION_ID" ] && echo "harness_session_id: $OPEN_HARNESS_SESSION_ID"
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
    # WP-530 Ф53: host + process start time let a sweep distinguish "this
    # host's pid is gone" from "another host's pid" and, in the next phase, a
    # reused pid from the original owner. Informational for today's readers.
    echo "host: $(hostname)"
    if [ -n "${OWNER_PID:-${CLAUDE_PID:-}}" ]; then
      OWNER_PID_START=$(ps -p "${OWNER_PID:-$CLAUDE_PID}" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//' || true)
      [ -n "$OWNER_PID_START" ] && echo "pid_start: $OWNER_PID_START"
    fi
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
    # WP-484 (16.09, peer-session 2026-09-16-28-wp484-close-gate-triage):
    # `orz_sessions_dir:` above is written unconditionally in this same block,
    # yet a live semaphore missing it anyway was observed the same evening --
    # cause not found (not a blocker for this fix; flagged in the session's
    # own carta for a dedicated follow-up). Whatever the cause, a semaphore
    # silently missing this field is undetectable at `open` time today and
    # only surfaces hours later as a `close` refusal nobody can explain from
    # the semaphore alone. Fail loudly here instead, before the caller is
    # ever told `open` succeeded -- nothing external depends on this session
    # yet, so refusing now is safe where refusing at `close` time is not.
    # `.+` after the colon (Kimi cold-review, same session): a present-but-
    # empty value would pass a bare presence check and only fail later, at
    # `close`, when resolve_orz_sessions_dir()'s fallback also comes back
    # empty -- the whole point of this check is catching that at `open`.
    grep -qE '^orz_sessions_dir: .+' "$SEM_FILE" \
      || fail "open: опубликованный semaphore не содержит orz_sessions_dir (внутренняя ошибка записи, см. РП484 16.09) -- сессия не считается открытой" 1
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
  local runner_owner runner_wp runner_slug
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
        # The runner persists this step BEFORE invoking close. Its own journal
        # cannot be clean yet; accept only the same owned release proof that
        # the terminal gate below validates. Every ordinary artifact stays strict.
        runner_owner=$(_unique_record_field "$semaphore" harness_session_id || true)
        [ -n "$runner_owner" ] || runner_owner=$(_unique_record_field "$semaphore" session_id || true)
        runner_wp=$(_unique_record_field "$semaphore" wp || true)
        runner_slug=$(_unique_record_field "$semaphore" slug || true)
        if _terminal_card_snapshot_sha "$runner_card" release-step \
          "$runner_owner" "$runner_wp" "$runner_slug" >/dev/null; then
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

_repo_scope_has_publish_proof() {  # <repo> <role> <exact semaphore> <fresh remote OID> <own field> <other field> [<legacy own>] [<legacy other>]
  # Shared canonical HEAD also includes neighbouring sessions.  Their history
  # cannot vouch for (or prevent delivery of) our registered output.  This
  # fallback requires current exact trees, never a historical blob/patch match.
  #
  # <own field>/<other field> (WP-484, 16.09, peer-session
  # 2026-09-16-22-wp484-close-mechanism-hard-snapshot, Claude+Kimi):
  # parameterized from a governance-only function -- the caller names which
  # semaphore field identifies THIS repo (own field) and which identifies the
  # sibling scope repo (other field), so the same scope-check now serves both
  # the governance checkout (own=governance_worktree, other=orz_sessions_dir)
  # and the sessions checkout (own=orz_sessions_dir, other=governance_worktree,
  # "находка 1" from the FMT orz_sessions_dir patch session earlier the same
  # day).
  #
  # <legacy own>, <legacy other> (WP-484, peer-session 2026-09-14-13,
  # Claude+Kimi+Codex): both set ONLY by the caller's own structural-absence
  # check (all three of governance_worktree/isolated_worktree/orz_sessions_dir
  # missing from the semaphore, see _close_delivery_and_transition) -- never
  # read from the semaphore file itself. A legacy semaphore, by definition,
  # cannot name either of its own scope checkouts; without the other one too,
  # every legacy semaphore refuses on its own ORZ scaffold file (which `open`
  # always registers in scope) even once one side is fixed -- found live
  # testing this same phase's D scenario: fixing governance alone still
  # refused with "путь отсутствует или неоднозначен между репозиториями" on
  # the ORZ path.
  # Pass definitions from this loaded guard, never source/execute the guard CLI
  # recursively. Resolution is lazy: known scope paths keep their old checks.
  local scope_resolver_functions
  scope_resolver_functions=$(declare -f normalize_remote_url _resolve_repo_checkout 2>/dev/null) || scope_resolver_functions=""
  python3 - "$@" "$IWE_ROOT" "$scope_resolver_functions" <<'PY'
import difflib
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys

repo, role, semaphore, remote, own_field, other_field, legacy_own, legacy_other, iwe_root, resolver_functions = sys.argv[1:]

def refuse(message):
    raise SystemExit("Session CLOSE: scoped publish proof: " + message)

def git_at(checkout, *args):
    result = subprocess.run(
        ["git", "--literal-pathspecs", "-C", checkout, *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )
    if result.returncode:
        refuse("проверка Git не выполнена")
    return result.stdout

def git(*args):
    return git_at(repo, *args)

info = os.lstat(semaphore)
if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
    refuse("небезопасный semaphore")
snapshot = Path(semaphore).read_bytes()
lines = snapshot.decode("utf-8").splitlines()
own_prefix = own_field + ": "
own_matches = [line[len(own_prefix):] for line in lines if line.startswith(own_prefix)]
if len(own_matches) == 1:
    if os.path.realpath(own_matches[0]) != os.path.realpath(repo):
        refuse(role + " не связан с точным semaphore")
elif not own_matches and legacy_own:
    # WP-484 (17.09, own-field mirror of the other_field fallback below --
    # peer-session 2026-09-17-02-own-field-mirror-fix, Claude+Codex): the
    # other_field branch a few lines down was already narrowed from
    # "structurally legacy" (all three scope fields absent) to "this one
    # field absent" (16.09, находка 1). This own_field branch kept the old,
    # wider-refusing condition -- a semaphore missing ONLY own_field (e.g.
    # governance_worktree present, orz_sessions_dir absent) is not
    # "structurally legacy" and fell straight to the refusal below with no
    # fallback at all, live-reproduced closing the 16.09 session that fixed
    # other_field. Trust boundary is unchanged from before: `legacy_own` is
    # still only ever the caller's own independently-resolved value, never
    # read from the semaphore text -- only the CONDITION for consulting it
    # widened, from "all three fields absent" to "this specific field
    # absent". `len(own_matches) > 1` still falls through to the refusal
    # below unchanged (this branch only matches an empty list).
    if os.path.realpath(legacy_own) != os.path.realpath(repo):
        refuse("legacy " + role + " не совпадает с проверяемым checkout")
else:
    refuse(role + " не связан с точным semaphore")
isolated = [line.partition(": ")[2] for line in lines if line.startswith("isolated_worktree:")]
if isolated:
    governance = [line.partition(": ")[2] for line in lines if line.startswith("governance_worktree:")]
    # Isolation belongs to the governance checkout. A separate shared ORZ
    # repository still needs exact scoped delivery proof, not foreign HEADs.
    if (len(isolated) != 1 or not isolated[0] or len(governance) != 1
            or own_field != "orz_sessions_dir"
            or os.path.realpath(isolated[0]) != os.path.realpath(governance[0])
            or os.path.realpath(isolated[0]) == os.path.realpath(repo)):
        refuse("scoped fallback недопустим для isolated checkout")
if not re.fullmatch(r"[0-9a-f]{40,64}", remote):
    refuse("нет зафиксированного remote OID")
head = git("rev-parse", "--verify", "HEAD^{commit}").strip().decode()
git("cat-file", "-e", remote + "^{commit}")
scope = set()
for line in lines:
    if not line.startswith("file: "):
        continue
    path = line[6:]
    parts = PurePosixPath(path).parts
    if (not parts or path != str(PurePosixPath(path)) or path.startswith(("/", ":"))
            or ".." in parts or any(char in path for char in "\x00\r\n*?[")):
        refuse("неоднозначный file claim")
    # The open-session log is a runtime projection, never a Git deliverable.
    if path != "inbox/open-sessions.log":
        scope.add(path)
if not scope:
    refuse("нет file claims")

claimed_paths = set()
claims = []
other_claims = []
for line in lines:
    if not line.startswith("commit: "):
        continue
    fields = line[8:].split()
    if len(fields) != 2 or not re.fullmatch(r"[0-9a-fA-F]{40,64}", fields[1]):
        refuse("неоднозначный commit claim")
    if fields[0] != Path(repo).name:
        other_claims.append(tuple(fields))
        continue
    commit = fields[1]
    parents = git("rev-list", "--parents", "-n", "1", commit).split()
    if len(parents) > 2:
        refuse("merge claim требует обычного HEAD proof")
    claims.append(commit)
    changed = git("diff-tree", "--root", "--no-commit-id", "--name-only",
                  "--no-renames", "-r", "-z", commit)
    claimed_paths.update(os.fsdecode(path) for path in changed.split(b"\0") if path)
if not claims or not claimed_paths or not claimed_paths.issubset(scope):
    refuse("нет полного repo-qualified commit scope")

def entry(revision, path):
    return git("ls-tree", "-z", revision, "--", path)

# WP-537 (17.09) / WP-484 peer-session 2026-09-19-05 (Claude+Kimi+Codex,
# same day as _prepared_source_set_has_publish_proof's twin fallback): the
# exact-tree compare below can never succeed on a hot file (docs/WP-REGISTRY.md,
# WeekPlan) that a sibling session commits to between this session's delivery
# and this proof running. Opt-in (default off, IWE_SESSION_GUARD_ANCHORED_FALLBACK=1),
# claimed-path-only fallback: prove our own insertion is still uniquely
# anchored inside the current published blob, reusing the same primitive
# already trusted for commit-claim supersession and for the sibling function.
anchored_fallback_enabled = os.environ.get("IWE_SESSION_GUARD_ANCHORED_FALLBACK") == "1"

def _raw_git(*args):
    result = subprocess.run(
        ["git", "--literal-pathspecs", "-C", repo, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None

def blob_entry_fields(revision, raw_path):
    row = _raw_git("ls-tree", "-z", revision, "--", raw_path)
    return tuple(row.split(b"\t", 1)[0].split()) if row else None

def blob_by_oid(oid):
    return _raw_git("cat-file", "blob", oid.decode("ascii"))

def unique_position(seq, needle):
    positions = [i for i in range(len(seq) - len(needle) + 1)
                 if seq[i:i + len(needle)] == needle]
    return positions[0] if len(positions) == 1 else None

def anchored_insertions(base, own, published):
    if any(b"\0" in blob or len(blob) > 262144 for blob in (base, own, published)):
        return False
    base, own, published = (blob.splitlines(keepends=True) for blob in (base, own, published))
    if max(map(len, (base, own, published))) > 4096:
        return False
    own_ops = difflib.SequenceMatcher(None, base, own, autojunk=False).get_opcodes()
    target_ops = difflib.SequenceMatcher(None, base, published, autojunk=False).get_opcodes()
    inserts = [op for op in own_ops if op[0] != "equal"]
    if not inserts or any(op[0] != "insert" for op in inserts):
        return False

    def equal_mapping(ops, start, end):
        for tag, a, b, c, _ in ops:
            if tag == "equal" and a <= start < end <= b:
                return c + start - a
        return None

    for _, boundary, _, own_start, own_end in inserts:
        matches = [op for op in target_ops if op[0] == "insert" and op[1] == boundary]
        if len(matches) != 1 or boundary == 0 or boundary == len(base):
            return False
        target_start, target_end = matches[0][3:]
        if unique_position(published[target_start:target_end], own[own_start:own_end]) is None:
            return False
        for left in (True, False):
            anchored = False
            for width in range(1, 9):
                start, end = (boundary - width, boundary) if left else (boundary, boundary + width)
                if start < 0 or end > len(base):
                    continue
                anchor = base[start:end]
                own_position = equal_mapping(own_ops, start, end)
                target_position = equal_mapping(target_ops, start, end)
                if (own_position is not None and target_position is not None
                        and unique_position(base, anchor) == start
                        and unique_position(own, anchor) == own_position
                        and unique_position(published, anchor) == target_position):
                    anchored = True
                    break
            if not anchored:
                return False
    return True

def _is_ancestor(a, b):
    result = subprocess.run(
        ["git", "-C", repo, "merge-base", "--is-ancestor", a, b],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0

_session_base_cache = {}

def resolve_session_base():
    # Order-independent (Kimi, round 5): the semaphore's `commit:` lines are
    # append order, not proven git ancestry order. Find the claim that is an
    # ancestor of every OTHER claim and of head -- not just take claims[0].
    # No such claim (parallel/out-of-order claims) -> fallback stays
    # unavailable, exact-tree behaviour is unchanged.
    # Accepted residual risk (cold-review, same day): a stray extra `commit:`
    # claim for an unrelated, much older commit on this repo would shift
    # base_rev further back than this session's real start. That makes
    # anchored_insertions() prove a LARGER insert region, a strictly harder
    # bar -- biases toward spurious refusal, not toward a false accept.
    if "value" not in _session_base_cache:
        base_rev = None
        for candidate in claims:
            if (all(candidate == other or _is_ancestor(candidate, other) for other in claims)
                    and _is_ancestor(candidate, head)):
                parent = _raw_git("rev-parse", "--verify", candidate + "^")
                base_rev = parent.strip().decode() if parent else None
                break
        _session_base_cache["value"] = base_rev
    return _session_base_cache["value"]

def path_has_anchored_fallback_proof(raw_path):
    if not anchored_fallback_enabled or raw_path not in claimed_paths:
        return False
    base_rev = resolve_session_base()
    if base_rev is None:
        return False
    base_fields = blob_entry_fields(base_rev, raw_path)
    own_fields = blob_entry_fields(head, raw_path)
    published_fields = blob_entry_fields(remote, raw_path)
    if base_fields is None or own_fields is None or published_fields is None:
        return False
    base_mode, own_mode, published_mode = base_fields[0], own_fields[0], published_fields[0]
    if not (base_mode == own_mode == published_mode) or base_mode not in (b"100644", b"100755"):
        return False
    base_blob = blob_by_oid(base_fields[2])
    own_blob = blob_by_oid(own_fields[2])
    published_blob = blob_by_oid(published_fields[2])
    if base_blob is None or own_blob is None or published_blob is None:
        return False
    return anchored_insertions(base_blob, own_blob, published_blob)

def published_untracked_session_file(path):
    # A shared sessions checkout may stay on another writer's branch while
    # our exact file was delivered from a separate clone. Never extend this
    # proof to governance worktrees or staged/tracked local changes.
    if (own_field != "orz_sessions_dir" or other_field != "governance_worktree"
            or len(own_matches) != 1 or len(other_declared) != 1
            or os.path.realpath(other_declared[0]) == os.path.realpath(repo)
            or Path(repo).resolve().parent != Path(iwe_root).resolve()
            or not (Path(repo) / ".git").is_dir()
            or entry(head, path) or git("ls-files", "--stage", "-z", "--", path)
            or git("status", "--porcelain", "-z", "--untracked-files=all", "--", path)
               != b"?? " + os.fsencode(path) + b"\0"):
        return False
    remote_entry = entry(remote, path)
    if not remote_entry:
        return False
    metadata, remote_path = remote_entry.rstrip(b"\0").split(b"\t", 1)
    mode, kind, oid = metadata.split()
    if kind != b"blob" or mode not in (b"100644", b"100755") or remote_path != os.fsencode(path):
        return False
    candidate = Path(repo) / path
    directory = None
    descriptor = None
    try:
        if candidate.resolve(strict=True) != candidate:
            return False
        directory = os.open(repo, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        for component in PurePosixPath(path).parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(PurePosixPath(path).name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            return False
        actual_mode = b"100755" if before.st_mode & stat.S_IXUSR else b"100644"
        digest = hashlib.new("sha256" if len(oid) == 64 else "sha1")
        digest.update(b"blob " + str(before.st_size).encode("ascii") + b"\0")
        while chunk := os.read(descriptor, 65536):
            digest.update(chunk)
        if (actual_mode != mode or digest.hexdigest().encode("ascii") != oid
                or git("ls-files", "--stage", "-z", "--", path)
                or git("status", "--porcelain", "-z", "--untracked-files=all", "--", path)
                   != b"?? " + os.fsencode(path) + b"\0"
                or candidate.resolve(strict=True) != candidate):
            return False
        after = os.fstat(descriptor)
        current = candidate.lstat()
        fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
        return all(getattr(before, field) == getattr(after, field) == getattr(current, field)
                   for field in fields)
    except OSError as exc:
        refuse("файл недоступен при проверке публикации: " + path + ": " + str(exc))
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)


relevant = set(claimed_paths)
other_repos = [iwe_root, os.path.join(iwe_root, "memory")]
other_prefix = other_field + ": "
other_declared = [line[len(other_prefix):] for line in lines if line.startswith(other_prefix)]
if len(other_declared) > 1:
    refuse("неоднозначный " + other_field + " checkout")
if not other_declared and legacy_other:
    # Same trust shift as own_field above: caller-resolved, not read from
    # the semaphore. Without this, a legacy semaphore's own ORZ scaffold
    # file (always in scope, `open` registers it unconditionally) has no
    # repo left to be found in and refuses on "путь отсутствует или
    # неоднозначен между репозиториями" -- reproduced live testing this
    # phase's scenario D before this line existed.
    #
    # WP-484 (16.09, peer-session 2026-09-16-28-wp484-close-gate-triage,
    # Claude+Kimi): condition narrowed from "structurally_legacy" (all three
    # scope fields absent) to "this one field absent" -- a semaphore missing
    # only `other_field` (own_field present and already matched above) was
    # falling through to the strict refusal below with no fallback at all,
    # even though the caller always resolves `legacy_other` independently of
    # semaphore content now (never trusts what the semaphore claims). Kimi's
    # objection stands and is answered here, not hidden: this does widen
    # which semaphores get the caller-resolved fallback, from "all three
    # fields absent" to "this specific field absent" -- but the TRUST SOURCE
    # is unchanged (own_field's exact-match check above is untouched, and
    # `legacy_other` is still never read from the semaphore itself).
    #
    # `repo` (own_field, from the semaphore) and `legacy_other` (independent
    # resolve) CAN legitimately name the same real path in a partially-legacy
    # case -- e.g. an unmigrated install where resolve_orz_sessions_dir()'s
    # own legacy fallback is a subdirectory of the governance repo itself
    # (Kimi cold-review, same session). That is not a collision to guard
    # against here: `other_repos.discard(os.path.realpath(repo))` a few lines
    # below already removes `repo` from the other-side set unconditionally,
    # so a same-path `legacy_other` simply contributes nothing new, exactly
    # like a same-path `other_declared` from the semaphore already would.
    other_declared = [legacy_other]
other_repos.extend(other_declared)
other_repos = {os.path.realpath(path) for path in other_repos
               if os.path.lexists(Path(path) / ".git")}
other_repos.discard(os.path.realpath(repo))

def repository_identity(checkout):
    common = os.fsdecode(git_at(checkout, "rev-parse", "--git-common-dir")).strip()
    return os.path.realpath(os.path.join(checkout, common))

own_identity = repository_identity(repo)
other_repo_groups = {}
for checkout in other_repos:
    identity = repository_identity(checkout)
    if identity != own_identity:
        other_repo_groups.setdefault(identity, []).append(checkout)

def known_path(checkout, path):
    return bool(git_at(checkout, "ls-tree", "-z", "HEAD", "--", path)
                or git_at(checkout, "ls-files", "-z", "--", path)
                or os.path.lexists(Path(checkout) / path))

# A legacy file claim has no repository prefix. Only an otherwise unknown
# path may use third-repository commit claims for attribution. Do not extend
# other_repos globally: README.md in an unrelated code repo must not create a
# new ambiguity for a path already owned by the declared governance checkout.
resolved_other_claims = None

def claimed_other_owners(path):
    global resolved_other_claims
    if resolved_other_claims is None:
        if not resolver_functions:
            refuse("разрешение заявленных репозиториев недоступно")
        resolved_other_claims = {}
        for name, commit in other_claims:
            if Path(semaphore).read_bytes() != snapshot:
                refuse("scope изменился во время разрешения репозиториев")
            try:
                result = subprocess.run(
                    ["bash", "-c", resolver_functions
                     + '\nIWE_ROOT="$1"\n_resolve_repo_checkout "$2" "$3"\n',
                     "scope-claim-resolver", iwe_root, name, commit],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
                )
            except (OSError, subprocess.TimeoutExpired):
                refuse("разрешение заявленного репозитория не выполнено: " + name)
            if Path(semaphore).read_bytes() != snapshot:
                refuse("scope изменился во время разрешения репозиториев")
            if result.returncode:
                refuse("заявленный репозиторий отсутствует или неоднозначен: " + name)
            checkout = os.fsdecode(result.stdout).rstrip("\n")
            if (not os.path.isabs(checkout) or "\n" in checkout
                    or os.path.realpath(checkout) != checkout
                    or os.fsdecode(git_at(checkout, "rev-parse", "--show-toplevel")).rstrip("\n") != checkout):
                refuse("заявленный репозиторий не является точным checkout: " + name)
            git_at(checkout, "cat-file", "-e", commit + "^{commit}")
            # A genuine declared commit identifies its repository, not ownership
            # of every path. The canonical checkout can be on another branch:
            # exact declared trees also attribute paths absent from its HEAD.
            # Historical attribution never replaces current MC delivery proof;
            # publication of third-repo claims is checked separately at close.
            # WP-484 (21.09, peer-session 2026-09-21-08): the root repository is one of
            # other_repos, and used to be skipped here, so a NEW file published into it
            # from an isolated copy (absent from the canonical checkout, which lags
            # behind origin) had no owner and refused the close. This lookup runs only
            # for a path that no repository claimed yet (owners == 0 above), so it
            # cannot add a second owner to a path that already has one.
            if checkout != os.path.realpath(repo):
                resolved_other_claims.setdefault(checkout, set()).add(commit)
    def commit_touched_path(checkout, commits):
        return any(os.fsencode(path) in git_at(
            checkout, "diff-tree", "-m", "--root", "--no-commit-id", "--name-only",
            "--no-renames", "-r", "-z", commit).split(b"\0") for commit in commits)

    def declared_owner(checkout, commits):
        if known_path(checkout, path):
            return True
        if checkout in other_repos:
            # The root/sessions checkouts lag behind origin, so a path may be
            # absent there yet legitimately delivered. Here the declared commit
            # must itself ADD or CHANGE the path: a bare "the tree contains it"
            # would let a stale or historical commit own a path it never touched.
            return commit_touched_path(checkout, commits)
        return any(git_at(checkout, "ls-tree", "-z", commit, "--", path) for commit in commits)

    owning = [(checkout, commits) for checkout, commits in resolved_other_claims.items()
              if declared_owner(checkout, commits)]
    if len(owning) > 1:
        # Two claimed repositories can each legitimately hold their own, unrelated file
        # at the same relative path (WP-7 Ф173, 2026-09-24: gateway-mcp and knowledge-mcp
        # each have a src/scope.test.ts; only gateway-mcp's declared commit touched it).
        # Narrow to whichever candidate's own declared commit(s) actually added or
        # changed the path, when that narrows to exactly one — otherwise the original
        # tree-presence count stands (fail closed, unchanged from before this narrowing;
        # this also covers test_two_third_repo_claims_for_unknown_path_refuse, where both
        # candidates' commits genuinely touch the path and the ambiguity is real).
        touched = [checkout for checkout, commits in owning if commit_touched_path(checkout, commits)]
        if len(touched) == 1:
            return 1
    return len(owning)

for path in scope:
    local = path in claimed_paths or known_path(repo, path) or bool(entry(remote, path))
    owners = int(local) + sum(any(known_path(other, path) for other in checkouts)
                              for checkouts in other_repo_groups.values())
    if owners == 0:
        owners = claimed_other_owners(path)
    # WP-537 (19.09, peer session with Kimi+Codex): these two used to share one
    # message ("путь отсутствует или неоднозначен"), and the reader could not
    # tell which half had fired. A zero (path belongs to a repo this check does
    # not enumerate -- DS-MCP/*, DS-IT-systems/*) then reads as an ambiguity
    # between repos, which sends the diagnosis in exactly the wrong direction.
    if owners == 0:
        refuse("путь не найден ни в одном из проверяемых checkout — вероятно, "
               "принадлежит репозиторию вне этой проверки: " + path)
    if owners > 1:
        refuse("путь найден в нескольких проверяемых checkout, принадлежность "
               "неоднозначна: " + path)
    if local:
        relevant.add(path)
material = False
published_untracked = set()
for path in sorted(relevant):
    flags = git("ls-files", "-v", "-z", "--", path).split(b"\0")
    if any(flag and (flag[:1].islower() or flag[:1] == b"S") for flag in flags):
        refuse("флаги индекса скрывают проверку файла: " + path)
    if published_untracked_session_file(path):
        published_untracked.add(path)
        material = True
        continue
    if git("status", "--porcelain", "-z", "--untracked-files=all", "--", path):
        refuse("собственные файлы не закоммичены: " + path)
    local_entry = entry(head, path)
    if local_entry != entry(remote, path):
        if not path_has_anchored_fallback_proof(path):
            refuse("текущий результат не совпадает с origin/main: " + path)
    if not local_entry and os.path.lexists(Path(repo) / path):
        refuse("файл отсутствует в опубликованном дереве: " + path)
    material = material or bool(local_entry)
if not material:
    refuse("пустой результат")
for path in sorted(relevant):
    if path in published_untracked:
        if not published_untracked_session_file(path):
            refuse("опубликованный файл изменился во время проверки: " + path)
    elif git("status", "--porcelain", "-z", "--untracked-files=all", "--", path):
        refuse("собственные файлы изменились во время проверки: " + path)
if git("rev-parse", "HEAD").strip().decode() != head:
    refuse("HEAD изменился во время проверки")
if Path(semaphore).read_bytes() != snapshot:
    refuse("scope изменился во время проверки")
PY
}

_repo_head_has_publish_proof() {  # <repo> <role> [exact semaphore] [own field] [other field] [legacy own] [legacy other]
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
    if [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] \
       && _repo_scope_has_publish_proof "$root" "$role" "$3" "$origin_ref" "$4" "$5" "${6:-}" "${7:-}"; then
      echo "Session CLOSE: текущие файлы и commit scope этой сессии подтверждены свежим origin/main: $root" >&2
      return 0
    fi
    echo "Session CLOSE: HEAD $role не достижим из origin/main; есть неподтверждённая доставка: $root" >&2
    return 1
  fi
  return 0
}

_commit_current_tree_has_publish_proof() {  # <repo> <linear source commit> <fresh remote OID>
  # Three-way publication may omit hunks already present remotely.  Patch IDs
  # then differ; only the exact CURRENT result over every changed path counts.
  python3 - "$@" <<'PY'
import subprocess
import sys

repo, commit, remote = sys.argv[1:]

def git(*args):
    result = subprocess.run(
        ["git", "--literal-pathspecs", "-C", repo, *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )
    if result.returncode:
        raise SystemExit(1)
    return result.stdout

git("cat-file", "-e", remote + "^{commit}")
if len(git("rev-list", "--parents", "-n", "1", commit).split()) != 2:
    raise SystemExit(1)
paths = [path for path in git(
    "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", commit,
).split(b"\0") if path]
if not paths:
    raise SystemExit(1)
for path in paths:
    if git("ls-tree", "-z", commit, "--", path) != git("ls-tree", "-z", remote, "--", path):
        raise SystemExit(1)
PY
}

_commit_claim_supersession_has_publish_proof() {  # <repo> <source> <remote OID> <semaphore> <repo name>
  # Prove preservation in an already claimed, OID-published successor.  Neither
  # a declaration of supersession nor patch-id transitivity is sufficient.
  timeout 15 python3 - "$@" <<'PY'
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

repo, source, remote, semaphore, repo_name = sys.argv[1:]
deadline = time.monotonic() + 12
env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
           GIT_ATTR_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0",
           GIT_NO_REPLACE_OBJECTS="1", GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts",
           GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")


def git(directory, *args, allowed=(0,)):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("proof deadline exceeded")
    result = subprocess.run(
        ["git", "--literal-pathspecs", "-c", "core.attributesFile=" + os.devnull,
         "-C", str(directory), *args], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=remaining,
    )
    if result.returncode not in allowed:
        raise ValueError("Git proof operation failed: " + args[0])
    return result


def unique_position(lines, needle):
    positions = [i for i in range(len(lines) - len(needle) + 1)
                 if lines[i:i + len(needle)] == needle]
    return positions[0] if len(positions) == 1 else None


def anchored_insertions(base, own, published):
    if any(b"\0" in blob or len(blob) > 262144 for blob in (base, own, published)):
        return False
    base, own, published = (blob.splitlines(keepends=True) for blob in (base, own, published))
    if max(map(len, (base, own, published))) > 4096:
        return False
    own_ops = difflib.SequenceMatcher(None, base, own, autojunk=False).get_opcodes()
    target_ops = difflib.SequenceMatcher(None, base, published, autojunk=False).get_opcodes()
    inserts = [op for op in own_ops if op[0] != "equal"]
    if not inserts or any(op[0] != "insert" for op in inserts):
        return False

    def equal_mapping(ops, start, end):
        for tag, a, b, c, _ in ops:
            if tag == "equal" and a <= start < end <= b:
                return c + start - a
        return None

    for _, boundary, _, own_start, own_end in inserts:
        matches = [op for op in target_ops if op[0] == "insert" and op[1] == boundary]
        if len(matches) != 1 or boundary == 0 or boundary == len(base):
            return False
        target_start, target_end = matches[0][3:]
        if unique_position(published[target_start:target_end], own[own_start:own_end]) is None:
            return False
        for left in (True, False):
            anchored = False
            for width in range(1, 9):
                start, end = (boundary - width, boundary) if left else (boundary, boundary + width)
                if start < 0 or end > len(base):
                    continue
                anchor = base[start:end]
                own_position = equal_mapping(own_ops, start, end)
                target_position = equal_mapping(target_ops, start, end)
                if (own_position is not None and target_position is not None
                        and unique_position(base, anchor) == start
                        and unique_position(own, anchor) == own_position
                        and unique_position(published, anchor) == target_position):
                    anchored = True
                    break
            if not anchored:
                return False
    return True


def proof(store, candidate, parent, changed):
    def read(*args):
        return git(store, *args).stdout

    def entry(revision, path):
        row = read("ls-tree", "-z", revision, "--", path)
        return tuple(row.split(b"\t", 1)[0].split()) if row else None

    def blob(oid):
        if int(read("cat-file", "-s", oid)) > 262144:
            raise ValueError("conflict blob exceeds proof budget")
        return read("cat-file", "blob", oid)

    result = git(store, "merge-tree", "--write-tree", "-z", "--messages",
                 "--merge-base=" + parent, source, candidate, allowed=(0, 1))
    fields = result.stdout.split(b"\0")
    merged = fields.pop(0).decode("ascii")
    wanted = read("rev-parse", candidate + "^{tree}").strip().decode("ascii")
    if result.returncode == 0:
        return merged == wanted
    conflicts = {}
    while fields and fields[0]:
        row = fields.pop(0)
        metadata, path = row.split(b"\t", 1)
        mode, oid, stage = metadata.split()
        if stage not in (b"1", b"2", b"3") or stage in conflicts.setdefault(path, {}):
            return False
        conflicts[path][stage] = (mode, b"blob", oid)
    if not fields or not conflicts:
        return False
    fields.pop(0)
    content_paths = set()
    while fields and fields[0]:
        count = int(fields.pop(0))
        if count < 1 or count > 64 or len(fields) < count + 2:
            return False
        paths, fields = fields[:count], fields[count:]
        kind, _message = fields[:2]
        fields = fields[2:]
        if kind == b"CONFLICT (contents)" and count == 1:
            content_paths.add(paths[0])
        elif kind != b"Auto-merging":
            return False
    if fields != [b""] or content_paths != set(conflicts):
        return False
    differences = set(read("diff-tree", "--no-commit-id", "--name-only", "--no-renames",
                           "-r", "-z", merged, wanted).split(b"\0")) - {b""}
    if not differences.issubset(conflicts):
        return False
    target_changes = set(read("diff-tree", "--no-commit-id", "--name-only", "--no-renames",
                              "-r", "-z", parent, candidate).split(b"\0")) - {b""}
    for path, stages in conflicts.items():
        if set(stages) != {b"1", b"2", b"3"}:
            return False
        base, own, published = (stages[key] for key in (b"1", b"2", b"3"))
        if (base[0] not in (b"100644", b"100755")
                or not base[0] == own[0] == published[0]
                or entry(candidate, path) != published or path not in target_changes):
            return False
        source_paths = [old for old in changed
                        if entry(parent, old) == base and entry(source, old) == own]
        if len(source_paths) != 1:
            return False
        if source_paths[0] != path and entry(candidate, source_paths[0]) is not None:
            return False
        if not anchored_insertions(blob(base[2]), blob(own[2]), blob(published[2])):
            return False
    return True


try:
    if not all(re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", value)
               for value in (source, remote)):
        raise ValueError("invalid source or pinned remote")
    snapshot = Path(semaphore).read_bytes()
    if len(snapshot) > 65536:
        raise ValueError("claim snapshot exceeds proof budget")
    claims = [line[8:].decode("ascii").split() for line in snapshot.splitlines()
              if line.startswith(b"commit: ")]
    if len(claims) > 32 or any(len(claim) != 2 for claim in claims):
        raise ValueError("invalid or excessive claims")
    candidates = sorted({oid for name, oid in claims if name == repo_name and oid != source})
    if [repo_name, source] not in claims:
        raise ValueError("source is not a frozen claim")
    common = git(repo, "rev-parse", "--git-common-dir").stdout.strip().decode()
    objects = (Path(repo) / common / "objects").resolve()
    object_format = git(repo, "rev-parse", "--show-object-format").stdout.strip().decode("ascii")
    with tempfile.TemporaryDirectory(prefix="iwe-claim-proof-") as scratch:
        git(scratch, "init", "--bare", "--quiet", "--template=", "--object-format=" + object_format)
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = json.dumps(str(objects))
        # Tracked attributes must not select even a built-in union driver.
        env["GIT_ATTR_SOURCE"] = git(scratch, "mktree").stdout.strip().decode("ascii")
        parents = git(scratch, "rev-list", "--parents", "-n", "1", source).stdout.split()
        if len(parents) != 2:
            raise ValueError("source must be linear")
        parent = parents[1].decode("ascii")
        changed = set(git(scratch, "diff-tree", "--no-commit-id", "--name-only", "--no-renames",
                          "-r", "-z", source).stdout.split(b"\0")) - {b""}
        if not changed or len(changed) > 64:
            raise ValueError("empty or excessive source scope")
        for candidate in candidates:
            if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", candidate):
                raise ValueError("invalid successor claim")
            if git(scratch, "merge-base", "--is-ancestor", candidate, remote, allowed=(0, 1)).returncode:
                continue
            if len(git(scratch, "rev-list", "--parents", "-n", "1", candidate).stdout.split()) != 2:
                continue
            if not git(scratch, "diff-tree", "--no-commit-id", "--name-only", "-r", candidate).stdout:
                continue
            bases = git(scratch, "merge-base", "--all", source, candidate, allowed=(0, 1)).stdout.split()
            if bases != [parents[1]]:
                continue
            if proof(scratch, candidate, parent, changed):
                if time.monotonic() >= deadline:
                    raise ValueError("proof deadline exceeded")
                if Path(semaphore).read_bytes() != snapshot:
                    raise ValueError("claim snapshot changed during proof")
                print("Session CLOSE: claimed changes preserved in OID-published claim: "
                      + repo_name + " " + source + " -> " + candidate, file=sys.stderr)
                raise SystemExit(0)
    raise ValueError("no exact published successor preserves the claimed changes")
except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
    print("Session CLOSE: supersession proof refused: " + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

# Resolve a repo NAME (as recorded in the semaphore) to its checkout root.
# WP-537, peer session 2026-09-19-09-wp537-close-blocked-shared-checkout
# (Claude+Kimi+Codex).
#
# The writer and the reader of a `commit:` claim disagreed about what a name
# means. `note-commit` records `basename "$NC_REPO_DIR"` for anything that is
# not the root, so a claim made from DS-MCP/mentorship-service is written as
# `mentorship-service` -- and every reader then looked only under
# "$IWE_ROOT/<name>", found nothing, and refused the session's own delivered
# commit with "claimed commit не читается". Live case 19.09: five of the six
# repos of one session were direct children of the root and resolved; two
# (DS-MCP/mentorship-service, DS-IT-systems/neon-migrations) could not.
#
# The container list is deliberately fixed rather than a recursive scan. A
# `find | head -1` would happily return a worktree under .iwe-runtime, an
# archived copy under attic-*, or an arbitrary one of two same-named repos --
# and a basename is not a global identity: this installation really does have
# two `DS-ai-systems` checkouts (one at the root, one inside DS-IT-systems).
# Ambiguity therefore refuses instead of guessing, with its own exit code so
# callers can say WHICH failure happened -- the single blended message was
# what cost an hour of wrong hypothesis in the session that found this.
#
# Two checkouts sharing one origin are one repository in two copies, not a
# name collision -- the same identity rule `open` already uses to WARN rather
# than block on a duplicate clone (peer session 2026-08-14-02-git-worktree-chaos,
# consensus with Codex; regression scripts/tests/session-guard-duplicate-checkout-warn-smoke.sh).
# This matters in practice, not in theory: all three duplicated names in this
# installation -- DS-ai-systems, iwe-guide-web, neon-migrations -- are clones
# of one upstream each, and neon-migrations is one of the repos this fix
# exists for. Refusing them as "ambiguous" would have left the defect half
# unfixed.
#
# Exit: 0 + root on stdout | 2 not found | 3 ambiguous (candidates on stderr).
_resolve_repo_checkout() {  # <repo name> [<commit sha to pick the copy that has it>]
  local name="$1" want_commit="${2:-}"
  local container candidate toplevel physical remote identity common_dir
  local paths="" identities="" chosen="" fallback="" count=0
  case "$name" in
    ""|*/*|*..*) return 2 ;;
  esac
  if [ "$name" = "iwe-root" ] || [ "$name" = "$(basename "$IWE_ROOT")" ]; then
    (cd "$IWE_ROOT" 2>/dev/null && pwd -P) || return 2
    return 0
  fi
  for container in "$IWE_ROOT" "$IWE_ROOT/DS-MCP" "$IWE_ROOT/DS-IT-systems" \
                   "$IWE_ROOT/.iwe-runtime/isolated-worktrees"; do
    candidate="$container/$name"
    # `.git` is a directory in a normal clone and a file in a worktree/submodule.
    [ -e "$candidate/.git" ] || continue
    toplevel=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || continue
    physical=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
    # A plain subdirectory of a parent repo answers --show-toplevel with the
    # PARENT's root; only a real checkout root answers with itself.
    [ "$(cd "$toplevel" 2>/dev/null && pwd -P)" = "$physical" ] || continue
    # An isolated session's worktree is named after the SESSION. Until the
    # writer fix of this same phase, `note-commit` recorded that name as the
    # repository, so every semaphore opened before it carries claims no reader
    # could resolve -- and those semaphores belong to live sessions we must not
    # rewrite. Normalising a linked worktree to its canonical root here is the
    # reading half of the same rule: a worktree is a checkout of exactly one
    # repository, and the claimed commit lives in the object database they
    # share. For an ordinary clone the common dir's parent IS the root, so
    # nothing changes.
    common_dir=$(git -C "$physical" rev-parse --path-format=absolute \
      --git-common-dir 2>/dev/null || true)
    if [ -n "$common_dir" ] && [ -d "$(dirname "$common_dir")" ] \
       && [ "$(dirname "$common_dir")" != "$physical" ]; then
      physical=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd -P) || continue
    fi
    # Dedupe by physical root: `memory` is a symlink, and the same checkout
    # must not count twice just because two containers reach it.
    printf '%s' "$paths" | grep -qxF "$physical" && continue
    remote=$(git -C "$physical" remote get-url origin 2>/dev/null) || remote=""
    if [ -n "$remote" ]; then
      identity=$(normalize_remote_url "$remote")
    else
      # Unknown identity is never evidence of sameness: keep such a candidate
      # distinct by its own path, so it neither merges with a named repo nor
      # with another origin-less one (Codex cold review, 19.09).
      identity="path:$physical"
    fi
    paths="${paths}${physical}"$'\n'
    identities="${identities}${identity}"$'\n'
    count=$((count + 1))
  done
  [ "$count" -ne 0 ] || return 2
  # Identity is settled BEFORE the commit is consulted. The other order would
  # let a SHA that happens to exist in only one of two genuinely DIFFERENT
  # repositories silently resolve a real collision.
  if [ "$(printf '%s' "$identities" | sort -u | grep -c .)" -gt 1 ]; then
    printf '%s' "$paths" >&2
    return 3
  fi
  while IFS= read -r physical; do
    [ -n "$physical" ] || continue
    [ -n "$fallback" ] || fallback="$physical"
    [ -n "$want_commit" ] || continue
    git -C "$physical" cat-file -e "${want_commit}^{commit}" 2>/dev/null || continue
    # Copies of one origin answer the delivery question identically -- except
    # a shallow one, which can hold the object and still fail the ancestry
    # proof at its shallow boundary. Prefer a full clone when there is one.
    if [ "$(git -C "$physical" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ]; then
      chosen="$physical"
      break
    fi
    [ -n "$chosen" ] || chosen="$physical"
  done <<< "$paths"
  printf '%s\n' "${chosen:-$fallback}"
}

_peer_metadata_claim_has_publish_proof() {  # <repo> <source> <fresh remote OID> <semaphore> <repo name>
  # A peer session may publish one final packet instead of its intermediate
  # metadata commits. This is deliberately narrower than generic supersession:
  # peer evidence stays byte-identical; only verified lifecycle fields change.
  timeout 15 python3 - "$@" <<'PY'
import datetime
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import time
import yaml

repo, source, remote, semaphore, repo_name = sys.argv[1:]
deadline = time.monotonic() + 12
env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
           GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1",
           GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts",
           GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")


def git(*args, allowed=(0,)):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("proof deadline exceeded")
    result = subprocess.run(["git", "--literal-pathspecs", "-C", repo, *args],
                            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=remaining)
    if result.returncode not in allowed:
        raise ValueError("Git proof failed: " + args[0])
    return result


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str) or key in result or key == "<<":
            raise ValueError("ambiguous metadata key")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def mapping(raw):
    if len(raw) > 65536 or b"\0" in raw:
        raise ValueError("invalid metadata size")
    if any(isinstance(token, (yaml.tokens.AliasToken, yaml.tokens.AnchorToken))
           for token in yaml.scan(raw)):
        raise ValueError("metadata aliases are not proof")
    value = yaml.load(raw, Loader=UniqueLoader)
    if not isinstance(value, dict):
        raise ValueError("metadata is not a mapping")
    return value


def paths(commit):
    return set(git("diff-tree", "--root", "--no-commit-id", "--name-only",
                   "--no-renames", "-r", "-z", commit).stdout.split(b"\0")) - {b""}


def linear(commit):
    return len(git("rev-list", "--parents", "-n", "1", commit).stdout.split()) == 2


def ancestor(older, newer):
    return git("merge-base", "--is-ancestor", older, newer, allowed=(0, 1)).returncode == 0


def entry(commit, path):
    row = git("ls-tree", "-z", commit, "--", path).stdout
    if not row or row.count(b"\0") != 1:
        raise ValueError("missing or ambiguous artifact")
    fields = row.split(b"\t", 1)[0].split()
    if fields[0] not in (b"100644", b"100755") or fields[1] != b"blob":
        raise ValueError("artifact is not a regular file")
    return tuple(fields)


def metadata(commit, path):
    return mapping(git("cat-file", "blob", entry(commit, path)[2].decode()).stdout)


def clean_files(revision, relevant):
    if git("status", "--porcelain", "-z", "--untracked-files=all", "--", *sorted(relevant)).stdout:
        return False
    for path in relevant:
        flags = git("ls-files", "-v", "-z", "--", path).stdout
        if not flags or flags[:1].islower() or flags[:1] == b"S":
            return False
        local = Path(repo) / os.fsdecode(path)
        if local.resolve() != local.absolute() or not local.is_file():
            return False
        expected = entry(revision, path)
        if bool(local.lstat().st_mode & stat.S_IXUSR) != (expected[0] == b"100755"):
            return False
        if local.read_bytes() != git("cat-file", "blob", expected[2].decode()).stdout:
            return False
    return True


def lifecycle(before, after, identity):
    mutable = {"end_time", "status", "result_path", "publication_status"}
    additions = {"closure_run_id", "closure_guard_session_id", "publication_target",
                 "publication_method", "pilot_reflection", "main_publication_approved"}
    if not set(before).issubset(after) or set(after) - set(before) - additions:
        return False
    if any(yaml.safe_dump(before[key], sort_keys=True) != yaml.safe_dump(after[key], sort_keys=True)
           for key in before if key not in mutable):
        return False
    if (before.get("status") not in ("agreed", "completed") or after.get("status") != "completed"
            or before.get("result_path") not in ("report-draft.md", "report.md")
            or after.get("result_path") != "report.md"
            or before.get("publication_status") not in ("awaiting_explicit_main_approval", "runner-managed")
            or after.get("publication_status") != "runner-managed"):
        return False
    for key in ("session_id", "wp"):
        if before.get(key) != identity[key]:
            return False
    start = datetime.datetime.fromisoformat(str(before.get("start_time", "")))
    end = datetime.datetime.fromisoformat(str(after.get("end_time", "")))
    if start.tzinfo is None or end.tzinfo is None or end < start:
        return False
    if before.get("end_time") not in ("", after["end_time"]):
        return False
    expected = {"closure_guard_session_id": identity["guard"], "publication_target": "main",
                "publication_method": "runner-publication-recovery", "pilot_reflection": "рефлексии нет",
                "main_publication_approved": True}
    if any(key in after and (type(after[key]) is not type(value) or after[key] != value)
           for key, value in expected.items()):
        return False
    return bool(re.fullmatch("quick-close-" + re.escape(identity["session_id"])
                             + r"(?:-[0-9]{15,20})?", str(after.get("closure_run_id", ""))))


try:
    info = os.lstat(semaphore)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
        raise ValueError("unsafe semaphore")
    snapshot = Path(semaphore).read_bytes()
    if len(snapshot) > 65536:
        raise ValueError("oversized semaphore")
    lines = snapshot.decode().splitlines()
    def field(name):
        values = [line[len(name) + 2:] for line in lines if line.startswith(name + ": ")]
        if len(values) != 1 or not values[0]:
            raise ValueError("ambiguous semaphore field: " + name)
        return values[0]
    slug, guard, wp = field("slug"), field("session_id"), field("wp")
    if Path(field("orz_sessions_dir")).resolve() != Path(repo).resolve() or Path(repo).name != repo_name:
        raise ValueError("not this session's content repository")
    date = datetime.date.fromisoformat(slug[:10])
    if not re.fullmatch(r"[A-Za-z0-9._-]+", slug + guard):
        raise ValueError("unsafe identity")
    folder = date.strftime("%Y-%m/%d/") + slug + "/"
    meta, report = (folder + "meta.yaml").encode(), (folder + "report.md").encode()
    scope = set()
    for line in lines:
        if line.startswith("file: "):
            path = line[6:]
            if (not path or str(PurePosixPath(path)) != path or path.startswith(("/", ":"))
                    or ".." in PurePosixPath(path).parts or re.search(r"[\x00\r\n*?\[]", path)):
                raise ValueError("unsafe registered path")
            scope.add(path.encode())
    claims = set()
    for line in lines:
        if line.startswith("commit: "):
            parts = line[8:].split()
            if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", parts[1]):
                raise ValueError("invalid claim")
            if parts[0] == repo_name:
                claims.add(parts[1])
    if source not in claims or len(claims) > 32 or not linear(source):
        raise ValueError("missing or non-linear source claim")
    if git("rev-parse", "refs/remotes/origin/main").stdout.strip().decode() != remote:
        raise ValueError("remote snapshot changed")
    original_paths = paths(source)
    if meta not in original_paths or not original_paths.issubset(scope) or report not in scope:
        raise ValueError("incomplete peer scope")
    before = metadata(source, meta)
    head = git("rev-parse", "HEAD").stdout.strip().decode()
    publications = [claim for claim in claims if claim != source and linear(claim) and ancestor(claim, remote)]
    revisions = [claim for claim in claims if claim != source and linear(claim)
                 and ancestor(source, claim) and ancestor(claim, head)]
    accepted = False
    for revision in revisions:
        chain = git("rev-list", "--ancestry-path", source + ".." + revision).stdout.decode().splitlines()
        if len(chain) > 128:
            continue
        relevant = set(original_paths) | {report}
        valid_chain = True
        for commit in chain:
            if not linear(commit):
                valid_chain = False
                break
            changed = paths(commit)
            if any(path.startswith(folder.encode()) for path in changed):
                if commit not in claims or not linear(commit) or not changed.issubset(scope):
                    valid_chain = False
                    break
                relevant.update(changed)
        if not valid_chain or not lifecycle(before, metadata(revision, meta),
                                           {"session_id": slug, "guard": guard, "wp": wp}):
            continue
        if any(entry(source, path) != entry(revision, path) for path in original_paths - {meta}):
            continue
        if entry(source, meta)[:2] != entry(revision, meta)[:2]:
            continue
        if not clean_files(revision, relevant):
            continue
        if any(entry(head, path) != entry(revision, path) for path in relevant):
            continue
        for publication in publications:
            if not relevant.issubset(paths(publication)):
                continue
            if all(entry(revision, path) == entry(publication, path) == entry(remote, path)
                   for path in relevant):
                accepted = True
                break
        if accepted:
            break
    if not accepted:
        raise ValueError("no exact claimed lifecycle publication")
    if (Path(semaphore).read_bytes() != snapshot or git("rev-parse", "HEAD").stdout.strip().decode() != head
            or git("rev-parse", "refs/remotes/origin/main").stdout.strip().decode() != remote
            or not clean_files(revision, relevant)):
        raise ValueError("proof inputs changed")
    print("Session CLOSE: peer metadata lifecycle and unchanged evidence published: " + source, file=sys.stderr)
except (ValueError, TypeError, KeyError, OSError, UnicodeError, yaml.YAMLError, subprocess.SubprocessError) as error:
    print("Session CLOSE: peer lifecycle proof refused: " + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

_code_branch_claim_has_publish_proof() {  # <semaphore> <resolved repo> <claimed commit> <repo name>
  # Product delivery can stop at its session branch; governance/ORZ/root cannot.
  # The frozen claim and slug choose the identity and ref. The existing runner
  # receipt only locates the owned registered worktree; it never proves delivery.
  python3 - "$IWE_ROOT" "$@" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import yaml

root, semaphore, repo, claimed, repo_name = sys.argv[1:]
root, semaphore, repo = (Path(value).resolve(strict=True) for value in (root, semaphore, repo))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(path, *args):
    result = subprocess.run(
        ["git", "-c", "diff.autoRefreshIndex=false", "-C", str(path), *args],
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"},
        capture_output=True, text=True, timeout=10,
    )
    require(result.returncode == 0, "git proof unavailable")
    return result.stdout.strip()


def common(path):
    return Path(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve(strict=True)


def origin(path):
    value = git(path, "remote", "get-url", "origin")
    value = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", "", value)
    value = re.sub(r"^[^@/]*@", "", value).replace(":", "/")
    return re.sub(r"\.git$", "", value)


class UniqueLoader(yaml.SafeLoader):
    pass


def mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        require(key not in result, "duplicate metadata key")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def parse_document(raw):
    require(0 < len(raw) <= 1024 * 1024 and b"\0" not in raw, "invalid metadata size")
    text = raw.decode()
    match = re.match(r"^---\n(.*?)\n---(?:\n|$)", text, re.S)
    require(match is not None, "frontmatter missing")
    value = yaml.load(match.group(1), Loader=UniqueLoader)
    require(isinstance(value, dict), "metadata must be a mapping")
    return value, raw


try:
    require(semaphore.is_file() and not semaphore.is_symlink(), "regular semaphore required")
    metadata, sem_snapshot = parse_document(semaphore.read_bytes())
    slug, owner = metadata.get("slug"), metadata.get("session_id")
    require(isinstance(slug, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", slug), "invalid session slug")
    require(isinstance(owner, str) and owner, "session owner missing")
    require(f"commit: {repo_name} {claimed}" in sem_snapshot.decode().splitlines(), "claim is not session-owned")
    repo_common, repo_origin = common(repo), origin(repo)
    require(repo_common.name == ".git" and repo_common.parent.parent in {
        root / "DS-MCP", root / "DS-IT-systems"
    }, "not a product checkout")
    protected = [root]
    for field in ("governance_worktree", "orz_sessions_dir"):
        value = metadata.get(field)
        require(isinstance(value, str) and Path(value).is_absolute(), "protected identity missing")
        protected.append(Path(value).resolve(strict=True))
    for path in protected:
        require(common(path) != repo_common and origin(path) != repo_origin, "protected repository requires main")

    listing = git(repo, "worktree", "list", "--porcelain", "-z").split("\0")
    registered = [Path(item[9:]) for item in listing if item.startswith("worktree ")]
    candidates = []
    governance = Path(metadata["governance_worktree"])
    source_heads = re.findall(r"^close_delivery_source_head: ([0-9a-f]{40,64})$", sem_snapshot.decode(), re.M)
    require(len(source_heads) == 1, "frozen source HEAD missing or ambiguous")
    source_head = source_heads[0]
    paths = git(governance, "ls-tree", "-r", "--name-only", source_head, "--", "inbox/agent/tasks").splitlines()
    for card_name in paths:
        if not re.fullmatch(r"inbox/agent/tasks/RUN-quick-close-" + re.escape(slug) + r"(?:-[0-9]{15,20})?\.md", card_name):
            continue
        blob = git(governance, "show", f"{source_head}:{card_name}")
        card, snapshot = parse_document(blob.encode())
        if (card.get("process_id") != "quick-close" or card.get("owner_session_id") != owner
                or card.get("requested_slug") != slug):
            continue
        receipt = (card.get("results") or {}).get("commit-push") or {}
        if receipt.get("all_pushed") is not True or receipt.get("failed"):
            continue
        for item in receipt.get("pushed", []):
            name, sha = item.get("repo"), item.get("sha")
            if not isinstance(name, str) or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", sha):
                continue
            worktree = root / name
            if (not worktree.is_absolute() or not worktree.exists()
                    or worktree.resolve() != worktree or registered.count(worktree) != 1):
                continue
            if common(worktree) == repo_common:
                candidates.append((worktree, sha))
    require(len(candidates) == 1, "owned delivery worktree missing or ambiguous")
    worktree, head = candidates[0]
    branch_ref, remote_ref = f"refs/heads/{slug}", f"refs/remotes/origin/{slug}"

    def source_snapshot():
        require(origin(worktree) == repo_origin and common(worktree) == repo_common, "repository identity changed")
        require(git(worktree, "symbolic-ref", "HEAD") == branch_ref, "not the exact session branch")
        require(git(worktree, "rev-parse", "HEAD") == head, "receipt source HEAD changed")
        require(git(worktree, "config", "--get", f"branch.{slug}.remote") == "origin", "foreign upstream remote")
        require(git(worktree, "config", "--get", f"branch.{slug}.merge") == branch_ref, "foreign upstream ref")
        require(not git(worktree, "status", "--porcelain", "--untracked-files=all"), "dirty source worktree")
        flags = git(worktree, "ls-files", "-v", "-z").split("\0")
        require(all(not line or line.startswith("H ") for line in flags), "hidden index flags")
        require(semaphore.read_bytes() == sem_snapshot, "session snapshot changed")

    source_snapshot()
    git(worktree, "merge-base", "--is-ancestor", claimed, head)
    git(worktree, "fetch", "--quiet", "--no-tags", "origin", f"+{branch_ref}:{remote_ref}")
    remote_oid = git(worktree, "rev-parse", "--verify", f"{remote_ref}^{{commit}}")
    git(worktree, "merge-base", "--is-ancestor", head, remote_oid)
    git(worktree, "merge-base", "--is-ancestor", claimed, remote_oid)
    source_snapshot()
    print(f"Session CLOSE: exact code claim delivered to {branch_ref}: {claimed}", file=sys.stderr)
except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError, yaml.YAMLError) as exc:
    print(f"Session CLOSE: code branch proof refused: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

_claimed_source_chain_has_publish_proof() {  # <repo> <source> <fresh main OID> <exact semaphore> <repo name>
  # Explicitly claimed report corrections may supersede an earlier packet.
  # Every commit, including intermediate edits, must already be frozen; this
  # is not a lifecycle heuristic or permission to search arbitrary peer history.
  timeout 15 python3 - "$@" <<'PY'
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import time

repo, source, remote, semaphore, repo_name = sys.argv[1:]
deadline = time.monotonic() + 12
env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
           GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1",
           GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts",
           GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")


def git(*args, allowed=(0,)):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("proof deadline exceeded")
    result = subprocess.run(["git", "--literal-pathspecs", "-C", repo, *args],
                            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=remaining)
    if result.returncode not in allowed:
        raise ValueError("Git proof failed: " + args[0])
    return result


def changed_paths(commit):
    return set(git("diff-tree", "--no-commit-id", "--name-only", "--no-renames",
                   "-r", "-z", commit).stdout.split(b"\0")) - {b""}


def parents(commit):
    return git("rev-list", "--parents", "-n", "1", commit).stdout.decode().split()[1:]


def ancestor(older, newer):
    return git("merge-base", "--is-ancestor", older, newer, allowed=(0, 1)).returncode == 0


def entry(commit, path):
    row = git("ls-tree", "-z", commit, "--", path).stdout
    if not row or row.count(b"\0") != 1:
        raise ValueError("missing or ambiguous final artifact")
    fields = row.split(b"\t", 1)[0].split()
    if fields[0] not in (b"100644", b"100755") or fields[1] != b"blob":
        raise ValueError("final artifact is not a regular file")
    return tuple(fields)


def current_files_match(revision, relevant):
    for path in relevant:
        expected = entry(revision, path)
        local = Path(repo) / os.fsdecode(path)
        if local.resolve() != local.absolute() or not local.is_file():
            return False
        if bool(local.lstat().st_mode & stat.S_IXUSR) != (expected[0] == b"100755"):
            return False
        if local.read_bytes() != git("cat-file", "blob", expected[2].decode()).stdout:
            return False
        index = git("ls-files", "--stage", "-z", "--", path).stdout
        if index:
            if index.count(b"\0") != 1:
                return False
            mode, oid, stage = index.split(b"\t", 1)[0].split()
            if (mode, b"blob", oid) != expected or stage != b"0":
                return False
            flags = git("ls-files", "-v", "-z", "--", path).stdout
            if not flags or flags[:1].islower() or flags[:1] == b"S":
                return False
            if git("status", "--porcelain", "-z", "--untracked-files=all", "--", path).stdout:
                return False
        elif git("ls-tree", "-z", "HEAD", "--", path).stdout:
            # A staged deletion must not masquerade as an untracked artifact.
            return False
        elif git("status", "--porcelain", "-z", "--untracked-files=all", "--", path).stdout != b"?? " + path + b"\0":
            # Ignored files are not declared untracked delivery artifacts.
            return False
    return True


try:
    info = os.lstat(semaphore)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
        raise ValueError("unsafe semaphore")
    snapshot = Path(semaphore).read_bytes()
    if len(snapshot) > 65536:
        raise ValueError("oversized semaphore")
    lines = snapshot.decode().splitlines()

    def field(name):
        values = [line[len(name) + 2:] for line in lines if line.startswith(name + ": ")]
        if len(values) != 1 or not values[0]:
            raise ValueError("ambiguous semaphore field: " + name)
        return values[0]

    if (Path(field("orz_sessions_dir")).resolve() != Path(repo).resolve()
            or Path(repo).name != repo_name or field("close_path") != "peer-session"):
        raise ValueError("not this peer session's content repository")
    rows = [line[8:] for line in lines if line.startswith("commit: ")]
    frozen = json.loads(field("close_delivery_claimed_commits"))
    if (not isinstance(frozen, list) or any(not isinstance(row, str) for row in frozen)
            or len(rows) > 32 or sorted(set(rows)) != sorted(frozen)):
        raise ValueError("claims differ from frozen delivery")
    claims = set()
    for row in rows:
        parts = row.split()
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", parts[1]):
            raise ValueError("invalid frozen claim")
        if parts[0] == repo_name:
            claims.add(parts[1])
    if source not in claims or len(parents(source)) != 1:
        raise ValueError("source is not a frozen linear claim")
    scope = set()
    for line in lines:
        if line.startswith("file: "):
            path = line[6:]
            if (not path or str(PurePosixPath(path)) != path or path.startswith(("/", ":"))
                    or ".." in PurePosixPath(path).parts or re.search(r"[\x00\r\n*?\[]", path)):
                raise ValueError("unsafe registered path")
            scope.add(path.encode())
    if git("rev-parse", "refs/remotes/origin/main").stdout.strip().decode() != remote:
        raise ValueError("remote snapshot changed")
    head = git("rev-parse", "HEAD").stdout
    publications = [claim for claim in sorted(claims)
                    if len(parents(claim)) == 1 and ancestor(claim, remote)]
    revisions = [claim for claim in sorted(claims) if claim != source and ancestor(source, claim)]
    accepted = False
    for revision in revisions:
        chain = git("rev-list", "--reverse", source + ".." + revision).stdout.decode().splitlines()
        if not chain or len(chain) > 32 or not set(chain).issubset(claims):
            continue
        relevant = changed_paths(source)
        previous = source
        valid = bool(relevant) and relevant.issubset(scope)
        for commit in chain:
            changed = changed_paths(commit)
            if parents(commit) != [previous] or not changed or not changed.issubset(scope):
                valid = False
                break
            relevant.update(changed)
            previous = commit
        if not valid or len(relevant) > 64 or not current_files_match(revision, relevant):
            continue
        for publication in publications:
            if not relevant.issubset(changed_paths(publication)):
                continue
            if all(entry(revision, path) == entry(publication, path) == entry(remote, path)
                   for path in relevant):
                accepted = True
                break
        if accepted:
            break
    if not accepted:
        raise ValueError("no exact published frozen source chain")
    if (Path(semaphore).read_bytes() != snapshot or git("rev-parse", "HEAD").stdout != head
            or git("rev-parse", "refs/remotes/origin/main").stdout.strip().decode() != remote
            or not current_files_match(revision, relevant)):
        raise ValueError("proof inputs changed")
    print("Session CLOSE: frozen source chain published exactly: " + source + " -> " + revision,
          file=sys.stderr)
except (ValueError, TypeError, KeyError, OSError, UnicodeError, subprocess.SubprocessError) as error:
    print("Session CLOSE: frozen source chain proof refused: " + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
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
    repo_dir=$(_resolve_repo_checkout "$repo_name" "$commit_sha") || {
      case $? in
        3) echo "Session CLOSE: закрытие отклонено — имя '$repo_name' принадлежит нескольким checkout с РАЗНЫМИ origin, заявка не указывает, о каком из них речь (кандидаты выше): $repo_name $commit_sha" >&2 ;;
        *) echo "Session CLOSE: закрытие отклонено — репозиторий заявки не найден среди известных checkout (корень, \$IWE_ROOT/*, DS-MCP/*, DS-IT-systems/*): $repo_name $commit_sha" >&2 ;;
      esac
      return 1
    }
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
    if _code_branch_claim_has_publish_proof "$semaphore" "$repo_dir" "$commit_sha" "$repo_name"; then
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
      if git -C "$repo_dir" cherry refs/remotes/origin/main "$commit_sha" "${commit_sha}~1" 2>/dev/null \
          | grep -q '^- '; then
        continue
      fi
      local current_remote
      current_remote=$(git -C "$repo_dir" rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null) \
        || return 1
      _commit_current_tree_has_publish_proof "$repo_dir" "$commit_sha" "$current_remote" \
        || _commit_claim_supersession_has_publish_proof "$repo_dir" "$commit_sha" "$current_remote" "$semaphore" "$repo_name" \
        || _peer_metadata_claim_has_publish_proof "$repo_dir" "$commit_sha" "$current_remote" "$semaphore" "$repo_name" \
        || _claimed_source_chain_has_publish_proof "$repo_dir" "$commit_sha" "$current_remote" "$semaphore" "$repo_name" \
        || { echo "Session CLOSE: claimed commit не имеет OID, patch, точного текущего tree или проверенного supersession proof в origin/main: $repo_name $commit_sha" >&2; return 1; }
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
    if status != "running" or step != "session-guard-release" or verdict != "pass":
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
    published["close_publish_session_id"] != expected_session
    or published["close_publish_prepare_digest"] != digest
    or published["close_publish_source_head"] != fields["close_delivery_source_head"]
    or published["close_publish_source_status_sha256"] != fields["close_delivery_source_status_sha256"]
    or published["close_publish_terminal_sha256"] != fields["close_delivery_terminal_sha256"]
):
    raise SystemExit(1)
try:
    verified = json.loads(published["close_publish_verified_commits"])
except (TypeError, ValueError):
    raise SystemExit(1)
if verified != expected:
    raise SystemExit(1)
proof = published["close_publish_proof"]
if proof == "isolate-push-exit0/v1":
    if not re.fullmatch(r"[0-9a-f]{40,64}", published["close_publish_remote_main_sha"]):
        raise SystemExit(1)
    publish_payload = {
        "proof": proof,
        "session_id": published["close_publish_session_id"],
        "prepare_digest": digest,
        "source_head": published["close_publish_source_head"],
        "source_status_sha256": published["close_publish_source_status_sha256"],
        "terminal_sha256": published["close_publish_terminal_sha256"],
        "remote_main_sha": published["close_publish_remote_main_sha"],
        "verified_commits": verified,
    }
elif proof == "manual-abandon-attestation/v1":
    # WP-484 (peer-session with Codex): the cryptographic tree-proof this
    # closes cannot succeed once a later legitimate REPLACE lands on the same
    # paths the PREPARED snapshot touched. This branch validates the
    # attestation record written by _record_close_abandoned instead -- it is
    # deliberately a distinct proof identity, never mistaken for the
    # cryptographic isolate-push path above (self-check below still binds it
    # to this exact prepare_digest/source_head/terminal_sha).
    if published["close_publish_remote_main_sha"] != "abandoned":
        raise SystemExit(1)
    abandoned_by_values = values("close_publish_abandoned_by")
    abandoned_at_values = values("close_publish_abandoned_at")
    if len(abandoned_by_values) != 1 or not abandoned_by_values[0]:
        raise SystemExit(1)
    if len(abandoned_at_values) != 1 or not abandoned_at_values[0]:
        raise SystemExit(1)
    publish_payload = {
        "proof": proof,
        "session_id": published["close_publish_session_id"],
        "prepare_digest": digest,
        "source_head": published["close_publish_source_head"],
        "source_status_sha256": published["close_publish_source_status_sha256"],
        "terminal_sha256": published["close_publish_terminal_sha256"],
        "abandoned_commits": verified,
        "abandoned_by": abandoned_by_values[0],
    }
else:
    raise SystemExit(1)
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

_abandon_prepared_matches_source() {  # <semaphore> <source-commit>...
  local semaphore="$1"; shift
  local recorded_json
  recorded_json=$(_unique_record_field "$semaphore" close_delivery_source_commits) || return 1
  python3 - "$recorded_json" "$@" <<'PY' 2>/dev/null
import json
import sys

recorded = json.loads(sys.argv[1])
supplied = sys.argv[2:]
if not isinstance(recorded, list) or len(supplied) != len(set(supplied)):
    raise SystemExit(1)
raise SystemExit(0 if sorted(c.lower() for c in recorded) == sorted(c.lower() for c in supplied) else 1)
PY
}

_record_close_abandoned() {  # <semaphore> <session> <prepare-digest> <source-commits-json> <source-head> <source-status> <terminal-sha> <agent>
  local fields_json digest
  fields_json=$(python3 - "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'PY'
import hashlib
import json
import sys
import time

session, prepare, commits_json, source_head, source_status, terminal_sha, agent = sys.argv[1:]
commits = json.loads(commits_json)
abandoned_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
payload = {
    "proof": "manual-abandon-attestation/v1",
    "session_id": session,
    "prepare_digest": prepare,
    "source_head": source_head,
    "source_status_sha256": source_status,
    "terminal_sha256": terminal_sha,
    "abandoned_commits": commits,
    "abandoned_by": agent,
}
digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
print(json.dumps({
    "close_publish_proof": "manual-abandon-attestation/v1",
    "close_publish_session_id": session,
    "close_publish_prepare_digest": prepare,
    "close_publish_source_head": source_head,
    "close_publish_source_status_sha256": source_status,
    "close_publish_terminal_sha256": terminal_sha,
    "close_publish_remote_main_sha": "abandoned",
    "close_publish_verified_commits": json.dumps(commits, separators=(",", ":")),
    "close_publish_digest": digest,
    "close_publish_abandoned_by": agent,
    "close_publish_abandoned_at": abandoned_at,
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

_runner_release_retry_snapshot_sha() {  # <semaphore> <same frozen card path>
  local semaphore="$1" card="$2" owner wp slug current_sha
  owner=$(_unique_record_field "$semaphore" harness_session_id || true)
  [ -n "$owner" ] || owner=$(_legacy_codex_harness_session_id "$semaphore" || true)
  [ -n "$owner" ] || return 1
  wp=$(_unique_record_field "$semaphore" wp) || return 1
  slug=$(_unique_record_field "$semaphore" slug) || return 1
  current_sha=$(_terminal_card_snapshot_sha "$card" release-step "$owner" "$wp" "$slug") || return 1
  # A runner updates its release result and stage on every failed attempt.
  # Accept that progress only from its own audited write, after validating
  # the same owner/WP/slug/release gate again. PREPARED bytes stay immutable;
  # source HEAD, scope, claims and fresh main proof remain separate gates.
  python3 - "$card" "$IWE_ROOT/.iwe-runtime/run-card-audit" <<'PY' || return 1
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import yaml

card, audit_root = map(Path, sys.argv[1:])

def owned_bytes(path, limit):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or not 0 < info.st_size <= limit):
            raise ValueError("not an owned bounded file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(limit + 1)
        current = os.lstat(path)
        if ((current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
                or len(raw) != info.st_size or not raw.endswith(b"\n")):
            raise ValueError("snapshot changed")
        return raw
    finally:
        os.close(fd)

try:
    raw = owned_bytes(card, 1024 * 1024)
    _, metadata, body = raw.decode().split("---\n", 2)
    doc = yaml.safe_load(metadata)
    expected_body = ("\n# Карточка запуска: quick-close\n\n"
                     "Автоматически обновляется `process-runner.py`. Не редактировать руками -- "
                     "карточка производная, source-of-truth = `~/.iwe/gate-decisions.jsonl` "
                     "и сам раннер (DP.SC.054 инвариант 3).\n")
    if body != expected_body or doc.get("kind") != "process-run":
        raise ValueError("not a derived runner body")
    if doc["results"]["commit-push"].get("all_pushed") is not True:
        raise ValueError("publication did not succeed")
    if not any(item.get("step") == "session-guard-release" and item.get("type") == "reflex"
               for item in doc.get("history", [])):
        raise ValueError("no previous release attempt")
    run_id = doc["run_id"]
    if card.name != "RUN-" + run_id + ".md" or audit_root.resolve() != audit_root:
        raise ValueError("audit route changed")
    event = json.loads(owned_bytes(audit_root / (run_id + ".jsonl"), 8 * 1024 * 1024).splitlines()[-1])
    expected = dict(actor="process-runner", event="written", process_id="quick-close",
                    run_id=run_id, status="running", card_path=str(card),
                    sha256=hashlib.sha256(raw).hexdigest())
    if any(event.get(key) != value for key, value in expected.items()):
        raise ValueError("current card is not the runner's audited write")
except (OSError, ValueError, KeyError, TypeError, AttributeError, yaml.YAMLError):
    raise SystemExit(1)
PY
  [ "$(_terminal_card_snapshot_sha "$card" release-step "$owner" "$wp" "$slug" || true)" = "$current_sha" ] || return 1
  printf '%s\n' "$current_sha"
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
  [ -n "$actual_terminal" ] || return 1
  if [ "$actual_terminal" != "$terminal_sha" ]; then
    [ "$terminal_kind" = "file" ] || return 1
    [ "$(_runner_release_retry_snapshot_sha "$semaphore" "$terminal_ref" || true)" = "$actual_terminal" ] || return 1
    printf 'Session CLOSE: повторный release подтверждён записью раннера; PREPARED сохранён, current terminal=%s\n' "$actual_terminal" >&2
  fi
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
  # A previous attempt may have delivered the final prepared snapshot with
  # rewritten OIDs. Replaying its intermediate commits can then conflict
  # with that same delivered result. Reuse the full-set proof on fresh main;
  # the caller still checks the immutable snapshot, claims and receipt.
  timeout 10 git -C "$worktree" fetch --quiet origin \
    '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null || return 1
  if _prepared_source_set_has_publish_proof "$semaphore" "$worktree"; then
    return 0
  fi
  if [ "$commit_count" -eq 0 ]; then
    # An empty prepared set is already-delivered evidence, not permission to
    # recalculate a moving range.  Calling ordinary isolate-push here would
    # publish a commit created after PREPARED before the post-check noticed.
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
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

semaphore, worktree = sys.argv[1:]
snapshot = Path(semaphore).read_bytes()

def field(key):
    prefix = (key + ": ").encode()
    values = [line[len(prefix):] for line in snapshot.splitlines() if line.startswith(prefix)]
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

# WP-537 (17.09) / WP-484 peer-session 2026-09-19-05 (Claude+Kimi+Codex): a
# byte-exact whole-blob compare can never succeed on a hot file
# (docs/WP-REGISTRY.md, WeekPlan) that a concurrent session commits to
# between this session's delivery and this proof running -- the blob at
# that path keeps moving, so source_head is a permanently stale snapshot of
# it. Opt-in (default off, IWE_SESSION_GUARD_ANCHORED_FALLBACK=1): on a
# mismatch, prove instead that our own insertion is still uniquely anchored
# inside the current published blob, reusing the same anchored-insertion
# primitive already trusted for commit-claim supersession
# (_commit_claim_supersession_has_publish_proof). Only a pure insertion (no
# replace/delete) at a path whose mode is unchanged qualifies -- anything
# else still fails closed exactly as before this fallback existed.
anchored_fallback_enabled = os.environ.get("IWE_SESSION_GUARD_ANCHORED_FALLBACK") == "1"

def blob_entry_fields(revision, raw_path):
    row = tree_entry(revision, raw_path)
    return tuple(row.split(b"\t", 1)[0].split()) if row else None

def blob_by_oid(oid):
    result = subprocess.run(
        ["git", "-C", worktree, "cat-file", "blob", oid],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None

def unique_position(lines, needle):
    positions = [i for i in range(len(lines) - len(needle) + 1)
                 if lines[i:i + len(needle)] == needle]
    return positions[0] if len(positions) == 1 else None

def anchored_insertions(base, own, published):
    if any(b"\0" in blob or len(blob) > 262144 for blob in (base, own, published)):
        return False
    base, own, published = (blob.splitlines(keepends=True) for blob in (base, own, published))
    if max(map(len, (base, own, published))) > 4096:
        return False
    own_ops = difflib.SequenceMatcher(None, base, own, autojunk=False).get_opcodes()
    target_ops = difflib.SequenceMatcher(None, base, published, autojunk=False).get_opcodes()
    inserts = [op for op in own_ops if op[0] != "equal"]
    if not inserts or any(op[0] != "insert" for op in inserts):
        return False

    def equal_mapping(ops, start, end):
        for tag, a, b, c, _ in ops:
            if tag == "equal" and a <= start < end <= b:
                return c + start - a
        return None

    for _, boundary, _, own_start, own_end in inserts:
        matches = [op for op in target_ops if op[0] == "insert" and op[1] == boundary]
        if len(matches) != 1 or boundary == 0 or boundary == len(base):
            return False
        target_start, target_end = matches[0][3:]
        if unique_position(published[target_start:target_end], own[own_start:own_end]) is None:
            return False
        for left in (True, False):
            anchored = False
            for width in range(1, 9):
                start, end = (boundary - width, boundary) if left else (boundary, boundary + width)
                if start < 0 or end > len(base):
                    continue
                anchor = base[start:end]
                own_position = equal_mapping(own_ops, start, end)
                target_position = equal_mapping(target_ops, start, end)
                if (own_position is not None and target_position is not None
                        and unique_position(base, anchor) == start
                        and unique_position(own, anchor) == own_position
                        and unique_position(published, anchor) == target_position):
                    anchored = True
                    break
            if not anchored:
                return False
    return True

def path_has_anchored_fallback_proof(raw_path):
    if not anchored_fallback_enabled:
        return False
    base_fields = blob_entry_fields(source_base, raw_path)
    own_fields = blob_entry_fields(source_head, raw_path)
    published_fields = blob_entry_fields(remote_head, raw_path)
    if base_fields is None or own_fields is None or published_fields is None:
        return False
    base_mode, own_mode, published_mode = base_fields[0], own_fields[0], published_fields[0]
    if not (base_mode == own_mode == published_mode) or base_mode not in (b"100644", b"100755"):
        return False
    base_blob = blob_by_oid(base_fields[2])
    own_blob = blob_by_oid(own_fields[2])
    published_blob = blob_by_oid(published_fields[2])
    if base_blob is None or own_blob is None or published_blob is None:
        return False
    return anchored_insertions(base_blob, own_blob, published_blob)

def runtime_reap_superseded(raw_path):
    # A stale local reaper must not roll back another run's published lifecycle.
    import yaml

    path = os.fsdecode(raw_path)
    if not re.fullmatch(r"inbox/agent/tasks/RUN-[A-Za-z0-9._-]+\.md", path):
        return False

    class UniqueLoader(yaml.SafeLoader):
        pass

    def unique_mapping(loader, node):
        result = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node)
            if not isinstance(key, str) or key in result or key == "<<":
                raise ValueError("ambiguous runtime metadata")
            result[key] = loader.construct_object(value_node)
        return result

    UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)

    def read_card(revision):
        entry = blob_entry_fields(revision, raw_path)
        if entry is None or entry[:2] != (b"100644", b"blob"):
            raise ValueError("runtime card is not a regular file")
        raw = blob_by_oid(entry[2])
        if raw is None or len(raw) > 1048576 or not raw.startswith(b"---\n"):
            raise ValueError("runtime card frontmatter is missing")
        _, frontmatter, body = raw.split(b"---\n", 2)
        if any(isinstance(token, (yaml.tokens.AliasToken, yaml.tokens.AnchorToken))
               for token in yaml.scan(frontmatter)):
            raise ValueError("runtime metadata aliases are not proof")
        card = yaml.load(frontmatter, Loader=UniqueLoader)
        if not isinstance(card, dict):
            raise ValueError("runtime metadata is not a mapping")
        return card, body

    try:
        source, source_body = read_card(source_head)
        target, target_body = read_card(remote_head)
        expected_file = "inbox/agent/tasks/RUN-" + str(source.get("run_id")) + ".md"
        own_harness = [line.split(b": ", 1)[1].decode() for line in snapshot.splitlines()
                       if line.startswith(b"harness_session_id: ")]
        current_owner = (own_harness[0] if len(own_harness) == 1 else
                         os.environ.get("CODEX_THREAD_ID") or field("session_id"))
        if (source.get("kind") != "process-run" or source.get("process_id") != "quick-close"
                or path != expected_file or source.get("status") != "cancelled"
                or source.get("cancel_reason") != "auto_reaped_orphan"
                or target.get("status") not in {"completed", "failed", "cancelled"}
                or target.get("cancel_reason") == "auto_reaped_orphan"
                or not source.get("requested_slug") or source["requested_slug"] == field("slug")
                or source.get("owner_session_id") == current_owner or source_body != target_body):
            return False
        lifecycle = {"results", "stage_entered_at", "reaped_level", "cancel_reason",
                     "completed_at", "reaped_at", "current_step", "history", "status"}
        if any(source.get(key) != target.get(key) for key in (set(source) | set(target)) - lifecycle):
            return False
        history, published_history = source.get("history"), target.get("history")
        results, published_results = source.get("results"), target.get("results")
        return (isinstance(history, list) and bool(history) and isinstance(published_history, list)
                and len(published_history) > len(history) and published_history[:len(history)] == history
                and isinstance(results, dict) and isinstance(published_results, dict)
                and set(results).issubset(published_results))
    except (ValueError, TypeError, UnicodeError, yaml.YAMLError):
        return False

def path_absorbs_prepared_text(raw_path):
    # Compose independent proofs: a shared text file may have later edits
    # while unrelated runtime cards have separately verified lifecycle progress.
    # merge-file has no repository attributes, hooks, or custom merge drivers.
    entries = [blob_entry_fields(revision, raw_path)
               for revision in (source_base, source_head, remote_head)]
    if any(entry is None or entry[:2] != (b"100644", b"blob") for entry in entries):
        return False
    blobs = [blob_by_oid(entry[2]) for entry in entries]
    if any(blob is None or len(blob) > 1048576 or b"\0" in blob for blob in blobs):
        return False
    base_blob, own_blob, published_blob = blobs
    try:
        with tempfile.TemporaryDirectory(prefix="iwe-prepared-text-proof-") as scratch:
            files = [Path(scratch) / name for name in ("published", "base", "own")]
            for path, blob in zip(files, (published_blob, base_blob, own_blob)):
                path.write_bytes(blob)
            result = subprocess.run(
                ["git", "merge-file", "-p", *map(str, files)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                check=False, timeout=3,
            )
            return result.returncode == 0 and result.stdout == published_blob
    except (OSError, subprocess.SubprocessError):
        return False

def remote_absorbs_prepared_tree(compare_tree=True):
    # Reuse the strict tree-absorption criterion of supersession proof, bound
    # here to the immutable PREPARED range, not arbitrary caller merge bases.
    # Patch-history equality alone would not establish this current result.
    #
    # WP-484 (21.09, peer-session 2026-09-21-12, Codex): with compare_tree=False only the
    # integrity of the prepared set is verified (valid ids, unique commits, base..head equals the
    # declared commits without merges, the worktree stands on source_head) plus the final
    # snapshot recheck. Every per-path proof below depends on that integrity: a path proven
    # absorbed by a text merge says nothing about a set that is duplicated, incomplete or
    # not the range that was prepared.
    deadline = time.monotonic() + 12
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_ATTR_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0",
               GIT_NO_REPLACE_OBJECTS="1", GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts",
               GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")

    def run(directory, *args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("prepared absorption proof deadline exceeded")
        return subprocess.run(
            ["git", "--literal-pathspecs", "-c", "core.attributesFile=" + os.devnull,
             "-C", str(directory), *args], env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=remaining,
        ).stdout

    try:
        if (not isinstance(commits, list) or not commits or len(commits) != len(set(commits))
                or any(not isinstance(oid, str) or not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", oid)
                       for oid in [source_base, source_head, remote_head, *commits])):
            return False
        if run(worktree, "rev-parse", "HEAD").strip().decode() != source_head:
            return False
        common = run(worktree, "rev-parse", "--git-common-dir").strip().decode()
        objects = (Path(worktree) / common / "objects").resolve()
        object_format = run(worktree, "rev-parse", "--show-object-format").strip().decode("ascii")
        with tempfile.TemporaryDirectory(prefix="iwe-prepared-proof-") as scratch:
            run(scratch, "init", "--bare", "--quiet", "--template=", "--object-format=" + object_format)
            env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = json.dumps(str(objects))
            # Never execute a repository merge driver or accept a built-in union
            # driver from tracked attributes; all new objects stay in scratch.
            env["GIT_ATTR_SOURCE"] = run(scratch, "mktree").strip().decode("ascii")
            run(scratch, "merge-base", "--is-ancestor", source_base, source_head)
            actual = run(scratch, "rev-list", "--reverse", source_base + ".." + source_head).decode().splitlines()
            if actual != commits or run(scratch, "rev-list", "--merges", source_base + ".." + source_head).strip():
                return False
            if compare_tree:
                expected = run(scratch, "rev-parse", remote_head + "^{tree}").strip()
                merged = run(scratch, "merge-tree", "--write-tree", "--merge-base=" + source_base,
                             remote_head, source_head).strip()
                if merged != expected:
                    return False
        return (Path(semaphore).read_bytes() == snapshot
                and run(worktree, "rev-parse", "HEAD").strip().decode() == source_head
                and run(worktree, "rev-parse", "refs/remotes/origin/main").strip().decode() == remote_head)
    except (ValueError, TypeError, OSError, UnicodeError, subprocess.SubprocessError):
        return False


# Integrity of the prepared set comes FIRST and is required for every per-path proof, not only for
# the whole-tree one; and once all paths are proven the snapshot is rechecked (semaphore bytes,
# HEAD, origin/main unchanged while the proofs ran).
if not remote_absorbs_prepared_tree(compare_tree=False):
    raise SystemExit(1)
for raw_path in sorted(paths):
    if tree_entry(source_head, raw_path) != tree_entry(remote_head, raw_path):
        if (not runtime_reap_superseded(raw_path)
                and not path_has_anchored_fallback_proof(raw_path)
                and not path_absorbs_prepared_text(raw_path)):
            raise SystemExit(0 if remote_absorbs_prepared_tree() else 1)
if not remote_absorbs_prepared_tree(compare_tree=False):
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
    # Resolved here, ahead of its other (redundant but side-effect-free, see
    # that line's own comment) read further down for the governance-checkout
    # call -- this call site runs first and needs its own legacy fallback
    # value now, not after governance_repo is resolved below (WP-484, 17.09,
    # peer-session 2026-09-17-02-own-field-mirror-fix).
    legacy_semaphore_sessions_dir=$(resolve_orz_sessions_dir 2>/dev/null || true)
    if [ "$sessions_repo" != "$isolated_worktree" ]; then
      # находка 1 (WP-484, session 2026-09-16-18-wp484-fmt-orz-sessions-dir-patch
      # §5-6; fixed 2026-09-16, peer-session
      # 2026-09-16-22-wp484-close-mechanism-hard-snapshot, Claude+Kimi): this
      # call used to pass no semaphore/field args at all, so the scoped
      # fallback in _repo_head_has_publish_proof (guarded on a non-empty 3rd
      # arg) never engaged here -- every session hit the bare ancestry check,
      # which fails whenever MC-sessions has honestly diverged from
      # origin/main (routine under real concurrency: 15-20 sessions commit to
      # it daily, isolate-push republishes under a different SHA).
      #
      # own-field legacy fallback (WP-484, 17.09, peer-session
      # 2026-09-17-02-own-field-mirror-fix, Claude+Codex): this call used to
      # pass no legacy fallback at all, on the assumption that `open()`
      # writes `orz_sessions_dir:` unconditionally so this field can never be
      # absent on a modern semaphore -- disproved live the same week (this
      # session's OWN semaphore, opened before that write got a self-check,
      # had `governance_worktree:` but no `orz_sessions_dir:`). Only the own
      # field's fallback is wired here (`legacy_semaphore_sessions_dir`,
      # already resolved unconditionally a few lines above); the other
      # field's fallback is deliberately withheld pending its own
      # justification and test (Codex cold-review, same session) -- passing
      # it would silently widen this call's trust surface for a case this
      # fix does not need to cover.
      _repo_head_has_publish_proof "$sessions_repo" "sessions checkout" "$SEM_FILE" \
        "orz_sessions_dir" "governance_worktree" "$legacy_semaphore_sessions_dir" \
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
      if [ "$ABANDON_PREPARED" -eq 1 ]; then
        # Manual recovery (see header doc + _record_close_abandoned): the
        # cryptographic proof below can never pass once a later, legitimate
        # REPLACE lands on a path this PREPARED snapshot touched -- it only
        # distinguishes byte-identical delivery from divergence, not "lost"
        # from "delivered, then superseded". This branch swaps that proof for
        # an explicit, audited human attestation naming the exact commit set.
        #
        # Cold-review Critical (Codex+Claude peer-session): note-commit (WP-537)
        # can stage claims for commits in OTHER repos on this same semaphore
        # (close_delivery_claimed_commits) independently of source_commits, and
        # the normal path proves those too (_claimed_commits_have_publish_proof
        # below). The operator's --source-commit list only ever names
        # close_delivery_source_commits -- it says nothing about claimed
        # commits elsewhere. Rather than widen the attestation UX to also cover
        # an unbounded set of foreign-repo claims, refuse the manual path
        # outright when any exist: that case needs its own, separately
        # reasoned recovery, not a silent pass-through under this flag.
        claimed_json=$(_unique_record_field "$SEM_FILE" close_delivery_claimed_commits || true)
        [ "$claimed_json" = "[]" ] \
          || fail "close --abandon-prepared: у сессии есть note-commit заявки на коммиты в других репозиториях (close_delivery_claimed_commits не пуст) -- ручная attestation покрывает только close_delivery_source_commits, для этого случая нужен отдельный разбор" 7
        _abandon_prepared_matches_source "$SEM_FILE" "${ABANDON_SOURCE_COMMITS[@]}" \
          || fail "close --abandon-prepared: --source-commit список не совпадает ТОЧНО с close_delivery_source_commits (частичное подтверждение запрещено)" 7
        verified_json=$(_unique_record_field "$SEM_FILE" close_delivery_source_commits || true)
        source_status=$(_unique_record_field "$SEM_FILE" close_delivery_source_status_sha256 || true)
        terminal_sha=$(_unique_record_field "$SEM_FILE" close_delivery_terminal_sha256 || true)
        publish_digest=$(_record_close_abandoned "$SEM_FILE" "$SESSION_ID" "$prepare_digest" \
          "$verified_json" "$source_head" "$source_status" "$terminal_sha" "$AGENT") \
          || fail "close --abandon-prepared: attestation receipt не записан durable; PREPARED/worktree сохранены" 7
        [ "$(_close_delivery_state "$SEM_FILE" "$SESSION_ID" || true)" = "published" ] \
          || fail "close --abandon-prepared: записанный receipt не прошёл self-check" 7
        delivery_state="published"
        echo "⚠️  session-guard: PREPARED-снимок закрыт ВРУЧНУЮ (--abandon-prepared), без криптографического proof доставки. Коммиты: ${ABANDON_SOURCE_COMMITS[*]}. close_publish_proof=manual-abandon-attestation/v1 в семафоре — постоянный видимый в аудите след." >&2
      else
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
          || fail "close: не каждый PREPARED source commit доказан fresh origin/main exact OID или итоговым tree proof (нет доказательства доставки -- если содержимое доставлено, а более поздняя легитимная замена тех же строк ломает byte-exact proof, разбери вручную и рассмотри close --abandon-prepared)" 7
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
      fi
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
  # WP-484 (16.09, peer-session 2026-09-16-28-wp484-close-gate-triage,
  # Claude+Kimi): resolved unconditionally now, not only inside the "fully
  # legacy" branch below. A semaphore missing exactly ONE of the three scope
  # fields (e.g. governance_worktree present, orz_sessions_dir absent --
  # confirmed live on WP-568's semaphore, opened through a session-guard.sh
  # copy that wrote only the former) is not "structurally legacy" by the
  # check below, so it never reached this assignment before, and
  # _repo_scope_has_publish_proof's per-field fallback (see its own comment)
  # had nothing to fall back to for the one absent field. Both reads are
  # cheap and side-effect-free regardless of which fields the semaphore has.
  legacy_semaphore_canonical=$(git -C "$IWE_ROOT/$GOV_REPO" rev-parse --show-toplevel 2>/dev/null || true)
  legacy_semaphore_sessions_dir=$(resolve_orz_sessions_dir 2>/dev/null || true)
  if [ -z "$governance_repo" ] && [ -z "$isolated_worktree" ] \
     && ! grep -qE '^(governance_worktree|isolated_worktree|orz_sessions_dir): ' "$SEM_FILE"; then
    # Legacy semaphore predating governance_worktree/orz_sessions_dir
    # (WP-484, 14.09: opened by a session-guard.sh copy older than
    # e2d3a2423e, 12.09 -- confirmed live on two semaphores the same day).
    # Before --isolate existed every non-isolated session worked in the
    # canonical checkout unconditionally; restore that default here instead
    # of failing closed. Mirrors the fallback session_scope_dirty_paths()
    # already applies at the scope-check step.
    #
    # Scoped to the STRUCTURAL absence of all three fields, not merely to
    # semaphore_governance_worktree() returning empty (cold-review, Codex):
    # a modern semaphore can legitimately name an independent, non-canonical
    # governance_worktree that is currently unresolvable (gone, unreachable)
    # -- that case must stay fail-closed, since substituting canonical there
    # would silently accept a checkout that never actually owned the scope.
    governance_repo=$(git -C "$IWE_ROOT/$GOV_REPO" rev-parse --show-toplevel 2>/dev/null || true)
    # WP-484 Ф(peer-session 2026-09-14-13): the fallback above only fixed the
    # HEAD-ancestry check having *some* repo to test against.  It never let
    # the scoped fallback (_repo_scope_has_publish_proof) fire, because that
    # function still demanded a `governance_worktree:` line the legacy
    # semaphore structurally cannot have -- so a legacy semaphore with a
    # dirty/diverged canonical (own commits real, HEAD not an origin/main
    # ancestor because of unrelated foreign history) still failed closed on
    # the strict ancestry check with no fallback left to try. Recorded here,
    # not read from the semaphore, so the trust boundary is the caller's own
    # verified structural-absence check, never semaphore content.
    legacy_semaphore_canonical="$governance_repo"
    # A legacy semaphore also lacks orz_sessions_dir, and `open` always
    # registers the session's own ORZ scaffold file in scope -- without a
    # sessions checkout to check that path against, the scoped fallback
    # above refuses on it every time ("путь отсутствует или неоднозначен
    # между репозиториями"), found live testing this same phase. Best
    # effort: resolve_orz_sessions_dir() can itself fail() (e.g.
    # IWE_SESSIONS_ROOT set but broken) -- that must not abort close, since
    # this is an enrichment, not a requirement; an empty value here just
    # means the ORZ path stays unrecognized, same as before this fix.
    legacy_semaphore_sessions_dir=$(resolve_orz_sessions_dir 2>/dev/null || true)
    # P1(b), WP-484 п.19: pure diagnostic, no effect on the fallback above --
    # names which script version (if any) wrote this semaphore, so the next
    # incident like WP-573 (14.09, several unsynced session-guard.sh copies
    # on one host) is greppable from the semaphore itself instead of needing
    # a multi-agent git-archaeology session to even locate the drifted copy.
    _legacy_guard_schema=$(grep '^guard_schema: ' "$SEM_FILE" 2>/dev/null | head -1 | cut -d' ' -f2- || true)
    echo "Session CLOSE: legacy semaphore (структурно без governance_worktree/isolated_worktree/orz_sessions_dir) -- writer guard_schema=${_legacy_guard_schema:-отсутствует (написан копией старше введения этого поля)}, читает closer с guard_schema=$GUARD_SCHEMA_VERSION" >&2
  fi
  [ -n "$governance_repo" ] \
    || fail "close: governance checkout не доказан; clean/terminal transition запрещён" 7

  # A shared governance checkout may have foreign unpublished history.  Its
  # alternative proof covers this session's current exact output and declared
  # commits.  The independent sessions checkout keeps the strict HEAD proof.
  # Missing origin or a tracking ref is never implicit `clean`.
  #
  # WP-484 (16.09, peer-session 2026-09-16-13-wp484-close-drift-fix,
  # Claude+Kimi): a session that never touched the governance repo has
  # nothing to prove there. This check used to run unconditionally for every
  # non-isolated session regardless of scope, demanding the WHOLE shared
  # canonical checkout's HEAD be an ancestor of origin/main -- a checkout
  # that drifts constantly under real concurrency (other sessions committing
  # locally without pushing yet), so a session with zero footprint in this
  # repo failed for a divergence it had no part in.
  #
  # Cold-review Critical (same session, before deploy): gating on `commit:`
  # claims alone is not the same as "touched nothing" -- a session that
  # edited a file here (auto-tracked as a `file:` claim by
  # post-tool-use-scope-track.sh) and committed it directly, forgetting to
  # call `note-commit`, would previously fail closed on this exact check (its
  # unpublished HEAD commit fails the ancestor test, and the scoped fallback
  # also refuses with an empty `commit:` list) -- a real, if accidental,
  # safety net. Skipping whenever `commit:` is empty silently drops that net.
  # Fixed by requiring EITHER a `commit:` claim for this repo OR at least one
  # `file:` claim that resolves to a path actually present under
  # $governance_repo -- a session with neither has provably no footprint here
  # (nothing committed, nothing present to have been committed), so there is
  # still nothing to prove; a session with a stray `file:` claim under this
  # repo still runs the full check, the same as before this fix (rejected the
  # alternative of comparing HEAD against its value at `open`: in a shared
  # checkout that drifts from sibling sessions just as easily, that proves
  # nothing more than the existing ancestry check).
  GOVERNANCE_REPO_BASENAME=$(basename "$governance_repo")
  GOVERNANCE_REPO_HAS_FOOTPRINT=0
  if grep -qF "commit: ${GOVERNANCE_REPO_BASENAME} " "$SEM_FILE" 2>/dev/null; then
    GOVERNANCE_REPO_HAS_FOOTPRINT=1
  else
    # Second cold-review (same session): a bare `file:` claim is not
    # repo-qualified -- the same relative path can legitimately exist in more
    # than one repo (confirmed live: CLAUDE.md/AGENTS.md/.claude/settings.json
    # and several scripts/* exist verbatim in both $IWE_ROOT and every
    # governance checkout). A naive existence check alone would count a root
    # repo edit (e.g. this file's own CLAUDE.md) as governance-repo footprint
    # and re-trigger the exact false block this fix exists to remove -- not
    # rare, CLAUDE.md/AGENTS.md are edited routinely per this file's own §7.
    # Only trust a path as this session's governance-repo footprint when it
    # exists HERE and NOT at the same relative path under $IWE_ROOT; an
    # ambiguous path falls through with no footprint from this claim (still
    # picked up by the `commit:` signal above, or by another unambiguous
    # `file:` claim) rather than forcing a check that fails for unrelated
    # repo drift on a session that never touched this file here.
    while IFS= read -r _footprint_path; do
      _footprint_path="${_footprint_path#file: }"
      [ -n "$_footprint_path" ] || continue
      if [ -e "$governance_repo/$_footprint_path" ] && [ ! -e "$IWE_ROOT/$_footprint_path" ]; then
        GOVERNANCE_REPO_HAS_FOOTPRINT=1
        break
      fi
    done < <(grep '^file: ' "$SEM_FILE" 2>/dev/null || true)
  fi
  if [ -z "$isolated_worktree" ] && [ "$GOVERNANCE_REPO_HAS_FOOTPRINT" -eq 1 ]; then
    _repo_head_has_publish_proof "$governance_repo" "governance checkout" "$SEM_FILE" \
      "governance_worktree" "orz_sessions_dir" "$legacy_semaphore_canonical" "$legacy_semaphore_sessions_dir" \
      || fail "close: governance delivery не подтверждена; .open/lease/pointer сохранены" 7
  fi
  if [ -z "$isolated_worktree" ]; then
    _claimed_commits_have_publish_proof "$SEM_FILE" \
      || fail "close: один из session-owned commits не имеет точного publish proof; .open сохранён" 7
  fi

  if [ -n "$isolated_worktree" ]; then
    CLOSING_WORKTREE="$isolated_worktree"
    [ "$(realpath "$governance_repo" 2>/dev/null || echo "$governance_repo")" = \
      "$(realpath "$CLOSING_WORKTREE" 2>/dev/null || echo "$CLOSING_WORKTREE")" ] \
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
    # bug-2026-09-16-quick-close-session-release-circular-terminal-check.md,
    # peer-session 2026-09-17-14 (Kimi cold-review, conditional consensus):
    # _worktree_clean_status_sha treats ANY ignored path (scripts/__pycache__/,
    # lock files a pipeline step left behind) as unclean -- the same
    # false-positive class already fixed for night-cycle's own worktree
    # (clean_day_open_ignored_debris, commit 70225e28a), but this PREPARE-write
    # path had no equivalent call. -X only: never touches tracked or
    # untracked-but-not-ignored content, so it cannot discard real work.
    # Residual risk (Kimi): a deliberately-gitignored file that is NOT pipeline
    # debris (e.g. an uncommitted .env dropped into this isolated worktree)
    # would also be removed here -- but close already refused unconditionally
    # whenever such a file was present, so this can only unblock a session,
    # never silently discard something that used to close cleanly.
    # Best-effort by design (matches clean_day_open_ignored_debris) -- a clean
    # failure here just means the check below fails with its normal message.
    git -C "$CLOSING_WORKTREE" clean -fdX --quiet 2>/dev/null || true
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
    if ! _owner_pid_is_live_ancestor "$MACHINE_OWNER_PID"; then
      # Confirmed-dead owner is safe to reclaim: MACHINE_STATE=none means
      # nothing was delivered yet. See bug-2026-09-14-night-cycle-machine-close-dead-owner-permanent-deadlock.md.
      kill -0 "$MACHINE_OWNER_PID" 2>/dev/null \
        && fail "machine-close: initial transition требует живой записанный owner PID как ancestor" 7
      echo "session-guard: machine-close: owner PID $MACHINE_OWNER_PID мёртв, MACHINE_STATE=none -- reclaim initial close" >&2
    fi
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
  # WP-7 Ф83 (no flag silently ignored) applied to --abandon-prepared: without
  # this check the flag would be accepted and then simply never read, because
  # only a "prepared" delivery_state ever reaches the branch that consumes it
  # (cold-review, Codex+Claude peer-session, found live: --housekeeping exits
  # long before this point, and "none"/"published"/"cleaned" all skip the
  # PREPARED branch too) -- an operator would believe the manual attestation
  # ran when it silently did nothing.
  if [ "$ABANDON_PREPARED" -eq 1 ] && [ "$CLOSE_RESUME_STATE" != "prepared" ]; then
    fail "close --abandon-prepared: сессия не в состоянии PREPARED (сейчас: $CLOSE_RESUME_STATE) — флаг применим только к зависшему PREPARED-снимку, не к обычному закрытию" 7
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
  if [ -n "${IWE_GOVERNANCE_REPO_PATH:-}" ] \
     && [ "$IWE_GOVERNANCE_REPO_PATH" != "$IWE_ROOT/$GOV_REPO" ] \
     && [ "$IWE_GOVERNANCE_REPO_PATH" != "${SESSION_GOVERNANCE_WORKTREE:-}" ]; then
    DECLARED_CARD_DIR=$(_declared_governance_card_dir "$IWE_GOVERNANCE_REPO_PATH" "$IWE_ROOT/$GOV_REPO") \
      || fail "close: explicit governance worktree could not be verified" 7
    RUNNER_CARD_DIRS+=("$DECLARED_CARD_DIR")
  fi
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
  if [ -z "$HARNESS_SESSION_ID" ] && [ "${AGENT:-}" = "codex" ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
    HARNESS_SESSION_ID=$(_legacy_codex_harness_session_id "$SEM_FILE") \
      || fail "close: native Codex owner could not be tied to this exact guard session/worktree" 7
  fi
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
  # Preserve terminal proof selected by the session's declared close path.
  if [ -z "$RUNNER_OK" ]; then
    for card in "${RUNNER_CARDS[@]+"${RUNNER_CARDS[@]}"}"; do
      grep -q '^process_id: quick-close$' "$card" || continue
      grep -q '^status: completed$' "$card" || continue
      RUNNER_OK="$card"
      TERMINAL_PROOF_MODE="completed"
      break
    done
  fi

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
    # WP-484 п.16 (16.09, пир-сессия с Kimi): harness_session_id отсутствует в
    # семафоре у любой сессии без CLAUDE_CODE_SESSION_ID в окружении при open
    # -- не только легаси-семафоры, но и живые сессии, где переменная не
    # долетела во вложенный вызов. session_id: (эпохальный, из имени самого
    # семафора) пишется всегда -- тот же fail-closed фолбэк-паттерн (уникальное
    # непустое поле или ничего), что _orphaned_worktree_terminal_outcome_proven
    # уже применяет для той же развилки (:2278, через _unique_record_field).
    # Не решает случай неинтерактивных/плановых (launchd) сессий: у них
    # close_obligation обычно не армируется вовсе (record-intent висит на
    # UserPromptSubmit, событии интерактивного харнесса) -- cancel-status
    # ниже честно ответит "нечего отменять", а не притворится, что ID был
    # недостижим.
    CANCEL_LOOKUP_ID="$HARNESS_SESSION_ID"
    [ -n "$CANCEL_LOOKUP_ID" ] || CANCEL_LOOKUP_ID=$(_unique_record_field "${SEM_FILE:-}" session_id || true)
    if [ -n "$CANCEL_LOOKUP_ID" ] && [ -f "$OBLIGATION_CLI" ]; then
      CANCEL_STATUS=$(python3 "$OBLIGATION_CLI" cancel-status --session-id "$CANCEL_LOOKUP_ID" 2>/dev/null) || CANCEL_STATUS=""
      if [ -n "$CANCEL_STATUS" ] && [ "$(printf '%s' "$CANCEL_STATUS" | jq -r '.cancelled // false' 2>/dev/null)" = "true" ]; then
        RUNNER_OK="cancel-obligation:$CANCEL_LOOKUP_ID"
        TERMINAL_PROOF_MODE="sentinel"
        # Нет реальной карточки раннера -- пусть downstream-очистка (ниже, по
        # тому же признаку, что force-no-reflection) пойдёт по generic-пути
        # cancel-session без --exclude, не пытаясь grep run_id из синтетического
        # RUNNER_OK. FORCED_CARD гарантированно пуст здесь: этот блок выполняется
        # только когда RUNNER_OK ещё пуст, а force-no-reflection выше уже вышел бы
        # с непустым RUNNER_OK, если бы сам его установил.
        FORCED_CARD="cancel-obligation:$CANCEL_LOOKUP_ID"
        CANCEL_ACTION=$(printf '%s' "$CANCEL_STATUS" | jq -r '.action // "unknown"' 2>/dev/null)
        CANCEL_ACTOR=$(printf '%s' "$CANCEL_STATUS" | jq -r '.actor // "unknown"' 2>/dev/null)
        echo "Session CLOSE: раннер не завершён, но close-обязательство явно отменено пилотом ($CANCEL_ACTION, actor=$CANCEL_ACTOR) — признаю терминальным (WP-537)." >&2
      fi
    fi

    # WP-484 п.16: готовый текст-подсказка для fail()-сообщений ниже по коду --
    # вычисляется один раз здесь, где CANCEL_LOOKUP_ID гарантированно уже
    # присвоена (та же ветка `-z "$RUNNER_OK"`), а не дублируется в каждом
    # fail() (P2). Без CANCEL_LOOKUP_ID показывать псевдо-команду с
    # плейсхолдером вместо ID нечестно (агент-исполнитель может выполнить её
    # буквально) -- отдельная ветка без готовой к копипасту команды.
    if [ -n "$CANCEL_LOOKUP_ID" ]; then
      CANCEL_HINT="попроси пилота об явной отмене: python3 close_obligation.py cancel --session-id '$CANCEL_LOOKUP_ID' --action cancel-close. Сессия неинтерактивная/плановая (launchd) -- для таких close-обязательство обычно не заводится вовсе, отмена вернёт \"нечего отменять\": используй process-runner.py cancel <run-id> или ручной карантин семафора (S-33)"
    else
      CANCEL_HINT="явная отмена через close_obligation.py недоступна -- у этой сессии не определился ни harness_session_id, ни session_id семафора. Попроси пилота о ручном карантине семафора (S-33) или используй process-runner.py cancel <run-id>"
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
      fail "Quick Close не завершён для slug '$SLUG': карточка отменена на шаге wp-archive-run, но push не подтверждён (нет all_pushed:true и commit_needed:false) -- WP-537 признаёт этот шаг терминальным только с доказанным push. Проверь commit-push вручную, либо $CANCEL_HINT." 7
    elif [ -n "$CANCELLED_STEP" ]; then
      fail "Quick Close не завершён для slug '$SLUG': карточка отменена на шаге '$CANCELLED_STEP' -- это не автоматически безопасный терминальный шаг (только wp-archive-run с доказанным push признаётся без ручного вмешательства, WP-537) и нет отмены close-обязательства. Доведи раннер до wp-archive-run/completed, либо $CANCEL_HINT." 7
    fi
    fail "Quick Close не завершён для slug '$SLUG': нет terminal RUN-quick-close-${SLUG}*.md и нет отмены close-обязательства для этой сессии. Сначала запусти process-runner.py start quick-close с тем же --slug, либо $CANCEL_HINT." 7
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
  # WP-484 (21.09, пир-сессия 2026-09-21-08): --forget снимает заявку на путь,
  # которого больше нигде нет. Живой случай: `report-draft.md` создан хуком Write
  # (заявка ставится сама), затем переименован в `report.md` до первого коммита;
  # заявка осталась, проверка доставки при close считала путь «не найденным ни в
  # одном checkout» и отказывала, а снять её было нечем. Снятие безопасно только
  # когда доставлять нечего: путь отсутствует на диске, в HEAD и в индексе обоих
  # checkout сессии (governance и репозиторий сессий) и не входит в diff ни одного
  # заявленного коммита. Иначе заявка законна и остаётся. Содержимое коммитов
  # проверяется отдельно по commit-заявкам, поэтому снятие file-заявки не ослабляет
  # доказательство доставки того, что закоммичено.
  # Гонки: замок acquire_session_transition_lock выше держится на FD 196 весь процесс,
  # включая этот python-потомок; тот же замок берут open/close/note-file/note-commit,
  # поэтому снимок семафора не расходится с записью (проверка-и-замена под замком).
  if [ "$FORGET_FLAG" = "1" ]; then
    python3 - "$SEM_FILE" "$FILE_PATH" <<'PY' || exit $?
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sem, raw = sys.argv[1], sys.argv[2]


def refuse(message):
    sys.stderr.write("note-file --forget: " + message + "\n")
    sys.exit(1)


snapshot = Path(sem).read_bytes()
lines = snapshot.decode("utf-8").split("\n")


def field(name):
    values = [line.partition(": ")[2] for line in lines if line.startswith(name + ": ")]
    return values[-1] if values else ""


checkouts = []
for name in ("governance_worktree", "orz_sessions_dir"):
    path = field(name)
    if path and path not in checkouts:
        checkouts.append(path)
if not checkouts:
    refuse("в семафоре нет governance_worktree/orz_sessions_dir: не с чем сверять, заявка остаётся")

def valid_claim_path(value):
    # A recorded claim is a lexical repo-relative path: no absolute form, no
    # empty/dot/dot-dot component, no control characters. Anything else is not
    # something this command may reason about.
    return (bool(value) and not value.startswith("/")
            and not any(char in value for char in "\x00\r\n")
            and all(part not in ("", ".", "..") for part in value.rstrip("/").split("/")))


claims = {line[6:] for line in lines if line.startswith("file: ")}
candidates = []
if raw in claims and valid_claim_path(raw):
    candidates.append(raw)
if os.path.isabs(raw):
    real_target = os.path.realpath(raw)
    for checkout in checkouts:
        real_checkout = os.path.realpath(checkout)
        if os.path.commonpath([real_checkout, real_target]) != real_checkout:
            continue
        rel = os.path.relpath(real_target, real_checkout)
        if rel in claims and valid_claim_path(rel) and rel not in candidates:
            candidates.append(rel)
if not candidates:
    # A claim that only contains the path as one whitespace-separated part is withdrawn
    # by passing that line whole; name it instead of leaving the operator to guess.
    containing = sorted(claim for claim in claims if raw in claim.split())
    refuse("заявки на '" + raw + "' в scope этой сессии нет"
           + ("; есть заявка, содержащая этот путь как часть, для снятия передай её строку целиком: '"
              + containing[0] + "'" if containing else ""))
if any(char.isspace() for candidate in candidates for char in candidate):
    # Grammar: a claim is ONE literal path everywhere (close proof, scope gate,
    # note-file), spaces included -- `WeekPlan W39.md` is a legal name. A line that
    # only LOOKS like several paths (an unsplit shell variable) never claimed the
    # parts, so withdrawing it removes nothing from the scope; say so explicitly.
    sys.stderr.write("note-file --forget: заявка содержит пробелы и снимается как ОДИН путь; "
                     "отдельные части этой строкой не заявлялись\n")


def head_exists(checkout):
    return subprocess.run(["git", "-C", checkout, "rev-parse", "--verify", "-q", "HEAD^{commit}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def git(checkout, *args):
    result = subprocess.run(["git", "--literal-pathspecs", "-C", checkout, *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        refuse("не удалось проверить '" + checkout + "' (git " + args[0] + "), заявка остаётся")
    return result.stdout


# Every checkout the close proof may consult: the two session checkouts plus the
# repositories of the workspace. Each is checked for the path on disk, in HEAD, in the
# index and in recent history: a claim that one of them still holds may be legitimate
# for that repository, and withdrawing it would shrink the scope.
iwe_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(sem))))
workspace = [iwe_root]
for parent in (iwe_root, os.path.join(iwe_root, "DS-IT-systems")):
    try:
        workspace.extend(os.path.join(parent, name) for name in sorted(os.listdir(parent))
                         if os.path.isdir(os.path.join(parent, name)))
    except OSError:
        pass

# A commit claim of an unknown format is not something to reason around: fail closed.
claimed_commits = []
for line in lines:
    if not line.startswith("commit: "):
        continue
    fields = line[8:].split()
    if len(fields) != 2 or not re.fullmatch(r"[0-9a-fA-F]{40,64}", fields[1]):
        refuse("неоднозначная заявка коммита в семафоре ('" + line + "'): заявка остаётся")
    claimed_commits.append(fields[1])

# Every git checkout a declared commit may live in (the repo name in the claim is
# not trusted to pick one). A claim found nowhere cannot be examined: fail closed.
commit_homes = []
for candidate_home in checkouts + workspace:
    real_home = os.path.realpath(candidate_home)
    if os.path.lexists(os.path.join(real_home, ".git")) and real_home not in commit_homes:
        commit_homes.append(real_home)
for sha in claimed_commits:
    if not any(subprocess.run(["git", "-C", home, "cat-file", "-e", sha + "^{commit}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
               for home in commit_homes):
        refuse("заявленный коммит " + sha[:9] + " не найден ни в одном checkout: не могу проверить, заявка остаётся")

# A path that was ever committed on any branch or in the reflog of a workspace repo may
# have its only copy there (committed, never declared with note-commit, then reset away).
# No time window: `--since` filters by the committer date, which a clock skew or a
# GIT_COMMITTER_DATE moves. Claimed paths carry the session directory (date and slug), so a
# past touch of the very same path is a real signal, and a false refusal only keeps the claim.

for path in candidates:
    for checkout in checkouts:
        if os.path.lexists(os.path.join(checkout, path)):
            refuse("'" + path + "' есть на диске в " + checkout + ": доставить нужно, заявка законна")
    for home in commit_homes:
        # A repository without commits has an empty HEAD tree; any other git error stays fail-closed.
        if head_exists(home) and git(home, "ls-tree", "-z", "HEAD", "--", path).strip(b"\0"):
            refuse("'" + path + "' есть в HEAD " + home + ": заявка законна")
        if git(home, "ls-files", "-z", "--", path).strip(b"\0"):
            refuse("'" + path + "' есть в индексе " + home + ": заявка законна")
        if git(home, "log", "--all", "--reflog", "-1", "--format=%H", "--", path).strip():
            refuse("'" + path + "' встречается в истории (ветки/reflog) " + home + ": заявка может быть законной")
    for other in workspace:
        if os.path.lexists(os.path.join(other, path)):
            refuse("'" + path + "' есть на диске в " + other + ": заявка может быть законной для этого репозитория")
    for sha in claimed_commits:
        for home in commit_homes:
            if subprocess.run(["git", "-C", home, "cat-file", "-e", sha + "^{commit}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                continue
            # -m: a merge commit is compared with each parent, plain -r prints nothing for it
            names = git(home, "diff-tree", "-m", "--root", "--no-commit-id", "--name-only",
                        "--no-renames", "-r", "-z", sha).split(b"\0")
            if path.encode() in names:
                refuse("'" + path + "' входит в заявленный коммит " + sha[:9] + ": заявка законна")

drop = {"file: " + path for path in candidates}
kept = [line for line in lines if line not in drop]
if Path(sem).read_bytes() != snapshot:
    refuse("семафор изменился во время проверки, повтори")
# Durable audit: withdrawing a claim weakens the close proof by design, so it
# leaves a trace outside the semaphore (whose format stays unchanged) that
# survives the session. Written BEFORE the change ("intent"), then confirmed
# after it ("done"): a crash leaves an intent without completion, never a
# removal without a trace.
sem_dir = os.path.dirname(os.path.abspath(sem))
audit = os.path.join(os.path.dirname(sem_dir), "note-file-forget.log")


def audit_event(event):
    record = json.dumps({
        "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        "session_id": field("session_id"),
        "slug": field("slug"),
        "paths": candidates,
        "checked_checkouts": checkouts,
    }, ensure_ascii=False)
    data = memoryview((record + "\n").encode("utf-8"))
    fd = os.open(audit, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        # The audit log is shared by every session, and the per-session transition
        # lock does not serialize them: a lock on the log itself plus a full-write
        # loop keeps records whole (a plain O_APPEND write may be partial).
        fcntl.flock(fd, fcntl.LOCK_EX)
        while data:
            data = data[os.write(fd, data):]
        os.fsync(fd)
    finally:
        os.close(fd)


audit_event("forget-intent")
mode = os.stat(sem).st_mode & 0o7777
# mkstemp: O_EXCL, unpredictable name, never follows a planted symlink.
fd, tmp = tempfile.mkstemp(dir=sem_dir, prefix=".forget-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(kept))
        handle.flush()
        os.fchmod(handle.fileno(), mode)
        os.fsync(handle.fileno())
    os.replace(tmp, sem)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
dir_fd = os.open(sem_dir, os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
audit_event("forget-done")
print("Forgot in scope: " + ", ".join(candidates))
PY
    exit 0
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
  # the root's basename is accepted as an alias for the same directory
  # (_resolve_repo_checkout owns both spellings now).
  NC_ROOT_ALIAS="iwe-root"
  if [ -n "$REPO_ARG" ]; then
    # cold review: ".." or a leading "/" would resolve outside $IWE_ROOT while
    # the failure message below still (falsely) claims the check happened.
    case "$REPO_ARG" in
      */*|*..*) fail "note-commit: --repo '$REPO_ARG' должен быть именем каталога внутри $IWE_ROOT без '/' и '..'" 1 ;;
    esac
    # Same resolver the READER of this claim uses (_resolve_repo_checkout):
    # a name this writer accepts but the reader cannot resolve is exactly the
    # defect WP-537 found on 19.09 -- nested checkouts (DS-MCP/*,
    # DS-IT-systems/*) were recorded and then rejected at close.
    NC_REPO_DIR=$(_resolve_repo_checkout "$REPO_ARG" "$COMMIT_SHA") || {
      case $? in
        3) fail "note-commit: '$REPO_ARG' — имя нескольких checkout с РАЗНЫМИ origin; формат заявки 'commit: <репозиторий> <sha>' их не различает, поэтому такой коммит заявить нельзя (вызов из каталога без --repo запишет то же самое имя и упрётся в то же самое)" 1 ;;
        *) fail "note-commit: '$REPO_ARG' не найден среди известных checkout (корень, \$IWE_ROOT/*, DS-MCP/*, DS-IT-systems/*); сам корневой репозиторий заявляется как --repo $NC_ROOT_ALIAS" 1 ;;
      esac
    }
  else
    NC_REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$NC_REPO_DIR" ] \
      || fail "note-commit: текущий каталог вне git-контекста и --repo не задан — репозиторий определить нечем" 1
  fi
  if [ "$(realpath "$NC_REPO_DIR" 2>/dev/null || echo "$NC_REPO_DIR")" = "$(realpath "$IWE_ROOT" 2>/dev/null || echo "$IWE_ROOT")" ]; then
    NC_REPO_NAME="$NC_ROOT_ALIAS"
  elif [ -n "$REPO_ARG" ]; then
    # Record the name the caller ASKED for, not the basename of the resolved
    # directory. _resolve_repo_checkout returns a physical path, so for a
    # symlink whose own name differs from its target's ($IWE_ROOT/service ->
    # /external/service-checkout) the basename would silently rename the claim
    # to one the reader then looks for in the wrong place (Codex cold review,
    # 19.09). The resolver already proved this name maps to exactly one
    # checkout, so it is the safe spelling to store.
    NC_REPO_NAME="$REPO_ARG"
  else
    # A LINKED WORKTREE's own basename is meaningless to every reader: an
    # isolated session's worktree is named after the session id and lives
    # under .iwe-runtime/, so a claim recorded as
    # "commit: claude-code-1789831272-656a <sha>" can never be resolved back
    # to a repository. Record the CANONICAL repo's name instead -- the same
    # "the writer must record a name the reader can resolve" rule this phase
    # fixed for nested checkouts, caught live while closing the very session
    # that fixed the first half (WP-537 Ф32).
    #
    # For an ordinary checkout --git-common-dir is "<root>/.git", so its
    # parent IS the root and this branch changes nothing.
    NC_COMMON_DIR=$(git -C "$NC_REPO_DIR" rev-parse --path-format=absolute \
      --git-common-dir 2>/dev/null || true)
    NC_CANONICAL_ROOT=""
    [ -n "$NC_COMMON_DIR" ] && NC_CANONICAL_ROOT=$(dirname "$NC_COMMON_DIR")
    if [ -n "$NC_CANONICAL_ROOT" ] && [ -d "$NC_CANONICAL_ROOT" ] \
       && [ "$NC_CANONICAL_ROOT" != "$NC_REPO_DIR" ]; then
      NC_REPO_DIR="$NC_CANONICAL_ROOT"
      if [ "$(realpath "$NC_REPO_DIR" 2>/dev/null || echo "$NC_REPO_DIR")" \
           = "$(realpath "$IWE_ROOT" 2>/dev/null || echo "$IWE_ROOT")" ]; then
        NC_REPO_NAME="$NC_ROOT_ALIAS"
      else
        NC_REPO_NAME=$(basename "$NC_REPO_DIR")
      fi
    else
      NC_REPO_NAME=$(basename "$NC_REPO_DIR")
    fi
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
  # WP-484 п.24а3 (systemic fix, 17.09): frozen_checkout_match() refuses a
  # FRESH `open` against the canonical checkout without --isolate/
  # --canonical-owner (see the freeze block above `open`'s guard), but this
  # command extends an ALREADY-open session's commit rights without ever
  # re-running that check -- a session that got in before drift accumulated
  # could renew indefinitely against an increasingly stale canonical checkout.
  # This is how the 178-commit divergence of 16.09 grew unnoticed across many
  # renewals. governance_worktree: records the exact repo path this session
  # writes to (an isolated session records its own worktree there, which
  # never matches a frozen canonical path -- this check is a structural no-op
  # for isolated sessions, not a special case).
  RENEW_WORKTREE=$(sed -n 's/^governance_worktree: //p' "$SEM_FILE" 2>/dev/null | head -1)
  if [ -n "$RENEW_WORKTREE" ] && [ "${#FROZEN_CANONICAL_PATHS[@]}" -gt 0 ]; then
    RENEW_WT_REAL=$(realpath "$RENEW_WORKTREE" 2>/dev/null || echo "$RENEW_WORKTREE")
    RENEW_FROZEN=false
    for _frozen in "${FROZEN_CANONICAL_PATHS[@]}"; do
      [ "$RENEW_WT_REAL" = "$(realpath "$_frozen" 2>/dev/null || echo "$_frozen")" ] \
        && RENEW_FROZEN=true && break
    done
    if $RENEW_FROZEN && [ -z "$UNFREEZE_REASON" ]; then
      # Read-only: git fetch only updates the remote-tracking ref, never
      # HEAD/index/worktree -- same "safe" class as iwe-safe-pull.sh and
      # day-close-prepare.sh's own canon-drift check (12.6 CANON DRIFT).
      # Best-effort: a network hiccup must not block a legitimate renewal,
      # it only means the drift check is skipped for this tick.
      if timeout 10 git -C "$RENEW_WORKTREE" fetch origin main --quiet 2>/dev/null; then
        RENEW_BEHIND=$(git -C "$RENEW_WORKTREE" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
        if [ "$RENEW_BEHIND" -ge 10 ]; then
          fail "renew: канонический checkout ($RENEW_WORKTREE) отстал от origin на $RENEW_BEHIND коммитов с момента open -- продление приостановлено, чтобы расхождение не росло молча. Закрой сессию и открой заново (пройдёт свежую проверку freeze/--isolate), либо явно подтверди риск: renew ... --reason '<причина>'." 1
        fi
      fi
    fi
  fi
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

# WP-484 2026-09-14: "unknown"/"day-close" are the two literal wp: values
# peer-conversation/SKILL.md prescribes for a session with no work product.
# They're a separate legitimate category, checked before -- not instead of --
# the WP-N format check below: real WP-N values still must match it exactly.
# Scoped to this loop only: validate_identity() and the orphaned-scheduled/
# recovery-pending loop below always expect a real WP-N by design. New
# sentinel -> extend this set, don't fork a second list.
NON_PRODUCT_WP_SENTINELS = {"UNKNOWN", "DAY-CLOSE"}

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
        # WP-7 Ф154 (2026-09-17, live production incident): a bare-number --wp
        # (e.g. `--wp 578`, no "WP-" prefix) is documented, real historical
        # usage (cold-review finding, same phase: `--wp 149`/`--wp 289` in
        # existing bug/session records) -- `open`/`--isolate` already accept
        # it. This classifier didn't, so a session opened that way raised
        # ValueError below and SystemExit(2) turned into a repo-wide "fail
        # closed" commit barrier for EVERY agent, not just its own session --
        # caught live when a throwaway --wp 578 test session blocked an
        # unrelated commit in a different worktree. Normalize before
        # validating, so active_wps stores the same canonical WP-N form the
        # orphaned-marker loop below already requires.
        if re.fullmatch(r"[1-9][0-9]*", wp):
            wp = "WP-" + wp
        if wp in NON_PRODUCT_WP_SENTINELS:
            # A sentinel must not double as a way to dodge an active per-WP freeze.
            # `file:` lines are the session's touched-path scope and routinely
            # name a real WP-N folder for legitimate reasons (e.g. filing a bug
            # report into that WP's inbox from a no-WP session) -- that's not
            # evidence of evasion, so they're excluded from this scan.
            # `task:` is free text the session opener chose (WP-484, 14.09,
            # live false positive): a no-WP session routinely narrates a real
            # WP-N in its own task description (e.g. "разбор находки WP-484")
            # without touching that WP's scope at all. Scanning it the same
            # way as any other line turned an ordinary parallel session into
            # a repo-wide commit barrier for every agent, not just itself.
            if any(
                re.search(r"\bWP-[1-9][0-9]*\b", line, re.I)
                for line in text.splitlines()
                if not line.startswith("file: ") and not line.startswith("task: ")
            ):
                raise ValueError("non-product wp sentinel references a real WP")
            continue
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
