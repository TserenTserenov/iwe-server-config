#!/bin/bash
# test-pull-on-touch-cd-relative-path.sh — regression corpus for pull-on-touch.sh
# (WP-484, пир-сессия 2026-10-16-23-fix-pull-on-touch, Claude+Kimi+Codex).
#
# Bug: the regex extractor looked for a literal "IWE/<repo>" substring in the
# command/path text. A command of the form `cd $IWE_ROOT && <relative command>`
# splits the repo name across two separate arguments (the cd target and the
# following relative path) — no such substring exists, so the hook silently
# did nothing (fail-open by design, no warning). Found live 16.10.2026: a
# stale DS-my-strategy checkout was read for hours before the pilot noticed
# via a GitHub screenshot.
#
# Fixed by: a bounded parser for `cd <IWE_ROOT> && <next simple segment>`
# (one segment only — a second `cd` resets context) plus removing the early
# `grep -q "IWE/" || exit 0` fast-exit that used to run before extraction.
#
# Run: bash .claude/hooks/tests/test-pull-on-touch-cd-relative-path.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pull-on-touch.sh"
WORKDIR=$(mktemp -d)
FAKE_IWE_ROOT="$WORKDIR/IWE"
FAKE_HOME="$WORKDIR/home"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

mkdir -p "$FAKE_IWE_ROOT/DS-my-strategy/.git" "$FAKE_IWE_ROOT/OtherRepo/.git" "$FAKE_IWE_ROOT/scripts" "$FAKE_HOME"

# Stub safe-pull: always "succeeds" so the hook's success branch (not the
# dirty-tree warning branch) is what the test observes — this test is about
# detection, not about safe-pull's own refusal logic (covered elsewhere).
cat > "$FAKE_IWE_ROOT/scripts/iwe-safe-pull.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$FAKE_IWE_ROOT/scripts/iwe-safe-pull.sh"

run_hook() {
    local command="$1" session="$2"
    python3 -c "
import json
print(json.dumps({
    'tool_name': 'Bash',
    'tool_input': {'command': $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$command")},
    'session_id': '$session',
}))
" | IWE_WORKSPACE="$FAKE_IWE_ROOT" HOME="$FAKE_HOME" bash "$HOOK"
}

assert_detects() {
    local desc="$1" command="$2" session="$3" repo="$4"
    local out
    out=$(run_hook "$command" "$session")
    if printf '%s' "$out" | grep -q "$repo"; then
        PASS=$((PASS + 1))
        echo "PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc — expected '$repo' in output, got: $out"
    fi
}

assert_silent() {
    local desc="$1" command="$2" session="$3"
    local out
    out=$(run_hook "$command" "$session")
    if [ -z "$out" ]; then
        PASS=$((PASS + 1))
        echo "PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc — expected no output, got: $out"
    fi
}

assert_detects \
    "cd \$IWE_ROOT && <relative command> finds the repo" \
    "cd $FAKE_IWE_ROOT && grep -n needle DS-my-strategy/docs/WP-REGISTRY.md" \
    "test-1" "DS-my-strategy"

assert_silent \
    "a second cd resets context — repo after it is not picked up" \
    "cd $FAKE_IWE_ROOT && cd /tmp && cat DS-my-strategy/README.md" \
    "test-2"

assert_detects \
    "cd \$IWE_ROOT && ./<repo>/... finds the repo" \
    "cd $FAKE_IWE_ROOT && ./DS-my-strategy/scripts/foo.sh" \
    "test-3" "DS-my-strategy"

assert_detects \
    "existing absolute-path scenario still works unchanged" \
    "cat $FAKE_IWE_ROOT/DS-my-strategy/docs/WP-REGISTRY.md" \
    "test-4" "DS-my-strategy"

assert_silent \
    "'..' after cd is not mistaken for a repo name" \
    "cd $FAKE_IWE_ROOT && cat ../OtherRepo/file.md" \
    "test-5"

assert_detects \
    "quoted cd target (cd \"\$IWE_ROOT\" && ...) still finds the repo" \
    "cd \"$FAKE_IWE_ROOT\" && cat DS-my-strategy/README.md" \
    "test-6" "DS-my-strategy"

assert_detects \
    "repo-root cd is the second segment, not the first" \
    "cd /tmp && cd $FAKE_IWE_ROOT && cat DS-my-strategy/README.md" \
    "test-7" "DS-my-strategy"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
