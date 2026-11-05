#!/usr/bin/env bash
# WP-530 F158 (05.11): a close event can sit only in the host ledger buffer
# (pending/acknowledged), not yet drained to the published day file -- the
# host's writer has defaulted to buffer-first since 28.10. Pins: scan_ledger
# finds a buffer-only event through --buffer-ledger-dirs, a published copy of
# the same date is not scanned twice into a wrong result, and the published
# root alone (no --buffer-ledger-dirs) still works as before.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/wp-session-journal-gaps.py"
PY="$("$ROOT_DIR/scripts/lib/find-python3.sh" --stdlib-only)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wp-journal-gaps-buffer.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$2" in *"$3"*) ;; *) fail "$1 — нет '$3' в: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 — лишнее '$3' в: $2" ;; *) ;; esac; }

SESSIONS="$TEST_ROOT/MC-sessions"
LEDGER="$TEST_ROOT/ledger/day"
BUFFER_PENDING="$TEST_ROOT/buffer/pending/day"
mkdir -p "$SESSIONS/2026-11" "$LEDGER/2026/11" "$BUFFER_PENDING/2026/11"
touch "$SESSIONS/2026-11/2026-11-05-buffer-only.md"
touch "$SESSIONS/2026-11/2026-11-05-published-only.md"

cat > "$LEDGER/2026/11/day-2026-11-05.yaml" <<'E'
events:
- ts: '2026-11-05T09:00:00Z'
  kind: session_closed
  data:
    wp: WP-999
    slug: published-only
E
cat > "$BUFFER_PENDING/2026/11/day-2026-11-05.yaml" <<'E'
events:
- ts: '2026-11-05T11:00:00Z'
  kind: session_closed
  data:
    wp: WP-999
    slug: buffer-only
E

helper() {
  SCRIPT_PATH="$SCRIPT" SESS="$SESSIONS" LED="$LEDGER" BUF="$1" "$PY" - <<'P'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gaps", os.environ["SCRIPT_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
buffer_dirs = [d for d in os.environ["BUF"].split(",") if d]
print(sorted(mod.scan_ledger("WP-999", os.environ["LED"], os.environ["SESS"], days=3650, buffer_ledger_dirs=buffer_dirs)))
P
}

WITHOUT_BUFFER="$(helper "")"
contains "без --buffer-ledger-dirs опубликованное событие находится" "$WITHOUT_BUFFER" "2026-11/2026-11-05-published-only.md"
lacks "без --buffer-ledger-dirs буферное событие не видно (ожидаемо)" "$WITHOUT_BUFFER" "2026-11/2026-11-05-buffer-only.md"

WITH_BUFFER="$(helper "$BUFFER_PENDING")"
contains "с --buffer-ledger-dirs опубликованное событие всё ещё находится" "$WITH_BUFFER" "2026-11/2026-11-05-published-only.md"
contains "с --buffer-ledger-dirs буферное-только событие находится" "$WITH_BUFFER" "2026-11/2026-11-05-buffer-only.md"

# Cold review finding (05.11): a date duplicated across canon+buffer must
# count as ONE date against --window-days, not as two files eating two of
# the requested slots -- otherwise an older, still-in-window date is pushed
# out silently. Build one older date that exists ONLY in canon, then ask for
# a 2-day window: it must still be found even though the newest date (04.11)
# has two files (canon + buffer).
mkdir -p "$LEDGER/2026/11"
cat > "$LEDGER/2026/11/day-2026-11-04.yaml" <<'E'
events:
- ts: '2026-11-04T09:00:00Z'
  kind: session_closed
  data:
    wp: WP-999
    slug: older-published-only
E
touch "$SESSIONS/2026-11/2026-11-04-older-published-only.md"

TWO_DAY_WINDOW="$(SCRIPT_PATH="$SCRIPT" SESS="$SESSIONS" LED="$LEDGER" BUF="$BUFFER_PENDING" "$PY" - <<'P'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gaps", os.environ["SCRIPT_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
buffer_dirs = [d for d in os.environ["BUF"].split(",") if d]
print(sorted(mod.scan_ledger("WP-999", os.environ["LED"], os.environ["SESS"], days=2, buffer_ledger_dirs=buffer_dirs)))
P
)"
contains "окно в 2 дня не теряет старую дату из-за дубля новой (канон+буфер)" "$TWO_DAY_WINDOW" "2026-11/2026-11-04-older-published-only.md"

echo "PASS: wp-session-journal-gaps.py finds a buffer-only close event via --buffer-ledger-dirs"
