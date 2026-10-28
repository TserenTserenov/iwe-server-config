#!/usr/bin/env bash
# wp-handoff-show.sh WP-N -- reader of the handoff fields of a WP card
# (WP-484 F257, measure M3).
#
# The next session must start from what the previous one left in the card, and a
# stale working copy of the card is the failure this closes: the reader prints the
# copy freshness first, then the three handoff fields taken from the origin
# snapshot, never from the working tree.
#
# Prints, in this order:
#   1. freshness of the governance repo copy (lib/git-sync-status.sh);
#   2. a line "read the card only from the origin snapshot" when the copy is
#      STALE or DIVERGED;
#   3. "Следующий шаг", "Контекст для следующей сессии", "Актуально до" from
#      origin/main (a past date is marked);
#   4. the last session line of the WP from wp-session-journal-gaps.sh.
#
# Best-effort and read-only: always exits 0, a missing piece is reported as text,
# so a caller can run it as an optional step (`... || true`).
# Needs IWE_GOVERNANCE_REPO (no silent default, same rule as session-guard.sh).
set -u

WP="${1:-}"
case "$WP" in
  WP-[0-9]*) ;;
  *) echo "usage: wp-handoff-show.sh WP-N" >&2; exit 0 ;;
esac
case "${WP#WP-}" in
  *[!0-9]*) echo "usage: wp-handoff-show.sh WP-N" >&2; exit 0 ;;
esac

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SCRIPTS_DIR="${IWE_SCRIPTS:-$IWE_ROOT/scripts}"

echo "=== Передача работы по $WP ==="

if [ -z "${IWE_GOVERNANCE_REPO:-}" ]; then
  echo "Репозиторий управления не задан (IWE_GOVERNANCE_REPO): поля передачи прочитать нельзя."
  exit 0
fi
REPO="$IWE_ROOT/$IWE_GOVERNANCE_REPO"
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Репозиторий управления $IWE_GOVERNANCE_REPO не найден: поля передачи прочитать нельзя."
  exit 0
fi

# 1-2. Freshness of the working copy.
GIT_SYNC_STATUS=""
if [ -r "$SCRIPTS_DIR/lib/git-sync-status.sh" ]; then
  # shellcheck source=lib/git-sync-status.sh
  . "$SCRIPTS_DIR/lib/git-sync-status.sh"
  check_git_sync_status "$REPO" "main" 10 >/dev/null 2>&1 || true
fi
echo "Свежесть копии: ${GIT_SYNC_STATUS:-не проверена} (${GIT_SYNC_DETAIL:-нет данных})"
case "$GIT_SYNC_STATUS" in
  STALE|DIVERGED)
    echo "Карточку читать только со снимка origin, не из рабочей копии: она отстаёт."
    ;;
esac

# 3. The card and the checker, both from the origin snapshot (the checker owns
#    the field parsing; the working copy may predate it).  The reader never fetches:
#    it pins one snapshot.  The server commit id from the freshness check is used when
#    that commit is already local; otherwise the local origin/main is read and the gap
#    is said out loud, because a silent older snapshot looks exactly like a current one.
SNAP_REF="origin/main"
LOCAL_ORIGIN="$(git -C "$REPO" rev-parse --verify -q origin/main 2>/dev/null || true)"
if [ -n "${GIT_SYNC_REMOTE_OID:-}" ] && [ "${GIT_SYNC_REMOTE_OID}" != "$LOCAL_ORIGIN" ]; then
  if git -C "$REPO" cat-file -e "${GIT_SYNC_REMOTE_OID}^{commit}" 2>/dev/null; then
    SNAP_REF="$GIT_SYNC_REMOTE_OID"
    echo "Снимок: серверная версия ${GIT_SYNC_REMOTE_OID:0:12} (локальный origin/main отстаёт)."
  else
    echo "Внимание: локальный снимок origin/main отстаёт от сервера (локально ${LOCAL_ORIGIN:0:12}, на сервере ${GIT_SYNC_REMOTE_OID:0:12}), поля ниже могут быть старше. Обновить: git -C $REPO fetch origin main."
  fi
fi
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-handoff-show.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
CARD_REL="inbox/$WP/$WP.md"
if ! git -C "$REPO" show "$SNAP_REF:$CARD_REL" >"$TMP_DIR/card.md" 2>/dev/null; then
  echo "Карточка $CARD_REL на origin/main не найдена."
  CARD_OK=0
else
  CARD_OK=1
fi

# Checker candidates, first one that has show_fields() wins: an explicit override
# (tests), the origin snapshot, then the working copy.
ORIGIN_CHECKER="$TMP_DIR/wp-handoff-check.py"
git -C "$REPO" show "$SNAP_REF:scripts/wp-handoff-check.py" >"$ORIGIN_CHECKER" 2>/dev/null || rm -f "$ORIGIN_CHECKER"

PY="$("$SCRIPTS_DIR/lib/find-python3.sh" --stdlib-only 2>/dev/null)" || PY=""
if [ "$CARD_OK" = 1 ]; then
  if [ -z "$PY" ]; then
    echo "Читатель полей недоступен: нет python3."
  else
    "$PY" - "$TMP_DIR/card.md" "${IWE_HANDOFF_CHECKER:-}" "$ORIGIN_CHECKER" "$REPO/scripts/wp-handoff-check.py" <<'PYEOF' || echo "Чтение полей карточки не удалось."
import datetime
import importlib.util
import re
import sys

import os

module = None
for candidate in sys.argv[2:]:
    if not candidate or not os.path.isfile(candidate):
        continue
    spec = importlib.util.spec_from_file_location("wp_handoff_check", candidate)
    loaded = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(loaded)
    except Exception:
        continue
    if hasattr(loaded, "show_fields"):
        module = loaded
        break
if module is None:
    print("Читатель полей недоступен: ни на origin/main, ни в рабочей копии нет wp-handoff-check.py с чтением полей.")
    sys.exit(0)
with open(sys.argv[1], encoding="utf-8") as handle:
    shown = module.show_fields(handle.read())

today = datetime.date.today()


def past_date(value):
    """True when the value leads with a date that is already behind us."""
    match = re.match(r"\s*(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?", value or "")
    if match:
        day, month, year = int(match.group(1)), int(match.group(2)), int(match.group(3) or today.year)
    else:
        match = re.match(r"\s*(\d{4})-(\d{2})-(\d{2})", value or "")
        if not match:
            return False
        year, month, day = (int(group) for group in match.groups())
    try:
        return datetime.date(year, month, day) < today
    except ValueError:
        return False


for name, value in shown["fields"].items():
    if value is None:
        print(f"{name}: поля нет в «Осталось» карточки")
        continue
    mark = " (дата прошла)" if name == "Актуально до" and past_date(value) else ""
    print(f"{name}: {value}{mark}")
print(f"Ревизия карточки (отпечаток): {shown['card_digest']}")
PYEOF
  fi
fi

# 4. Last session of the WP.
if [ -x "$SCRIPTS_DIR/wp-session-journal-gaps.sh" ]; then
  # The caller's own open session is not «where the previous one stopped»: find its
  # semaphore by the harness session id and hand its guard id to the scanner.
  OWN_ID=""
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    for sem in "$IWE_ROOT/.iwe-runtime/sessions/"*.open; do
      [ -f "$sem" ] || continue
      if grep -qx "harness_session_id: $CLAUDE_CODE_SESSION_ID" "$sem" 2>/dev/null; then
        OWN_ID="$(grep '^session_id: ' "$sem" | head -1 | cut -d' ' -f2-)"
        break
      fi
    done
  fi
  if [ -n "$OWN_ID" ]; then
    LAST="$(bash "$SCRIPTS_DIR/wp-session-journal-gaps.sh" "$WP" --exclude-session-id "$OWN_ID" 2>/dev/null | tail -1)"
  else
    LAST="$(bash "$SCRIPTS_DIR/wp-session-journal-gaps.sh" "$WP" 2>/dev/null | tail -1)"
  fi
  if [ -n "$LAST" ]; then
    echo "Последняя сессия: $LAST"
  else
    echo "Последняя сессия: сканер не нашёл сессий по $WP"
  fi
fi
exit 0
