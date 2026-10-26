#!/usr/bin/env bash
# session-guard-peer-evidence-smoke.sh -- WP-484 (26.10, peer-session 2026-10-26-19).
# close_path=peer-session is declared at open and was never checked: 3 of 9 such
# closes that day were ordinary work sessions. peer_session_evidence() reports
# whether the declaration has a trace of a real peer session (journal folder with
# 00-writer.md or meta.yaml, or an ORZ of type: peer-session). The function is
# extracted from the shipped session-guard.sh, so the test cannot drift from it,
# and it runs under `set -euo pipefail` like the script itself.
set -euo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/session-guard.sh"
[ -f "$GUARD" ] || { echo "FAIL: $GUARD not found"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

python3 - "$GUARD" "$SANDBOX/fn.sh" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").split("\n")
start = next(i for i, line in enumerate(lines) if line.startswith("peer_session_evidence() {"))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
Path(sys.argv[2]).write_text("\n".join(lines[start:end + 1]), encoding="utf-8")
PY
# shellcheck source=/dev/null
. "$SANDBOX/fn.sh"

PASS=0
FAIL=0
check() { # <name> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok: $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected '$3', got '$2')"; fi
}

ORZ="$SANDBOX/orz"
SEM="$SANDBOX/sem"
mkdir -p "$ORZ/2026-10/26"
printf 'wp: WP-1\nslug: s\n' > "$SEM"

check "another close path is not judged" \
  "$(peer_session_evidence quick-close "$SEM" plain-work "$ORZ")" "n/a"

check "peer-session without any trace is flagged" \
  "$(peer_session_evidence peer-session "$SEM" plain-work "$ORZ")" "no"

mkdir -p "$ORZ/2026-10/26/real-peer"
: > "$ORZ/2026-10/26/real-peer/00-writer.md"
check "journal folder with 00-writer.md counts" \
  "$(peer_session_evidence peer-session "$SEM" real-peer "$ORZ")" "yes"

mkdir -p "$ORZ/2026-10/25/meta-only"
: > "$ORZ/2026-10/25/meta-only/meta.yaml"
check "journal folder with meta.yaml counts, on any day" \
  "$(peer_session_evidence peer-session "$SEM" meta-only "$ORZ")" "yes"

mkdir -p "$ORZ/2026-10/26/empty-folder"
check "an empty folder is not evidence" \
  "$(peer_session_evidence peer-session "$SEM" empty-folder "$ORZ")" "no"

printf 'orz_file: 2026-10/typed.md\n' > "$SEM"
mkdir -p "$ORZ/2026-10"
printf -- '---\ntype: peer-session\n---\n' > "$ORZ/2026-10/typed.md"
check "ORZ of type peer-session counts" \
  "$(peer_session_evidence peer-session "$SEM" no-folder "$ORZ")" "yes"

printf -- '---\ntype: work\n---\n' > "$ORZ/2026-10/typed.md"
check "ORZ of type work does not" \
  "$(peer_session_evidence peer-session "$SEM" no-folder "$ORZ")" "no"

# The body of a report may quote the line; only the frontmatter counts.
printf -- '---\ntype: work\n---\n\ntype: peer-session\n' > "$ORZ/2026-10/typed.md"
check "a quoted 'type: peer-session' in the body does not count" \
  "$(peer_session_evidence peer-session "$SEM" no-folder "$ORZ")" "no"

printf -- 'type: peer-session\n' > "$ORZ/2026-10/typed.md"
check "a file without frontmatter does not count" \
  "$(peer_session_evidence peer-session "$SEM" no-folder "$ORZ")" "no"

printf 'orz_file:   2026-10/typed.md\n' > "$SEM"
printf -- '---\ntype: peer-session\n---\n' > "$ORZ/2026-10/typed.md"
check "leading spaces in orz_file do not hide a real peer ORZ" \
  "$(peer_session_evidence peer-session "$SEM" no-folder "$ORZ")" "yes"

# A slug that is not one path component must never walk out of the day folder.
mkdir -p "$ORZ/2026-10/26/real-peer/nested"
: > "$ORZ/2026-10/26/real-peer/nested/00-writer.md"
printf 'wp: WP-1\n' > "$SEM"
check "slug '..' is refused" "$(peer_session_evidence peer-session "$SEM" .. "$ORZ")" "no"
check "slug '.' is refused" "$(peer_session_evidence peer-session "$SEM" . "$ORZ")" "no"
check "slug with a slash is refused" \
  "$(peer_session_evidence peer-session "$SEM" real-peer/nested "$ORZ")" "no"
check "empty slug is refused" "$(peer_session_evidence peer-session "$SEM" "" "$ORZ")" "no"

check "a missing semaphore never aborts the close" \
  "$(peer_session_evidence peer-session "$SANDBOX/absent" no-folder "$ORZ")" "no"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
