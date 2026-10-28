#!/usr/bin/env bash
# WP-484 F257 M4a: a Quick Close session leaves only a flat ORZ file, no folder.
# The scanner used to skip such sessions, so an older peer-session folder was
# reported as «последняя сессия». Pins: the flat session is listed, it is the
# latest when it really is, a session with a folder is not listed twice, and a
# closed session is found through the ledger event as well.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/wp-session-journal-gaps.py"
PY="$("$ROOT_DIR/scripts/lib/find-python3.sh" --stdlib-only)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wp-journal-gaps-flat.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$2" in *"$3"*) ;; *) fail "$1 — нет '$3' в: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 — лишнее '$3' в: $2" ;; *) ;; esac; }

SESSIONS="$TEST_ROOT/MC-sessions"
SEM="$TEST_ROOT/sem"
mkdir -p "$SESSIONS/2026-10/20/old-peer" "$SEM"
touch "$SESSIONS/2026-10/20/old-peer/report-draft.md"
printf -- "---\nduration_h: 1.5\n---\n" >"$SESSIONS/2026-10/2026-10-27-quick-close.md"
printf -- "---\nduration_h: ~\n---\n" >"$SESSIONS/2026-10/2026-10-25-scaffold.md"
touch "$SESSIONS/2026-10/2026-10-27-ledger-only.md"

cat > "$SEM/claude-code-old-peer.closed" <<'S'
wp: WP-999
slug: old-peer
session_id: old-peer
opened_at: 2026-10-20T10:00:00Z
file: 2026-10/20/old-peer/report-draft.md
orz_file: 2026-10/2026-10-20-old-peer.md
S
cat > "$SEM/claude-code-quick.closed" <<'S'
wp: WP-999
slug: quick-close
session_id: quick-close
opened_at: 2026-10-27T13:00:00Z
orz_file: 2026-10/2026-10-27-quick-close.md
S
cat > "$SEM/claude-code-missing.open" <<'S'
wp: WP-999
slug: missing-orz
session_id: missing-orz
opened_at: 2026-10-26T10:00:00Z
orz_file: 2026-10/2026-10-26-missing-orz.md
S
cat > "$SEM/claude-code-scaffold.closed" <<'S'
wp: WP-999
slug: scaffold
session_id: scaffold
opened_at: 2026-10-25T09:00:00Z
orz_file: 2026-10/2026-10-25-scaffold.md
S
cat > "$SEM/claude-code-evil.open" <<'S'
wp: WP-999
slug: evil
session_id: evil
opened_at: 2026-10-25T10:00:00Z
orz_file: ../../etc/passwd
S

LEDGER="$TEST_ROOT/ledger/day"
mkdir -p "$LEDGER/2026/10"
cat > "$LEDGER/2026/10/day-2026-10-27.yaml" <<'E'
events:
- ts: '2026-10-27T12:00:00Z'
  kind: session_closed
  data:
    wp: WP-999
    slug: ledger-only
E

NOW_SHIFT=$("$PY" - <<'P'
import datetime
print((datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%d"))
P
)
# The window is relative to «now»; widen it so the fixed 2026-10 dates stay inside.
OUT="$("$PY" "$SCRIPT" --wp WP-999 --sessions-dir "$SESSIONS" --sem-dir "$SEM" --ledger-dir "$LEDGER" --window-days 36500)"

contains "плоская сессия Quick Close видна" "$OUT" "2026-10/2026-10-27-quick-close.md"
contains "сессия без файла ОРЗ видна и помечена" "$OUT" "2026-10/2026-10-26-missing-orz.md"
contains "ОРЗ-файла нет" "$OUT" "отчёта НЕТ"
contains "пир-сессия с черновиком осталась в списке" "$OUT" "2026-10/20/old-peer"
contains "закрытая сессия с пустой заготовкой не спрятана" "$OUT" "ОРЗ-заготовка не заполнена"
lacks "путь за пределами каталога сессий отвергнут" "$OUT" "passwd"
lacks "сессия с папкой не задвоена плоским файлом" "$OUT" "2026-10-20-old-peer.md"

LAST="$(printf '%s\n' "$OUT" | tail -1)"
contains "последней названа самая поздняя (Quick Close 13:00)" "$LAST" "quick-close"

# The ledger source finds the flat file too (finalized rows are hidden from the
# printed list by design, so ask the function directly).
FOUND="$(SCRIPT_PATH="$SCRIPT" SESS="$SESSIONS" LED="$LEDGER" "$PY" - <<'P'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gaps", os.environ["SCRIPT_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(sorted(mod.scan_ledger("WP-999", os.environ["LED"], os.environ["SESS"], days=3650)))
P
)"
contains "закрытие из журнала находит плоский файл" "$FOUND" "2026-10/2026-10-27-ledger-only.md"

echo "PASS: wp-session-journal-gaps.py lists flat Quick Close sessions ($NOW_SHIFT)"
