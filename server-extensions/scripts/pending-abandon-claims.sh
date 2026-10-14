#!/usr/bin/env bash
# Read-only aggregator: finds stuck PREPARED close snapshots for a given WP
# across .iwe-runtime/sessions/*.open* and prints a ready `--abandon-prepared`
# command for each unambiguous one, instead of making the operator hunt each
# semaphore's close_delivery_source_commits by hand (WP-484, peer-session
# 2026-10-14-19-semaphore-bypass-proof-gap, Claude+Kimi+Codex).
#
# A file counts as a stuck PREPARED snapshot only if it has
# close_delivery_source_commits AND close_prepared_tree (the marker a normal
# close also sets while PREPARED, before close_publish_proof lands a few
# lines later in the same append) but NOT close_publish_proof. Filtering on
# "no close_publish_proof" alone would also catch an in-flight normal close
# mid-append (Kimi, round 1) -- requiring close_prepared_tree narrows it to
# snapshots that reached PREPARED and then never got a publish/abandon
# record at all, not a close caught between two appends of the same call.
#
# Scope deliberately stops at listing candidates (Codex, round 1): this
# script does not call session-guard.sh and does not abandon anything. A
# semaphore whose `wp:` is missing or does not look like `WP-<digits>` is
# printed under "неоднозначные", not auto-matched by slug.
set -euo pipefail

usage() {
  echo "Использование: $0 <WP-N>" >&2
  echo "Пример: $0 WP-521" >&2
  exit 1
}

[ $# -eq 1 ] || usage
WP_ARG="$1"
WP_NUM="${WP_ARG#WP-}"
[[ "$WP_NUM" =~ ^[0-9]+$ ]] || usage

SESSIONS_ROOT="${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/sessions"
[ -d "$SESSIONS_ROOT" ] || { echo "нет каталога $SESSIONS_ROOT" >&2; exit 1; }

found_match=0
found_ambiguous=0

for f in "$SESSIONS_ROOT"/*.open*; do
  [ -f "$f" ] || continue
  # Assumes one semaphore file holds at most one close-attempt block (no
  # repeated close_delivery_source_commits/close_publish_proof pairs) --
  # true for every file on disk as of 2026-10-14; -m1 below takes the first
  # match, which would be stale if that assumption ever breaks.
  grep -q '^close_delivery_source_commits:' "$f" 2>/dev/null || continue
  grep -q '^close_prepared_tree:' "$f" 2>/dev/null || continue
  grep -q '^close_publish_proof:' "$f" 2>/dev/null && continue

  file_wp=$(grep -m1 '^wp: ' "$f" 2>/dev/null | sed 's/^wp: *//') || true
  session_id=$(grep -m1 '^session_id: ' "$f" 2>/dev/null | sed 's/^session_id: *//') || true
  commits_line=$(grep -m1 '^close_delivery_source_commits:' "$f" 2>/dev/null | sed 's/^close_delivery_source_commits: *//') || true

  if [[ "$file_wp" =~ ^(WP-?)?0*${WP_NUM}$ ]]; then
    found_match=1
    echo "=== $f ==="
    echo "session_id: $session_id"
    echo "коммиты: $commits_line"
    commit_flags=$(python3 -c "
import json, sys
commits = json.loads(sys.argv[1])
print(' '.join('--source-commit ' + c for c in commits))
" "$commits_line" 2>/dev/null) || commit_flags=""
    if [ -n "$commit_flags" ]; then
      echo "команда: bash \${IWE_SCRIPTS:-\$HOME/IWE/scripts}/session-guard.sh close --abandon-prepared --i-understand-loss-risk $commit_flags --reason \"<причина>\""
    else
      echo "команда: не удалось распарсить close_delivery_source_commits как JSON-список -- разобрать вручную"
    fi
    echo
  elif [ -z "$file_wp" ] || [[ ! "$file_wp" =~ ^(WP-?)?[0-9]+$ ]]; then
    found_ambiguous=1
    echo "НЕОДНОЗНАЧНО (нет валидного wp: в frontmatter) -- $f (session_id: $session_id)" >&2
  fi
done

if [ "$found_match" -eq 0 ]; then
  echo "Незакрытых PREPARED-снимков для $WP_ARG не найдено." >&2
fi
if [ "$found_ambiguous" -eq 1 ]; then
  echo "Есть неоднозначные записи (см. stderr выше) -- разобрать отдельно, не по номеру РП." >&2
fi
