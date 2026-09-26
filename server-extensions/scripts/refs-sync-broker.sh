#!/usr/bin/env bash
# WP-530 Ф66 Требование А: refs-only sync broker (peer-session
# 2026-09-25-16-wp530-instant-sync-mandatory-reopen, round 3 with Codex,
# ArchGate-approved design). Fetches an EXPLICIT refspec per registered repo
# into refs/remotes/* only -- never touches the working tree or index, so a
# dirty/frozen canonical checkout (WP-520) is never an obstacle to VISIBILITY
# of a new origin commit. Merging into the working tree is a separate,
# unrelated stage (session-guard.sh's own freeze/isolate machinery already
# owns that) -- this script does not attempt it and never will. The
# registry (refs-sync-broker.repos.yaml) is trusted to name real remote-
# tracking destinations; this script itself REJECTS any entry that doesn't
# (cold review, 2026-09-26, Critical finding) rather than relying solely on
# registry review to keep that invariant.
#
# Honest scope limit (agreed in the peer session, not hidden): this is a
# short-poll broker (run on an interval by launchd/systemd/cron), not a real
# push-webhook. Detection latency is bounded by the poll interval, not
# instant. A push-triggered version would need a signal from the existing
# publish path (isolate-push.sh/ds-publish.sh) into this broker -- flagged as
# follow-up work in the WP-530 card, not implemented here (those scripts are
# used everywhere; wiring a new side-effect into them deserves its own
# reviewed change, not a rider on this one).
#
# Own state space, not a session-guard semaphore (Codex, round 3): this is a
# scheduled process like day-close-mechanical.sh, not an agent session. A
# non-blocking flock means a second concurrent invocation exits quietly
# instead of contending for or preempting the first; a stale heartbeat is an
# observability signal for a human, never an automatic license to steal the
# lock from a still-live process.
set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
REGISTRY="${REFS_SYNC_REGISTRY:-$IWE_ROOT/scripts/refs-sync-broker.repos.yaml}"
# NOT $IWE_RUNTIME -- that env var is already claimed platform-wide (see
# .claude/settings.json) as an agent-runtime IDENTIFIER ("claude-code"), not
# a path; the same real-world bug already found and fixed in
# wp-reopen-gate.sh on 2026-09-26. Follow session-guard.sh's own convention:
# no env override, always $IWE_ROOT/.iwe-runtime.
STATE_DIR="$IWE_ROOT/.iwe-runtime/refs-sync-broker"
LOCK_FILE="$STATE_DIR/broker.lock"
HEARTBEAT_FILE="$STATE_DIR/heartbeat.json"
LOG_FILE="$STATE_DIR/broker.log"
STALE_AFTER_SECONDS="${REFS_SYNC_STALE_AFTER:-180}"   # ~3x the intended 60s poll interval
FETCH_TIMEOUT_SECONDS="${REFS_SYNC_FETCH_TIMEOUT:-30}"

mkdir -p "$STATE_DIR"

# Resolved once, used for the traversal check in run_once. Comparing a
# realpath'd candidate against the RAW $IWE_ROOT is a real bug on macOS,
# where /var is itself a symlink to /private/var -- mktemp-style paths stay
# unresolved while `pwd -P` resolves every symlink, so a perfectly legitimate
# path would (and did, caught by the smoke suite) fail the check. Both sides
# must go through the same resolution.
IWE_ROOT_RESOLVED=$(cd "$IWE_ROOT" 2>/dev/null && pwd -P) || IWE_ROOT_RESOLVED="$IWE_ROOT"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }

require_registry() {
  [ -f "$REGISTRY" ] || { echo "refs-sync-broker: registry not found: $REGISTRY" >&2; exit 1; }
}

# Validates and prints "path<TAB>remote<TAB>refspec" per registered repo, one
# repo per line, to stdout -- but ONLY if every entry in the registry is
# valid. Any invalid entry (missing key, refspec not targeting
# refs/remotes/*, path escaping IWE_ROOT) fails the WHOLE call loudly (exit
# 1, nothing on stdout, reasons on stderr) rather than silently dropping
# just that one entry -- a partially-broken registry must not look like a
# healthy, narrower one (cold review, 2026-09-26, High finding: process
# substitution used to swallow this kind of parse failure entirely).
read_registry() {
  python3 -c "
import sys
try:
    import yaml
except ImportError:
    print('ERROR: pyyaml not available', file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}

repos = data.get('repos')
if not isinstance(repos, list):
    print('ERROR: registry top-level \"repos\" must be a list', file=sys.stderr)
    sys.exit(1)

errors = []
lines = []
for i, repo in enumerate(repos):
    if not isinstance(repo, dict):
        errors.append(f'entry {i}: not a mapping')
        continue
    path = repo.get('path')
    refspec = repo.get('refspec')
    remote = repo.get('remote', 'origin')
    if not path or not isinstance(path, str):
        errors.append(f'entry {i}: missing or non-string \"path\"')
        continue
    if '..' in path.split('/'):
        errors.append(f'entry {i} ({path}): \"path\" must not contain \"..\" segments')
        continue
    if not refspec or not isinstance(refspec, str):
        errors.append(f'entry {i} ({path}): missing or non-string \"refspec\"')
        continue
    dest = refspec.split(':', 1)[-1] if ':' in refspec else ''
    if not dest.lstrip('+').startswith('refs/remotes/'):
        errors.append(f'entry {i} ({path}): refspec destination must target refs/remotes/*, got {refspec!r}')
        continue
    lines.append(f'{path}\t{remote}\t{refspec}')

if errors:
    for e in errors:
        print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)

for line in lines:
    print(line)
" "$REGISTRY"
}

write_heartbeat() {
  local fetched="$1" failed="$2" status="$3" tmp
  tmp=$(mktemp "${HEARTBEAT_FILE}.tmp.XXXXXX")
  python3 -c "
import json, sys
print(json.dumps({'ts': int(sys.argv[1]), 'fetched': int(sys.argv[2]), 'failed': int(sys.argv[3]), 'status': sys.argv[4], 'pid': int(sys.argv[5])}))
" "$(date -u +%s)" "$fetched" "$failed" "$status" "$$" > "$tmp"
  mv -f "$tmp" "$HEARTBEAT_FILE"
}

run_once() {
  require_registry
  local registry_out fetched=0 failed=0
  registry_out=$(mktemp)
  if ! read_registry > "$registry_out" 2>>"$LOG_FILE"; then
    log "ABORT: registry validation failed, see errors above -- no repo was fetched this run"
    rm -f "$registry_out"
    write_heartbeat 0 0 "registry_invalid"
    exit 1
  fi

  local path remote refspec full_path resolved
  while IFS=$'\t' read -r path remote refspec; do
    [ -n "$path" ] || continue
    full_path="$IWE_ROOT/$path"
    # Belt-and-suspenders against the registry's own ".." guard: resolve the
    # real path and re-check it stays under IWE_ROOT (symlink escape, not
    # just a textual ".." segment) -- cold review, 2026-09-26, Medium finding.
    if resolved=$(cd "$full_path" 2>/dev/null && pwd -P); then
      case "$resolved" in
        "$IWE_ROOT_RESOLVED"|"$IWE_ROOT_RESOLVED"/*) : ;;
        *) log "SKIP $path: resolves outside IWE_ROOT ($resolved) -- refusing"; failed=$((failed + 1)); continue ;;
      esac
    fi
    if [ ! -e "$full_path/.git" ]; then
      log "SKIP $path: no .git at $full_path"
      continue
    fi
    local fetch_rc=0
    GIT_TERMINAL_PROMPT=0 timeout "$FETCH_TIMEOUT_SECONDS" git -C "$full_path" fetch --no-tags "$remote" "$refspec" >>"$LOG_FILE" 2>&1 || fetch_rc=$?
    if [ "$fetch_rc" -eq 0 ]; then
      fetched=$((fetched + 1))
      log "OK $path <- $remote $refspec"
    else
      failed=$((failed + 1))
      log "FAIL $path <- $remote $refspec (exit $fetch_rc, timeout ${FETCH_TIMEOUT_SECONDS}s)"
    fi
  done < "$registry_out"
  rm -f "$registry_out"
  write_heartbeat "$fetched" "$failed" "ok"
}

cmd_run() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "SKIP: another broker instance holds the lock"
    exit 0
  fi
  run_once
}

cmd_status() {
  if [ ! -f "$HEARTBEAT_FILE" ]; then
    echo "state=never_run"
    return
  fi
  local ts age
  ts=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ts', 0))" "$HEARTBEAT_FILE")
  age=$(( $(date -u +%s) - ts ))
  if [ "$age" -gt "$STALE_AFTER_SECONDS" ]; then
    echo "state=stale age_seconds=$age"
  else
    echo "state=fresh age_seconds=$age"
  fi
  cat "$HEARTBEAT_FILE"
}

main() {
  case "${1:-}" in
    run) cmd_run ;;
    status) cmd_status ;;
    *) echo "Usage: refs-sync-broker.sh run|status" >&2; exit 1 ;;
  esac
}

main "$@"
