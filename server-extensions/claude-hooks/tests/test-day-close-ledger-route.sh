#!/usr/bin/env bash
# Owner/foreign/corrupt routing through the same external writer used by Day Close.
set -euo pipefail

IWE_REPO="${DAY_CLOSE_DS_UNDER_TEST:-$HOME/IWE/DS-my-strategy}"
ROOT_HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WORKTREE="$TMP/.iwe-runtime/isolated-worktrees/day-close-fixture"
mkdir -p "$WORKTREE/scripts/lib" "$TMP/gov/scripts" "$TMP/.iwe-runtime/locks/day-close.lock"
printf 'fixture-token\n' > "$TMP/.iwe-runtime/locks/day-close.lock/token"
cp "$IWE_REPO/scripts/lib/day-close-ledger-route.py" "$TMP/.iwe-runtime/day-close-ledger-route.py"
cp "$IWE_REPO/scripts/ledger-append.sh" "$WORKTREE/scripts/ledger-append.sh"
cp "$IWE_REPO/scripts/lib/ledger-publish-kick.sh" "$WORKTREE/scripts/lib/ledger-publish-kick.sh"
cp "$IWE_REPO/scripts/lib/ledger-path.sh" "$WORKTREE/scripts/lib/ledger-path.sh"
cat > "$WORKTREE/scripts/ledger-publish.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --source-ledger-dir ] && [ -d "$2" ] || exit 1
printf 'publish\n' >> "$IWE_WORKSPACE/publish.calls"
printf 'LEDGER_SOURCE_RECEIPT {"state":"published","origin_oid":"fixture","source_changed":false}\n'
SH
cat > "$TMP/gov/scripts/ledger-append.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${IWE_LEDGER_WRITE_DIR:-unset}" "$3" >> "$IWE_ROOT/canon.calls"
SH

HELPER="$TMP/.iwe-runtime/day-close-ledger-route.py"
export IWE_ROOT="$TMP"
QUEUE=$(IWE_ROOT="$TMP" python3 "$HELPER" prepare --runtime claude-code \
  --session-id owner-a --token fixture-token --worktree "$WORKTREE" --date 2026-10-03)
# shellcheck source=../lib/day-close-ledger-route.sh
. "$ROOT_HOOKS/lib/day-close-ledger-route.sh"

ledger_route_configure '{"session_id":"owner-a"}' "$TMP" gov
[ "$LEDGER_ROUTE_OWN" = true ] && [ "$LEDGER_ROUTE_DATE" = 2026-10-03 ]
ledger_route_append ritual_shown '{"session_id":"owner-a"}' route-test
test -f "$QUEUE/day/2026/10/day-2026-10-03.yaml"
test ! -e "$TMP/canon.calls"

IWE_ROOT="$TMP" python3 "$HELPER" seal --runtime claude-code --session-id owner-a \
  --token fixture-token --state completed >/dev/null
ledger_route_configure '{"session_id":"owner-a"}' "$TMP" gov
ledger_route_append ritual_shown '{"session_id":"owner-a","late":true}' route-test
[ "$(wc -l < "$TMP/publish.calls" | tr -d ' ')" = 2 ]

ABORT_QUEUE=$(IWE_ROOT="$TMP" python3 "$HELPER" prepare --runtime claude-code \
  --session-id owner-aborted --token fixture-token --worktree "$WORKTREE" --date 2026-10-03)
IWE_ROOT="$TMP" python3 "$HELPER" seal --runtime claude-code --session-id owner-aborted \
  --token fixture-token --state aborted >/dev/null
ledger_route_configure '{"session_id":"owner-aborted"}' "$TMP" gov
ledger_route_append ritual_shown '{"session_id":"owner-aborted","after_abort":true}' route-test
test -f "$ABORT_QUEUE/day/2026/10/day-2026-10-03.yaml"
[ "$(wc -l < "$TMP/publish.calls" | tr -d ' ')" = 2 ]

export IWE_LEDGER_WRITE_DIR="$QUEUE" IWE_LEDGER_EXTERNAL_SOURCE=1
ledger_route_configure '{"session_id":"foreign-b"}' "$TMP" gov || [ "$?" = 10 ]
ledger_route_append ritual_shown '{"session_id":"foreign-b"}' route-test
[ "$(cat "$TMP/canon.calls")" = 'unset|ritual_shown' ]

if CLAUDE_CODE_SESSION_ID=other ledger_route_configure '{"session_id":"owner-a"}' "$TMP" gov; then
  echo 'FAIL: conflicting payload/env identity accepted' >&2; exit 1
fi
KEY=$(python3 -c 'import hashlib;print(hashlib.sha256(b"claude-code\0owner-a").hexdigest())')
mv "$TMP/.iwe-runtime/day-close-ledger/routes/$KEY.json" "$TMP/broken-route.json"
if ledger_route_configure '{"session_id":"owner-a"}' "$TMP" gov; then
  echo 'FAIL: missing own route fell back to canon' >&2; exit 1
fi
[ "$(wc -l < "$TMP/canon.calls" | tr -d ' ')" = 1 ]
python3 - "$ROOT_HOOKS/../skills/day-close/SKILL.md" "$TMP" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import yaml

skill = Path(sys.argv[1]).read_text(encoding="utf-8")
start = skill.index("DIGEST_JSON=$(python3 - ")
code = skill[start:].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
base = Path(sys.argv[2]) / "history.yaml"
own = Path(sys.argv[2]) / "owner.yaml"
date = "2026-10-03"
def ledger(*events):
    return {"schema": "ledger/v1", "scale": "day", "period": date, "events": list(events)}
def digest(data):
    return {"kind": "facts_digest", "data": {"for_date": date, **data}}
base.write_text(yaml.safe_dump(ledger(digest({"wakatime_h": 4.5})), allow_unicode=True))
own.write_text(yaml.safe_dump(ledger(
    digest({"wakatime_h": 5.0, "multiplier_estimated": 1.2}),
    digest({"multiplier_final": 1.1}),
), allow_unicode=True))
result = subprocess.run([sys.executable, "-c", code, str(own), str(base), date],
                        check=True, capture_output=True, text=True)
data = json.loads(result.stdout)
assert data["wakatime_h"] == 5.0
assert data["multiplier_estimated"] == 1.2
assert data["multiplier_final"] == 1.1
PY
echo 'PASS: owner, late hook, foreign, conflict and broken route'
