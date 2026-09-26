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

# Both the log file AND stderr (cold review's own tsekh-1 incident,
# 2026-09-26): systemd's journal only ever sees this process's stderr, not
# broker.log -- a FATAL written only to the file is invisible to
# `systemctl status`/journalctl, exactly the gap that let the missing-flock
# failure look silent from the operator's side even though the log file
# itself was accurate the whole time.
log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  printf '%s\n' "$line" >> "$LOG_FILE"
  printf '%s\n' "$line" >&2
}

require_registry() {
  [ -f "$REGISTRY" ] || { echo "refs-sync-broker: registry not found: $REGISTRY" >&2; exit 1; }
}

# Validates and prints "path<TAB>remote<TAB>refspec<TAB>optional" per repo, one
# repo per line, to stdout -- but ONLY if every entry in the registry is
# valid. Any invalid entry (missing key, refspec not targeting
# refs/remotes/*, path escaping IWE_ROOT) fails the WHOLE call loudly (exit
# 1, nothing on stdout, reasons on stderr) rather than silently dropping
# just that one entry -- a partially-broken registry must not look like a
# healthy, narrower one (cold review, 2026-09-26, High finding: process
# substitution used to swallow this kind of parse failure entirely).
read_registry() {
  python3 -c "
import re, sys
try:
    import yaml
except ImportError:
    print('ERROR: pyyaml not available', file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}

repos = data.get('repos')
if not isinstance(repos, list) or not repos:
    print('ERROR: registry top-level \"repos\" must be a nonempty list', file=sys.stderr)
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
    optional = repo.get('optional', False)
    if not isinstance(optional, bool):
        errors.append(f'entry {i}: optional must be a boolean')
        continue
    if not isinstance(remote, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*', remote):
        errors.append(f'entry {i}: invalid remote name')
        continue
    if not path or not isinstance(path, str):
        errors.append(f'entry {i}: missing or non-string \"path\"')
        continue
    if path.startswith('/') or any(c in path for c in '\\t\\r\\n') or '..' in path.split('/'):
        errors.append(f'entry {i} ({path}): \"path\" must not contain \"..\" segments')
        continue
    if not refspec or not isinstance(refspec, str):
        errors.append(f'entry {i} ({path}): missing or non-string \"refspec\"')
        continue
    dest = refspec.split(':', 1)[-1] if ':' in refspec else ''
    if any(c.isspace() for c in refspec) or not dest.startswith('refs/remotes/'):
        errors.append(f'entry {i} ({path}): refspec destination must target refs/remotes/*, got {refspec!r}')
        continue
    lines.append(f'{path}\t{remote}\t{refspec}\t{str(optional).lower()}')

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

  local path remote refspec optional full_path resolved
  while IFS=$'\t' read -r path remote refspec optional; do
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
      if [ "$optional" = true ]; then
        log "SKIP $path: optional repository absent at $full_path"
      else
        log "FAIL $path: required repository absent at $full_path"
        failed=$((failed + 1))
      fi
      continue
    fi
    local fetch_rc=0
    GIT_TERMINAL_PROMPT=0 timeout --kill-after=5s "$FETCH_TIMEOUT_SECONDS" git -C "$full_path" fetch \
      --no-tags --no-recurse-submodules --no-auto-maintenance --no-write-fetch-head \
      --refmap= "$remote" "$refspec" >>"$LOG_FILE" 2>&1 || fetch_rc=$?
    if [ "$fetch_rc" -eq 0 ]; then
      fetched=$((fetched + 1))
      log "OK $path <- $remote $refspec"
    else
      failed=$((failed + 1))
      log "FAIL $path <- $remote $refspec (exit $fetch_rc, timeout ${FETCH_TIMEOUT_SECONDS}s)"
    fi
  done < "$registry_out"
  rm -f "$registry_out"
  if [ "$failed" -gt 0 ]; then
    write_heartbeat "$fetched" "$failed" "failed"
    return 1
  fi
  if [ "$fetched" -eq 0 ]; then
    log "FAIL: no repositories were fetched"
    write_heartbeat 0 0 "no_repositories"
    return 1
  fi
  write_heartbeat "$fetched" "$failed" "ok"
}

cmd_run() {
  # Not "SKIP: lock held" -- a missing flock binary looks EXACTLY like a
  # held lock to the check below (bash reports "command not found", exit
  # 127, which the `if ! flock ...` negation happily treats as "contended"),
  # and every run since would log a plausible-sounding SKIP forever while
  # never fetching anything -- silence that looks identical to healthy.
  # Live incident, 2026-09-26: tsekh-1's systemd unit PATH (commonPath in
  # modules/systemd-timers.nix) didn't include util-linux, so THIS exact
  # failure mode fired on every single invocation post-deploy.
  command -v flock >/dev/null 2>&1 || { log "FATAL: flock binary not found in PATH -- cannot take the run lock"; exit 1; }
  exec 9>"$LOCK_FILE"
  local lock_rc=0
  flock -n 9 || lock_rc=$?
  if [ "$lock_rc" -eq 1 ]; then
    log "SKIP: another broker instance holds the lock"
    return 0
  elif [ "$lock_rc" -ne 0 ]; then
    log "FATAL: flock failed (exit $lock_rc)"
    return "$lock_rc"
  fi
  run_once
}

cmd_status() {
  if [ ! -f "$HEARTBEAT_FILE" ]; then
    echo "state=never_run"
    return 1
  fi
  local heartbeat_fields ts age status failed snapshot
  snapshot=$(cat "$HEARTBEAT_FILE")
  if ! heartbeat_fields=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert isinstance(data.get("ts"), int) and data["ts"] > 0
assert isinstance(data.get("failed"), int) and data["failed"] >= 0
assert isinstance(data.get("status"), str)
print(data["ts"], data["failed"], data["status"])
' "$snapshot" 2>/dev/null); then
    echo "state=invalid_heartbeat"
    return 1
  fi
  read -r ts failed status <<< "$heartbeat_fields"
  age=$(( $(date -u +%s) - ts ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$STALE_AFTER_SECONDS" ]; then
    echo "state=stale age_seconds=$age"
    printf '%s\n' "$snapshot"
    return 1
  elif [ "$status" != ok ] || [ "$failed" -gt 0 ]; then
    echo "state=failed age_seconds=$age reason=$status"
    printf '%s\n' "$snapshot"
    return 1
  fi
  echo "state=fresh age_seconds=$age"
  printf '%s\n' "$snapshot"
}

main() {
  case "${1:-}" in
    run) cmd_run ;;
    status) cmd_status ;;
    *) echo "Usage: refs-sync-broker.sh run|status" >&2; exit 1 ;;
  esac
}

main "$@"
