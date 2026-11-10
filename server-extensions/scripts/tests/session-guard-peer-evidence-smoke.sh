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
# Read by the extracted function sourced above.
# shellcheck disable=SC2034
GUARD_LIB_DIR="$(dirname "$GUARD")/lib"

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

# Kimi may open its standalone WP session before the peer journal receives a
# reserved name. The two note-file claims then bind that journal to the same
# semaphore even though its slug remains WP-7.
PAIR_REL="2026-11/08/2026-11-08-07-session"
PAIR_DIR="$ORZ/$PAIR_REL"
mkdir -p "$PAIR_DIR"
printf 'session_id: "2026-11-08-07-session"\n' > "$PAIR_DIR/meta.yaml"
printf '%s\n' '---' 'role: writer' '---' > "$PAIR_DIR/00-writer.md"
printf 'file: %s/meta.yaml\nfile: %s/00-writer.md\n' "$PAIR_REL" "$PAIR_REL" > "$SEM"
check "a claimed peer journal counts when the semaphore slug is WP-7" \
  "$(peer_session_evidence peer-session "$SEM" WP-7 "$ORZ")" "yes"

printf 'file: %s/meta.yaml\n' "$PAIR_REL" > "$SEM"
check "one claimed file is not a peer journal" \
  "$(peer_session_evidence peer-session "$SEM" WP-7 "$ORZ")" "no"

printf 'file: %s/meta.yaml\nfile: %s/00-writer.md\n' "$PAIR_REL" "$PAIR_REL" > "$SEM"
: > "$PAIR_DIR/00-writer.md"
check "an empty writer turn is not peer evidence" \
  "$(peer_session_evidence peer-session "$SEM" WP-7 "$ORZ")" "no"
printf '%s\n' '---' 'role: writer' '---' > "$PAIR_DIR/00-writer.md"

printf 'session_id: "other-session"\n' > "$PAIR_DIR/meta.yaml"
check "a mismatched session id is not peer evidence" \
  "$(peer_session_evidence peer-session "$SEM" WP-7 "$ORZ")" "no"
printf 'session_id: "2026-11-08-07-session"\n' > "$PAIR_DIR/meta.yaml"

OTHER_REL="2026-11/08/2026-11-08-08-session"
mkdir -p "$ORZ/$OTHER_REL"
printf 'file: %s/meta.yaml\nfile: %s/00-writer.md\nfile: %s/meta.yaml\n' \
  "$PAIR_REL" "$PAIR_REL" "$OTHER_REL" > "$SEM"
check "claims for two peer journals are ambiguous" \
  "$(peer_session_evidence peer-session "$SEM" WP-7 "$ORZ")" "no"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
