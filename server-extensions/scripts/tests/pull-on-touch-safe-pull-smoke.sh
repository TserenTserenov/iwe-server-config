#!/usr/bin/env bash
# Regression for WP-484: Pull-on-Touch observes remote freshness without mutating
# a shared checkout, hiding work in stash, or cleaning another session's Git state.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT_DIR/.claude/hooks/pull-on-touch.sh"
REAL_GIT=$(command -v git)
ORIGINAL_PATH="$PATH"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pull-on-touch-safe.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] || fail "$label — expected '$expected', got '$actual'"
}

assert_contains() {
    local label="$1" text="$2" needle="$3"
    case "$text" in
        *"$needle"*) ;;
        *) fail "$label — missing '$needle' in: $text" ;;
    esac
}

assert_ref_absent() {
    local label="$1" repo="$2"
    [ -z "$("$REAL_GIT" -C "$repo" for-each-ref --format='%(refname)' refs/iwe-safe-pull)" ] \
        || fail "$label — temporary safe-pull ref leaked"
}

object_store_checksum() {
    find "$1" -type f -exec shasum {} \; | LC_ALL=C sort | shasum | awk '{print $1}'
}

file_checksum_or_absent() {
    if [ -f "$1" ]; then
        cksum < "$1"
    else
        printf 'absent\n'
    fi
}

hook_input() {
    local repo="$1" session="$2"
    printf '{"tool_name":"Read","tool_input":{"file_path":"%s/tracked.txt"},"session_id":"%s"}' \
        "$repo" "$session"
}

decode_context() {
    python3 -c 'import json,sys; raw=sys.stdin.read(); print(json.loads(raw).get("additionalContext", "") if raw else "")'
}

# Contract layer: the hook may call safe-pull and stash-list telemetry only. It
# records a repo after the attempt finishes, so an abruptly killed attempt retries.
CONTRACT_ROOT="$TEST_ROOT/contract/IWE"
CONTRACT_REPO="$CONTRACT_ROOT/repo-contract"
CONTRACT_HOME="$TEST_ROOT/contract/home"
CONTRACT_BIN="$TEST_ROOT/contract/bin"
SAFE_PULL_LOG="$TEST_ROOT/contract/safe-pull.log"
GIT_CALL_LOG="$TEST_ROOT/contract/git-calls.log"
GIT_STASH_COUNTER="$TEST_ROOT/contract/stash-counter"
PYTHON_CALL_COUNTER="$TEST_ROOT/contract/python-counter"
REAL_PYTHON=$(command -v python3)
mkdir -p "$CONTRACT_REPO" "$CONTRACT_ROOT/scripts" "$CONTRACT_HOME" "$CONTRACT_BIN"
: > "$CONTRACT_REPO/.git"

cat > "$CONTRACT_ROOT/scripts/iwe-safe-pull.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SAFE_PULL_LOG"
if [ "${SAFE_PULL_KILL_PARENT:-0}" = "1" ]; then
    kill -TERM "$PPID"
    /bin/sleep 0.1
    exit 1
fi
exit "${SAFE_PULL_EXIT:-0}"
EOF

cat > "$CONTRACT_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALL_LOG"
if [ "$#" -ge 4 ] && [ "$1" = "-C" ] && [ "$3" = "stash" ] && [ "$4" = "list" ]; then
    count=0
    [ ! -f "$GIT_STASH_COUNTER" ] || count=$(cat "$GIT_STASH_COUNTER")
    count=$((count + 1))
    printf '%s\n' "$count" > "$GIT_STASH_COUNTER"
    case "${GIT_STASH_MUTATION:-none}:$count" in
        growth:2) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
        shrink:1) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        replace:1) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        replace:2) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    esac
    exit 0
fi
echo "unexpected git command in hook contract test: $*" >&2
exit 97
EOF

cat > "$CONTRACT_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
echo "hook must not wrap safe-pull in timeout" >&2
exit 98
EOF

cat > "$CONTRACT_BIN/python3" <<'EOF'
#!/usr/bin/env bash
count=0
[ ! -f "$PYTHON_CALL_COUNTER" ] || count=$(cat "$PYTHON_CALL_COUNTER")
count=$((count + 1))
printf '%s\n' "$count" > "$PYTHON_CALL_COUNTER"
if [ "${PYTHON_FAIL_ON:-0}" = "$count" ]; then
    exit 77
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$CONTRACT_ROOT/scripts/iwe-safe-pull.sh" "$CONTRACT_BIN/git" \
    "$CONTRACT_BIN/timeout" "$CONTRACT_BIN/python3"

run_contract_hook() {
    local session="$1" safe_pull_exit="$2" stash_mutation="$3" kill_parent="${4:-0}"
    local python_fail_on="${5:-0}"
    hook_input "$CONTRACT_REPO" "$session" | \
        HOME="$CONTRACT_HOME" \
        IWE_WORKSPACE="$CONTRACT_ROOT" \
        IWE_ROOT="$CONTRACT_ROOT" \
        SAFE_PULL_LOG="$SAFE_PULL_LOG" \
        SAFE_PULL_EXIT="$safe_pull_exit" \
        SAFE_PULL_KILL_PARENT="$kill_parent" \
        GIT_CALL_LOG="$GIT_CALL_LOG" \
        GIT_STASH_COUNTER="$GIT_STASH_COUNTER" \
        GIT_STASH_MUTATION="$stash_mutation" \
        PYTHON_CALL_COUNTER="$PYTHON_CALL_COUNTER" \
        PYTHON_FAIL_ON="$python_fail_on" \
        REAL_PYTHON="$REAL_PYTHON" \
        PATH="$CONTRACT_BIN:$ORIGINAL_PATH" \
        bash "$HOOK"
}

: > "$SAFE_PULL_LOG"
: > "$GIT_CALL_LOG"
: > "$GIT_STASH_COUNTER"
contract_out=$(run_contract_hook contract-success 0 none | decode_context)
assert_eq "safe-pull exact target" "$CONTRACT_REPO" "$(cat "$SAFE_PULL_LOG")"
assert_eq "hook only reads stash twice" "2" "$(wc -l < "$GIT_CALL_LOG" | tr -d ' ')"
assert_contains "successful freshness context" "$contract_out" "Проверил свежее: repo-contract"

: > "$SAFE_PULL_LOG"
: > "$GIT_CALL_LOG"
: > "$GIT_STASH_COUNTER"
contract_out=$(run_contract_hook contract-refusal 1 none | decode_context)
assert_contains "refusal context" "$contract_out" "potentially stale"
run_contract_hook contract-refusal 0 none >/dev/null
assert_eq "completed refusal is attempted once" "1" "$(wc -l < "$SAFE_PULL_LOG" | tr -d ' ')"

: > "$SAFE_PULL_LOG"
: > "$GIT_CALL_LOG"
: > "$GIT_STASH_COUNTER"
contract_out=$(run_contract_hook contract-stash-growth 0 growth | decode_context)
assert_contains "stash invariant warning" "$contract_out" "инвариант safe-pull нарушен"
case "$contract_out" in
    *"stash pop"*) fail "stash invariant must not recommend automatic pop" ;;
esac
for stash_mutation in shrink replace; do
    : > "$GIT_CALL_LOG"
    : > "$GIT_STASH_COUNTER"
    contract_out=$(run_contract_hook "contract-stash-$stash_mutation" 0 "$stash_mutation" | decode_context)
    assert_contains "$stash_mutation stash warning" "$contract_out" "инвариант safe-pull нарушен"
done

: > "$SAFE_PULL_LOG"
: > "$GIT_CALL_LOG"
: > "$GIT_STASH_COUNTER"
set +e
run_contract_hook contract-killed 0 none 1 >/dev/null 2>&1
killed_rc=$?
set -e
[ "$killed_rc" -ne 0 ] || fail "abrupt fixture did not kill the hook"
KILLED_STATE="$CONTRACT_HOME/.claude/state/repo-pulled-contract-killed.txt"
if [ -f "$KILLED_STATE" ] && grep -qxF repo-contract "$KILLED_STATE"; then
    fail "killed attempt was incorrectly marked completed"
fi
run_contract_hook contract-killed 0 none >/dev/null
assert_eq "killed attempt retries" "2" "$(wc -l < "$SAFE_PULL_LOG" | tr -d ' ')"

: > "$SAFE_PULL_LOG"
: > "$GIT_CALL_LOG"
: > "$GIT_STASH_COUNTER"
: > "$PYTHON_CALL_COUNTER"
run_contract_hook contract-emitter-failure 0 none 0 3 >/dev/null
EMITTER_STATE="$CONTRACT_HOME/.claude/state/repo-pulled-contract-emitter-failure.txt"
if [ -f "$EMITTER_STATE" ] && grep -qxF repo-contract "$EMITTER_STATE"; then
    fail "failed JSON emission was incorrectly marked completed"
fi
: > "$PYTHON_CALL_COUNTER"
run_contract_hook contract-emitter-failure 0 none >/dev/null
assert_eq "failed JSON emission retries" "2" "$(wc -l < "$SAFE_PULL_LOG" | tr -d ' ')"

# Integration layer: real Git, safe-pull and dirty-guard in isolated repositories.
INTEGRATION_ROOT="$TEST_ROOT/integration/IWE"
INTEGRATION_HOME="$TEST_ROOT/integration/home"
ORIGIN="$TEST_ROOT/integration/origin.git"
SEED="$TEST_ROOT/integration/seed"
REAL_REPO="$INTEGRATION_ROOT/repo-real"
mkdir -p "$INTEGRATION_ROOT/scripts" "$INTEGRATION_HOME"
cp "$ROOT_DIR/scripts/iwe-safe-pull.sh" "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh"
cp "$ROOT_DIR/scripts/git-dirty-guard.sh" "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh"
chmod +x "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh"

# Audit every ordinary integration call. A mutate-then-restore implementation can
# preserve final snapshots and still lose a concurrent write, so dangerous verbs are
# rejected at execution time. Safe-pull may query the remote but may not fetch or
# update any ref; stash access is telemetry-only.
AUDIT_BIN="$TEST_ROOT/integration/audit-bin"
AUDIT_LOG="$TEST_ROOT/integration/git-audit.log"
AUDIT_VIOLATIONS="$TEST_ROOT/integration/git-audit-violations.log"
mkdir -p "$AUDIT_BIN"
cat > "$AUDIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUDIT_LOG"
args=("$@")
index=0
while [ "$index" -lt "${#args[@]}" ]; do
    case "${args[$index]}" in
        -C|-c|--git-dir|--work-tree) index=$((index + 2)) ;;
        --no-lazy-fetch) index=$((index + 1)) ;;
        *) break ;;
    esac
done
verb="${args[$index]:-}"
next="${args[$((index + 1))]:-}"
case "$verb" in
    --version|check-ref-format|diff|diff-files|merge-base|rev-parse|show-ref|status) ;;
    symbolic-ref)
        [ "$next" = "--quiet" ] || {
            printf 'mutating symbolic-ref: %s\n' "$*" >> "$AUDIT_VIOLATIONS"
            exit 98
        }
        ;;
    stash)
        [ "$next" = "list" ] || {
            printf 'forbidden stash: %s\n' "$*" >> "$AUDIT_VIOLATIONS"
            exit 98
        }
        ;;
    ls-remote)
        if [ "${args[$((index + 1))]:-}" != "--exit-code" ] \
            || [ "${args[$((index + 2))]:-}" != "--refs" ] \
            || [ "${args[$((index + 3))]:-}" != "origin" ] \
            || [ "$((index + 5))" -ne "${#args[@]}" ]; then
            printf 'invalid remote query: %s\n' "$*" >> "$AUDIT_VIOLATIONS"
            exit 98
        fi
        case "${args[$((index + 4))]:-}" in
            refs/heads/*) ;;
            *)
                printf 'invalid remote query ref: %s\n' "$*" >> "$AUDIT_VIOLATIONS"
                exit 98
                ;;
        esac
        ;;
    *)
        printf 'unknown git verb: %s\n' "$*" >> "$AUDIT_VIOLATIONS"
        exit 98
        ;;
esac
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$AUDIT_BIN/git"

"$REAL_GIT" init --bare -q "$ORIGIN"
"$REAL_GIT" init -q "$SEED"
"$REAL_GIT" -C "$SEED" config user.name fixture
"$REAL_GIT" -C "$SEED" config user.email fixture@example.invalid
printf 'initial\n' > "$SEED/tracked.txt"
printf 'other initial\n' > "$SEED/other.txt"
"$REAL_GIT" -C "$SEED" add tracked.txt other.txt
"$REAL_GIT" -C "$SEED" commit -qm initial
"$REAL_GIT" -C "$SEED" branch -M main
"$REAL_GIT" -C "$SEED" remote add origin "$ORIGIN"
"$REAL_GIT" -C "$SEED" push -q -u origin main
"$REAL_GIT" -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" clone -q "$ORIGIN" "$REAL_REPO"
"$REAL_GIT" -C "$REAL_REPO" config user.name fixture
"$REAL_GIT" -C "$REAL_REPO" config user.email fixture@example.invalid

# The old destination API is retired rather than guarded by a prefix: Git follows
# symbolic refs at fetch destinations, so even a private-looking name could rewrite
# an unpushed permanent branch.
DEST_REPO="$INTEGRATION_ROOT/repo-destination-policy"
"$REAL_GIT" clone -q "$ORIGIN" "$DEST_REPO"
"$REAL_GIT" -C "$DEST_REPO" config user.name fixture
"$REAL_GIT" -C "$DEST_REPO" config user.email fixture@example.invalid
"$REAL_GIT" -C "$DEST_REPO" checkout -qb victim
printf 'unpushed victim\n' > "$DEST_REPO/victim.txt"
"$REAL_GIT" -C "$DEST_REPO" add victim.txt
"$REAL_GIT" -C "$DEST_REPO" commit -qm victim
VICTIM_HEAD=$("$REAL_GIT" -C "$DEST_REPO" rev-parse refs/heads/victim)
"$REAL_GIT" -C "$DEST_REPO" checkout -q main
set +e
unsafe_dest_out=$(HOME="$INTEGRATION_HOME" \
    GIT_DIRTY_GUARD_REQUIRE_FETCH=true \
    GIT_DIRTY_GUARD_FETCH_DEST_REF=refs/heads/victim \
    GIT_DIRTY_GUARD_TG_ALERTS=false REAL_GIT_BIN="$REAL_GIT" \
    AUDIT_LOG="$AUDIT_LOG" AUDIT_VIOLATIONS="$AUDIT_VIOLATIONS" \
    PATH="$AUDIT_BIN:$ORIGINAL_PATH" \
    bash "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh" "$DEST_REPO" main 2>&1)
unsafe_dest_rc=$?
set -e
assert_eq "permanent fetch destination refuses" "1" "$unsafe_dest_rc"
assert_contains "permanent fetch destination diagnostic" "$unsafe_dest_out" \
    "fetch destinations are unsupported"
assert_eq "permanent destination preserves victim" "$VICTIM_HEAD" \
    "$("$REAL_GIT" -C "$DEST_REPO" rev-parse refs/heads/victim)"

"$REAL_GIT" -C "$DEST_REPO" symbolic-ref \
    refs/iwe-safe-pull/redirect refs/heads/victim
set +e
symbolic_dest_out=$(HOME="$INTEGRATION_HOME" \
    GIT_DIRTY_GUARD_REQUIRE_FETCH=true \
    GIT_DIRTY_GUARD_FETCH_DEST_REF=refs/iwe-safe-pull/redirect \
    GIT_DIRTY_GUARD_TG_ALERTS=false REAL_GIT_BIN="$REAL_GIT" \
    AUDIT_LOG="$AUDIT_LOG" AUDIT_VIOLATIONS="$AUDIT_VIOLATIONS" \
    PATH="$AUDIT_BIN:$ORIGINAL_PATH" \
    bash "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh" "$DEST_REPO" main 2>&1)
symbolic_dest_rc=$?
set -e
assert_eq "symbolic private destination refuses" "1" "$symbolic_dest_rc"
assert_contains "symbolic private destination diagnostic" "$symbolic_dest_out" \
    "fetch destinations are unsupported"
assert_eq "symbolic destination preserves victim" "$VICTIM_HEAD" \
    "$("$REAL_GIT" -C "$DEST_REPO" rev-parse refs/heads/victim)"
assert_eq "symbolic destination remains untouched" "refs/heads/victim" \
    "$("$REAL_GIT" -C "$DEST_REPO" symbolic-ref refs/iwe-safe-pull/redirect)"
"$REAL_GIT" -C "$DEST_REPO" symbolic-ref --delete refs/iwe-safe-pull/redirect

# ~/.config/aist/env may supply notification secrets; it must not override the
# caller's fetch policy, repository/branch arguments, timeout, or read-only Git mode.
mkdir -p "$INTEGRATION_HOME/.config/aist"
cat > "$INTEGRATION_HOME/.config/aist/env" <<'EOF'
readonly GIT_DIRTY_GUARD_FETCH_DEST_REF=refs/heads/victim
readonly GIT_DIRTY_GUARD_REQUIRE_FETCH=false
readonly GIT_DIRTY_GUARD_FETCH_TIMEOUT=0
readonly GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT=false
readonly GIT_OPTIONAL_LOCKS=1
readonly REPO=/config-must-not-replace-caller-repo
readonly BRANCH=victim
readonly PATH=/config-must-not-replace-caller-path
export TELEGRAM_BOT_TOKEN=123:test_token
export TELEGRAM_CHAT_ID=-456
exit 0
EOF
DEST_GIT_DIR=$("$REAL_GIT" -C "$DEST_REPO" rev-parse --absolute-git-dir)
ALERT_BIN="$TEST_ROOT/integration/alert-bin"
ALERT_LOG="$TEST_ROOT/integration/alert.log"
mkdir -p "$ALERT_BIN"
cat > "$ALERT_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ALERT_LOG"
EOF
chmod +x "$ALERT_BIN/curl"
"$REAL_GIT" -C "$DEST_REPO" rev-parse HEAD > "$DEST_GIT_DIR/MERGE_HEAD"
set +e
HOME="$INTEGRATION_HOME" TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID='' \
    ALERT_LOG="$ALERT_LOG" PATH="$ALERT_BIN:$ORIGINAL_PATH" \
    bash "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh" "$DEST_REPO" main >/dev/null 2>&1
alert_guard_rc=$?
set -e
rm -f "$DEST_GIT_DIR/MERGE_HEAD"
assert_eq "whitelisted AIST credentials preserve alert path" "1" "$alert_guard_rc"
assert_contains "AIST token parsed as data" "$(cat "$ALERT_LOG")" \
    "bot123:test_token/sendMessage"
assert_contains "AIST chat id parsed as data" "$(cat "$ALERT_LOG")" "chat_id=-456"

touch -t 200001010101 "$DEST_REPO/tracked.txt"
DEST_INDEX_SUM=$(cksum < "$DEST_GIT_DIR/index")
config_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
    GIT_DIRTY_GUARD_TG_ALERTS=false REAL_GIT_BIN="$REAL_GIT" \
    AUDIT_LOG="$AUDIT_LOG" AUDIT_VIOLATIONS="$AUDIT_VIOLATIONS" \
    PATH="$AUDIT_BIN:$ORIGINAL_PATH" \
    bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$DEST_REPO" main 2>&1)
assert_contains "config cannot redirect safe-pull" "$config_out" "already matches queried"
assert_eq "config override preserves victim" "$VICTIM_HEAD" \
    "$("$REAL_GIT" -C "$DEST_REPO" rev-parse refs/heads/victim)"
assert_eq "config override preserves index bytes" "$DEST_INDEX_SUM" \
    "$(cksum < "$DEST_GIT_DIR/index")"
assert_ref_absent "config override creates no temporary ref" "$DEST_REPO"

# Caller REQUIRE_FETCH must remain fail-closed even when the AIST file declares
# the opposite value readonly. This is a direct guard contract, independent of the
# safe-pull output mode's own fail-closed rule.
QUERY_FAIL_BIN="$TEST_ROOT/integration/query-failure-bin"
mkdir -p "$QUERY_FAIL_BIN"
cat > "$QUERY_FAIL_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "ls-remote" ]; then
    exit 74
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$QUERY_FAIL_BIN/git"
set +e
query_fail_out=$(HOME="$INTEGRATION_HOME" \
    GIT_DIRTY_GUARD_REQUIRE_FETCH=true GIT_DIRTY_GUARD_TG_ALERTS=false \
    REAL_GIT_BIN="$REAL_GIT" PATH="$QUERY_FAIL_BIN:$ORIGINAL_PATH" \
    bash "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh" "$DEST_REPO" main 2>&1)
query_fail_rc=$?
set -e
assert_eq "caller required remote query refuses failure" "1" "$query_fail_rc"
assert_contains "caller required remote query diagnostic" "$query_fail_out" \
    "remote query failed or timed out"

# Legacy fail-open networking may let a clean caller continue, but it must still
# inspect the tracked tree and refuse real local work when the remote is unavailable.
printf 'dirty during query outage\n' > "$DEST_REPO/tracked.txt"
QUERY_OUTAGE_DIFF=$("$REAL_GIT" -C "$DEST_REPO" diff -- tracked.txt)
set +e
query_outage_out=$(HOME="$INTEGRATION_HOME" \
    GIT_DIRTY_GUARD_REQUIRE_FETCH=false GIT_DIRTY_GUARD_TG_ALERTS=false \
    REAL_GIT_BIN="$REAL_GIT" PATH="$QUERY_FAIL_BIN:$ORIGINAL_PATH" \
    bash "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh" "$DEST_REPO" main 2>&1)
query_outage_rc=$?
set -e
assert_eq "optional query outage still refuses dirty tree" "1" "$query_outage_rc"
assert_contains "optional query outage dirty diagnostic" "$query_outage_out" "not touching"
assert_eq "optional query outage preserves dirty diff" "$QUERY_OUTAGE_DIFF" \
    "$("$REAL_GIT" -C "$DEST_REPO" diff -- tracked.txt)"
"$REAL_GIT" -C "$DEST_REPO" checkout -q -- tracked.txt

run_safe() {
    local repo="$1" branch="${2:-main}"
    HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
        GIT_DIRTY_GUARD_TG_ALERTS=false REAL_GIT_BIN="$REAL_GIT" \
        AUDIT_LOG="$AUDIT_LOG" AUDIT_VIOLATIONS="$AUDIT_VIOLATIONS" \
        PATH="$AUDIT_BIN:$ORIGINAL_PATH" \
        bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$repo" "$branch"
}

run_real_hook() {
    local repo="$1" session="$2"
    hook_input "$repo" "$session" | \
        HOME="$INTEGRATION_HOME" \
        IWE_WORKSPACE="$INTEGRATION_ROOT" \
        IWE_ROOT="$INTEGRATION_ROOT" \
        GIT_DIRTY_GUARD_TG_ALERTS=false \
        REAL_GIT_BIN="$REAL_GIT" AUDIT_LOG="$AUDIT_LOG" \
        AUDIT_VIOLATIONS="$AUDIT_VIOLATIONS" PATH="$AUDIT_BIN:$ORIGINAL_PATH" \
        bash "$HOOK"
}

INITIAL_HEAD=$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)
REAL_GIT_DIR=$("$REAL_GIT" -C "$REAL_REPO" rev-parse --absolute-git-dir)
"$REAL_GIT" -C "$SEED" tag -a surprise-tag -m surprise-tag
"$REAL_GIT" -C "$SEED" push -q origin refs/tags/surprise-tag
printf 'sentinel fetch head\n' > "$REAL_GIT_DIR/FETCH_HEAD"
touch -t 200001010101 "$REAL_REPO/tracked.txt"
INDEX_SUM_BEFORE=$(cksum < "$REAL_GIT_DIR/index")
PERMANENT_REFS_BEFORE=$("$REAL_GIT" -C "$REAL_REPO" for-each-ref \
    --format='%(refname) %(objectname)' | awk '$1 !~ /^refs\/iwe-safe-pull\//')
equal_out=$(run_safe "$REAL_REPO" main 2>&1)
assert_contains "equal snapshot success" "$equal_out" "already matches queried"
assert_eq "equal HEAD unchanged" "$INITIAL_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"
assert_eq "remote query preserves FETCH_HEAD" "sentinel fetch head" "$(cat "$REAL_GIT_DIR/FETCH_HEAD")"
assert_eq "inspection preserves index bytes" "$INDEX_SUM_BEFORE" "$(cksum < "$REAL_GIT_DIR/index")"
assert_eq "remote query preserves permanent refs" "$PERMANENT_REFS_BEFORE" \
    "$("$REAL_GIT" -C "$REAL_REPO" for-each-ref --format='%(refname) %(objectname)' | awk '$1 !~ /^refs\/iwe-safe-pull\//')"
if "$REAL_GIT" -C "$REAL_REPO" show-ref --verify --quiet refs/tags/surprise-tag; then
    fail "remote query materialized a remote tag"
fi
assert_ref_absent "equal query creates no temporary ref" "$REAL_REPO"

# Bracket local inspection with two exact queries. If origin advances after the
# first answer, safe-pull must not report the now-old local HEAD as fresh.
REMOTE_RACE_ORIGIN="$TEST_ROOT/integration/remote-race-origin.git"
REMOTE_RACE_SEED="$TEST_ROOT/integration/remote-race-seed"
REMOTE_RACE_REPO="$INTEGRATION_ROOT/repo-remote-race"
"$REAL_GIT" init --bare -q "$REMOTE_RACE_ORIGIN"
"$REAL_GIT" init -q "$REMOTE_RACE_SEED"
"$REAL_GIT" -C "$REMOTE_RACE_SEED" config user.name fixture
"$REAL_GIT" -C "$REMOTE_RACE_SEED" config user.email fixture@example.invalid
printf 'race base\n' > "$REMOTE_RACE_SEED/tracked.txt"
"$REAL_GIT" -C "$REMOTE_RACE_SEED" add tracked.txt
"$REAL_GIT" -C "$REMOTE_RACE_SEED" commit -qm race-base
"$REAL_GIT" -C "$REMOTE_RACE_SEED" branch -M main
"$REAL_GIT" -C "$REMOTE_RACE_SEED" remote add origin "$REMOTE_RACE_ORIGIN"
"$REAL_GIT" -C "$REMOTE_RACE_SEED" push -q -u origin main
"$REAL_GIT" -C "$REMOTE_RACE_ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" clone -q "$REMOTE_RACE_ORIGIN" "$REMOTE_RACE_REPO"
REMOTE_RACE_HEAD=$("$REAL_GIT" -C "$REMOTE_RACE_REPO" rev-parse HEAD)
REMOTE_RACE_GIT_DIR=$("$REAL_GIT" -C "$REMOTE_RACE_REPO" rev-parse --absolute-git-dir)
REMOTE_RACE_INDEX_SUM=$(cksum < "$REMOTE_RACE_GIT_DIR/index")
printf 'race remote advance\n' > "$REMOTE_RACE_SEED/tracked.txt"
"$REAL_GIT" -C "$REMOTE_RACE_SEED" add tracked.txt
"$REAL_GIT" -C "$REMOTE_RACE_SEED" commit -qm race-advance
REMOTE_RACE_NEW_HEAD=$("$REAL_GIT" -C "$REMOTE_RACE_SEED" rev-parse HEAD)
"$REAL_GIT" -C "$REMOTE_RACE_SEED" push -q origin \
    "$REMOTE_RACE_NEW_HEAD:refs/heads/staged-next"
REMOTE_ADVANCE_BIN="$TEST_ROOT/integration/remote-advance-bin"
REMOTE_ADVANCE_MARKER="$TEST_ROOT/integration/remote-advance-injected"
mkdir -p "$REMOTE_ADVANCE_BIN"
cat > "$REMOTE_ADVANCE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "ls-remote" ] && [ ! -e "$REMOTE_ADVANCE_MARKER" ]; then
    first_output=$("$REAL_GIT_BIN" "$@") || exit $?
    : > "$REMOTE_ADVANCE_MARKER"
    "$REAL_GIT_BIN" -C "$REMOTE_RACE_ORIGIN" update-ref \
        refs/heads/main "$REMOTE_RACE_NEW_HEAD"
    printf '%s\n' "$first_output"
    exit 0
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$REMOTE_ADVANCE_BIN/git"
set +e
remote_race_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
    REAL_GIT_BIN="$REAL_GIT" REMOTE_ADVANCE_MARKER="$REMOTE_ADVANCE_MARKER" \
    REMOTE_RACE_ORIGIN="$REMOTE_RACE_ORIGIN" REMOTE_RACE_NEW_HEAD="$REMOTE_RACE_NEW_HEAD" \
    PATH="$REMOTE_ADVANCE_BIN:$ORIGINAL_PATH" GIT_DIRTY_GUARD_TG_ALERTS=false \
    bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$REMOTE_RACE_REPO" main 2>&1)
remote_race_rc=$?
set -e
assert_eq "remote advance during inspection refuses" "1" "$remote_race_rc"
assert_contains "remote advance during inspection diagnostic" "$remote_race_out" \
    "changed during inspection"
assert_eq "remote advance preserves HEAD" "$REMOTE_RACE_HEAD" \
    "$("$REAL_GIT" -C "$REMOTE_RACE_REPO" rev-parse HEAD)"
assert_eq "remote advance preserves index" "$REMOTE_RACE_INDEX_SUM" \
    "$(cksum < "$REMOTE_RACE_GIT_DIR/index")"
assert_ref_absent "remote advance creates no temporary ref" "$REMOTE_RACE_REPO"

printf 'remote update\n' > "$SEED/tracked.txt"
"$REAL_GIT" -C "$SEED" add tracked.txt
"$REAL_GIT" -C "$SEED" commit -qm remote-update
"$REAL_GIT" -C "$SEED" push -q
REMOTE_HEAD=$("$REAL_GIT" -C "$SEED" rev-parse HEAD)
BEHIND_STATUS=$("$REAL_GIT" -C "$REAL_REPO" status --porcelain)
BEHIND_STASHES=$("$REAL_GIT" -C "$REAL_REPO" stash list | wc -l | tr -d ' ')
set +e
behind_out=$(run_safe "$REAL_REPO" main 2>&1)
behind_rc=$?
set -e
assert_eq "behind snapshot refuses" "1" "$behind_rc"
assert_contains "behind diagnostic" "$behind_out" "shared checkout not auto-mutated"
assert_eq "behind HEAD unchanged" "$INITIAL_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"
assert_eq "behind status unchanged" "$BEHIND_STATUS" "$("$REAL_GIT" -C "$REAL_REPO" status --porcelain)"
assert_eq "behind stash list unchanged" "$BEHIND_STASHES" "$("$REAL_GIT" -C "$REAL_REPO" stash list | wc -l | tr -d ' ')"
assert_ref_absent "behind cleanup" "$REAL_REPO"

real_out=$(run_real_hook "$REAL_REPO" real-behind | decode_context)
assert_contains "hook exposes stale checkout" "$real_out" "potentially stale"
assert_eq "hook does not fast-forward" "$INITIAL_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"

"$REAL_GIT" -C "$REAL_REPO" fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
"$REAL_GIT" -C "$REAL_REPO" merge --ff-only -q origin/main
assert_eq "fixture manual fast-forward" "$REMOTE_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"

printf 'local ahead\n' > "$REAL_REPO/local-ahead.txt"
"$REAL_GIT" -C "$REAL_REPO" add local-ahead.txt
"$REAL_GIT" -C "$REAL_REPO" commit -qm local-ahead
LOCAL_AHEAD_HEAD=$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)
ahead_out=$(run_safe "$REAL_REPO" main 2>&1)
assert_contains "local-ahead success" "$ahead_out" "contains queried"
assert_eq "local-ahead HEAD preserved" "$LOCAL_AHEAD_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"
"$REAL_GIT" -C "$REAL_REPO" reset --hard -q "$REMOTE_HEAD"

# Dirty work is diagnostic-only. The MM case proves a unique staged layer cannot
# be hidden by a worktree that happens to match the remote snapshot.
printf 'second remote update\n' > "$SEED/tracked.txt"
"$REAL_GIT" -C "$SEED" add tracked.txt
"$REAL_GIT" -C "$SEED" commit -qm second-remote-update
"$REAL_GIT" -C "$SEED" push -q
SECOND_REMOTE_HEAD=$("$REAL_GIT" -C "$SEED" rev-parse HEAD)
printf 'local uncommitted work\n' > "$REAL_REPO/tracked.txt"
DIRTY_DIFF=$("$REAL_GIT" -C "$REAL_REPO" diff -- tracked.txt)
set +e
dirty_out=$(run_safe "$REAL_REPO" main 2>&1)
dirty_rc=$?
set -e
assert_eq "dirty snapshot refuses" "1" "$dirty_rc"
assert_contains "dirty diagnostic" "$dirty_out" "not touching"
assert_eq "dirty diff preserved" "$DIRTY_DIFF" "$("$REAL_GIT" -C "$REAL_REPO" diff -- tracked.txt)"
assert_eq "dirty HEAD preserved" "$REMOTE_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"
assert_ref_absent "dirty temporary-ref cleanup" "$REAL_REPO"
"$REAL_GIT" -C "$REAL_REPO" checkout -q -- tracked.txt
"$REAL_GIT" -C "$REAL_REPO" fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
"$REAL_GIT" -C "$REAL_REPO" merge --ff-only -q origin/main

printf 'staged secret\n' > "$REAL_REPO/tracked.txt"
"$REAL_GIT" -C "$REAL_REPO" add tracked.txt
cp "$SEED/tracked.txt" "$REAL_REPO/tracked.txt"
MM_INDEX=$("$REAL_GIT" -C "$REAL_REPO" show :tracked.txt)
MM_WORKTREE=$(cat "$REAL_REPO/tracked.txt")
MM_HEAD=$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)
MM_INDEX_SUM=$(cksum < "$("$REAL_GIT" -C "$REAL_REPO" rev-parse --absolute-git-dir)/index")
set +e
mm_out=$(run_safe "$REAL_REPO" main 2>&1)
mm_rc=$?
set -e
assert_eq "MM staged overlay refuses" "1" "$mm_rc"
assert_contains "MM diagnostic" "$mm_out" "not touching"
assert_eq "MM staged blob preserved" "$MM_INDEX" "$("$REAL_GIT" -C "$REAL_REPO" show :tracked.txt)"
assert_eq "MM worktree preserved" "$MM_WORKTREE" "$(cat "$REAL_REPO/tracked.txt")"
assert_eq "MM HEAD preserved" "$MM_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"
assert_eq "MM index bytes preserved" "$MM_INDEX_SUM" "$(cksum < "$("$REAL_GIT" -C "$REAL_REPO" rev-parse --absolute-git-dir)/index")"
assert_ref_absent "MM temporary-ref cleanup" "$REAL_REPO"
"$REAL_GIT" -C "$REAL_REPO" reset --hard -q "$SECOND_REMOTE_HEAD"

# Even a byte-identical staged/worktree mirror is no longer reset automatically.
printf 'third remote update\n' > "$SEED/tracked.txt"
"$REAL_GIT" -C "$SEED" add tracked.txt
"$REAL_GIT" -C "$SEED" commit -qm third-remote-update
"$REAL_GIT" -C "$SEED" push -q
# The production path never fetches. Materialize this object explicitly in the
# fixture so the guard can exercise its finer "byte-identical mirror" diagnostic.
"$REAL_GIT" -C "$REAL_REPO" fetch -q origin main
cp "$SEED/tracked.txt" "$REAL_REPO/tracked.txt"
"$REAL_GIT" -C "$REAL_REPO" add tracked.txt
MIRROR_INDEX=$("$REAL_GIT" -C "$REAL_REPO" show :tracked.txt)
MIRROR_HEAD=$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)
set +e
mirror_out=$(run_safe "$REAL_REPO" main 2>&1)
mirror_rc=$?
set -e
assert_eq "stale mirror refuses" "1" "$mirror_rc"
assert_contains "self-heal retirement diagnostic" "$mirror_out" "automatic self-heal is disabled"
assert_eq "stale mirror HEAD preserved" "$MIRROR_HEAD" "$("$REAL_GIT" -C "$REAL_REPO" rev-parse HEAD)"
assert_eq "stale mirror index preserved" "$MIRROR_INDEX" "$("$REAL_GIT" -C "$REAL_REPO" show :tracked.txt)"
assert_eq "stale mirror worktree preserved" "$(cat "$SEED/tracked.txt")" "$(cat "$REAL_REPO/tracked.txt")"
assert_ref_absent "stale mirror temporary-ref cleanup" "$REAL_REPO"
"$REAL_GIT" -C "$REAL_REPO" reset --hard -q "$SECOND_REMOTE_HEAD"

# Passing main while feature is checked out must refuse before the guard can act.
WRONG_BRANCH_REPO="$INTEGRATION_ROOT/repo-wrong-branch"
"$REAL_GIT" clone -q "$ORIGIN" "$WRONG_BRANCH_REPO"
"$REAL_GIT" -C "$WRONG_BRANCH_REPO" checkout -qb feature
WRONG_MAIN_HEAD=$("$REAL_GIT" -C "$WRONG_BRANCH_REPO" rev-parse main)
WRONG_FEATURE_HEAD=$("$REAL_GIT" -C "$WRONG_BRANCH_REPO" rev-parse feature)
set +e
wrong_branch_out=$(run_safe "$WRONG_BRANCH_REPO" main 2>&1)
wrong_branch_rc=$?
set -e
assert_eq "initial wrong branch refuses" "1" "$wrong_branch_rc"
assert_contains "initial wrong branch diagnostic" "$wrong_branch_out" "checked-out branch is feature"
assert_eq "wrong branch keeps selection" "feature" "$("$REAL_GIT" -C "$WRONG_BRANCH_REPO" branch --show-current)"
assert_eq "wrong branch preserves main" "$WRONG_MAIN_HEAD" "$("$REAL_GIT" -C "$WRONG_BRANCH_REPO" rev-parse main)"
assert_eq "wrong branch preserves feature" "$WRONG_FEATURE_HEAD" "$("$REAL_GIT" -C "$WRONG_BRANCH_REPO" rev-parse feature)"

# A branch switch after the last preflight cannot mutate either branch or produce
# a false local-ahead success because ancestry uses pinned OIDs and success rechecks.
BRANCH_RACE_REPO="$INTEGRATION_ROOT/repo-branch-race"
"$REAL_GIT" clone -q "$ORIGIN" "$BRANCH_RACE_REPO"
"$REAL_GIT" -C "$BRANCH_RACE_REPO" config user.name fixture
"$REAL_GIT" -C "$BRANCH_RACE_REPO" config user.email fixture@example.invalid
"$REAL_GIT" -C "$BRANCH_RACE_REPO" branch feature
printf 'race local ahead\n' > "$BRANCH_RACE_REPO/race-local.txt"
"$REAL_GIT" -C "$BRANCH_RACE_REPO" add race-local.txt
"$REAL_GIT" -C "$BRANCH_RACE_REPO" commit -qm race-local-ahead
RACE_MAIN_HEAD=$("$REAL_GIT" -C "$BRANCH_RACE_REPO" rev-parse main)
RACE_FEATURE_HEAD=$("$REAL_GIT" -C "$BRANCH_RACE_REPO" rev-parse feature)
RACE_BIN="$TEST_ROOT/integration/branch-race-bin"
RACE_MARKER="$TEST_ROOT/integration/branch-race-injected"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "merge-base" ] && [ ! -e "$RACE_MARKER" ]; then
    : > "$RACE_MARKER"
    "$REAL_GIT_BIN" -C "$RACE_REPO" checkout -q feature
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$RACE_BIN/git"
set +e
branch_race_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
    REAL_GIT_BIN="$REAL_GIT" RACE_MARKER="$RACE_MARKER" RACE_REPO="$BRANCH_RACE_REPO" \
    PATH="$RACE_BIN:$ORIGINAL_PATH" GIT_DIRTY_GUARD_TG_ALERTS=false \
    bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$BRANCH_RACE_REPO" main 2>&1)
branch_race_rc=$?
set -e
assert_eq "late branch switch refuses" "1" "$branch_race_rc"
assert_contains "late branch switch diagnostic" "$branch_race_out" "repo changed during ancestry check"
assert_eq "late switch preserves main" "$RACE_MAIN_HEAD" "$("$REAL_GIT" -C "$BRANCH_RACE_REPO" rev-parse main)"
assert_eq "late switch preserves feature" "$RACE_FEATURE_HEAD" "$("$REAL_GIT" -C "$BRANCH_RACE_REPO" rev-parse feature)"
assert_eq "late switch leaves feature selected" "feature" "$("$REAL_GIT" -C "$BRANCH_RACE_REPO" branch --show-current)"

# A tracked edit arriving after guard completion is detected and preserved even when
# it does not overlap anything in the remote snapshot.
EDIT_RACE_REPO="$INTEGRATION_ROOT/repo-edit-race"
"$REAL_GIT" clone -q "$ORIGIN" "$EDIT_RACE_REPO"
EDIT_RACE_HEAD=$("$REAL_GIT" -C "$EDIT_RACE_REPO" rev-parse HEAD)
EDIT_BIN="$TEST_ROOT/integration/edit-race-bin"
EDIT_MARKER="$TEST_ROOT/integration/edit-race-injected"
mkdir -p "$EDIT_BIN"
cat > "$EDIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--porcelain=v2" ] \
    && [ "${3:-}" = "--branch" ] && [ "${4:-}" = "--untracked-files=no" ]; then
    edit_status_count=0
    [ ! -f "$EDIT_MARKER" ] || edit_status_count=$(cat "$EDIT_MARKER")
    edit_status_count=$((edit_status_count + 1))
    printf '%s\n' "$edit_status_count" > "$EDIT_MARKER"
    # Inject between safe-pull's two line-oriented status rounds.
    if [ "$edit_status_count" -eq 2 ]; then
        printf 'foreign concurrent edit\n' > "$EDIT_RACE_TARGET/other.txt"
    fi
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$EDIT_BIN/git"
set +e
edit_race_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
    REAL_GIT_BIN="$REAL_GIT" EDIT_MARKER="$EDIT_MARKER" EDIT_RACE_TARGET="$EDIT_RACE_REPO" \
    PATH="$EDIT_BIN:$ORIGINAL_PATH" GIT_DIRTY_GUARD_TG_ALERTS=false \
    bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$EDIT_RACE_REPO" main 2>&1)
edit_race_rc=$?
set -e
assert_eq "late tracked edit refuses" "1" "$edit_race_rc"
assert_contains "late tracked edit diagnostic" "$edit_race_out" "repo changed during inspection"
assert_eq "late tracked edit preserved" "foreign concurrent edit" "$(cat "$EDIT_RACE_REPO/other.txt")"
assert_eq "late tracked edit HEAD preserved" "$EDIT_RACE_HEAD" "$("$REAL_GIT" -C "$EDIT_RACE_REPO" rev-parse HEAD)"

# Exercise the two independent clean-snapshot gates. In the repeat scenario an
# unstaged edit lands after a real clean status was captured; only the following
# status round can see it. In the pinned scenario every status is made to look
# clean after commit X and soft reset to L; only index-to-L comparison can see
# the staged X layer. Safe-pull arms each mutation only after its second remote
# query, so inner guard observations cannot consume the fixture early.
ABA_REPO="$INTEGRATION_ROOT/repo-status-head-aba"
"$REAL_GIT" clone -q "$ORIGIN" "$ABA_REPO"
"$REAL_GIT" -C "$ABA_REPO" config user.name fixture
"$REAL_GIT" -C "$ABA_REPO" config user.email fixture@example.invalid
ABA_ORIGINAL_HEAD=$("$REAL_GIT" -C "$ABA_REPO" rev-parse HEAD)
ABA_BIN="$TEST_ROOT/integration/status-head-aba-bin"
ABA_REMOTE_COUNTER="$TEST_ROOT/integration/status-head-aba-remote-counter"
ABA_FINAL_PHASE="$TEST_ROOT/integration/status-head-aba-final-phase"
ABA_INJECTED="$TEST_ROOT/integration/status-head-aba-injected"
ABA_SNAPSHOT="$TEST_ROOT/integration/status-head-aba-snapshot"
ABA_CONCURRENT_HEAD_FILE="$TEST_ROOT/integration/status-head-aba-commit"
mkdir -p "$ABA_BIN"
cat > "$ABA_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "$ABA_SCOPE" = "safe" ] && [ "${1:-}" = "ls-remote" ] \
    && [ "${GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT:-false}" = "true" ]; then
    remote_count=0
    [ ! -f "$ABA_REMOTE_COUNTER" ] || remote_count=$(cat "$ABA_REMOTE_COUNTER")
    remote_count=$((remote_count + 1))
    printf '%s\n' "$remote_count" > "$ABA_REMOTE_COUNTER"
    "$REAL_GIT_BIN" "$@"
    remote_rc=$?
    if [ "$remote_rc" -eq 0 ] && [ "$remote_count" -eq 2 ]; then
        : > "$ABA_FINAL_PHASE"
    fi
    exit "$remote_rc"
fi

is_target_snapshot=false
status_is_nul=false
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--porcelain=v2" ] \
    && [ "${3:-}" = "--branch" ]; then
    if [ "${4:-}" = "-z" ] && [ "${5:-}" = "--untracked-files=no" ]; then
        status_is_nul=true
        if [ "$ABA_SCOPE" = "guard" ]; then
            is_target_snapshot=true
        fi
    elif [ "${4:-}" = "--untracked-files=no" ] \
        && [ "$ABA_SCOPE" = "safe" ] && [ -f "$ABA_FINAL_PHASE" ] \
        && [ "${GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT:-false}" != "true" ]; then
        is_target_snapshot=true
    fi
fi

if [ "$is_target_snapshot" = true ]; then
    if [ "$ABA_SCENARIO" = "repeat" ] && [ ! -f "$ABA_INJECTED" ]; then
        "$REAL_GIT_BIN" "$@" > "$ABA_SNAPSHOT"
        status_rc=$?
        [ "$status_rc" -eq 0 ] || exit "$status_rc"
        printf 'foreign concurrent edit\n' > "$ABA_REPO/tracked.txt"
        : > "$ABA_INJECTED"
        cat "$ABA_SNAPSHOT"
        exit 0
    fi

    if [ "$ABA_SCENARIO" = "pinned" ]; then
      if [ ! -f "$ABA_INJECTED" ]; then
        "$REAL_GIT_BIN" "$@" > "$ABA_SNAPSHOT"
        status_rc=$?
        [ "$status_rc" -eq 0 ] || exit "$status_rc"
        printf 'concurrent committed layer\n' > "$ABA_REPO/tracked.txt"
        "$REAL_GIT_BIN" -C "$ABA_REPO" add tracked.txt
        "$REAL_GIT_BIN" -C "$ABA_REPO" commit -qm concurrent-status-snapshot
        "$REAL_GIT_BIN" -C "$ABA_REPO" rev-parse HEAD > "$ABA_CONCURRENT_HEAD_FILE"
        "$REAL_GIT_BIN" -C "$ABA_REPO" reset -q --soft "$ABA_ORIGINAL_HEAD"
        : > "$ABA_INJECTED"
        cat "$ABA_SNAPSHOT"
        exit 0
      fi
      if [ "$status_is_nul" = true ]; then
          printf '# branch.oid %s\0# branch.head main\0' "$ABA_ORIGINAL_HEAD"
      else
          printf '# branch.oid %s\n# branch.head main\n' "$ABA_ORIGINAL_HEAD"
      fi
      exit 0
    fi
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$ABA_BIN/git"
ABA_TARGET="$ABA_REPO"

run_aba_case() {
  local scope="$1" scenario="$2" case_name="$1 $2"
  local case_out case_rc
  "$REAL_GIT" -C "$ABA_REPO" reset --hard -q "$ABA_ORIGINAL_HEAD"
  rm -f "$ABA_REMOTE_COUNTER" "$ABA_FINAL_PHASE" "$ABA_INJECTED" \
    "$ABA_SNAPSHOT" "$ABA_CONCURRENT_HEAD_FILE"
  set +e
  if [ "$scope" = "safe" ]; then
    case_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
      REAL_GIT_BIN="$REAL_GIT" ABA_REMOTE_COUNTER="$ABA_REMOTE_COUNTER" \
      ABA_FINAL_PHASE="$ABA_FINAL_PHASE" ABA_INJECTED="$ABA_INJECTED" \
      ABA_SNAPSHOT="$ABA_SNAPSHOT" ABA_CONCURRENT_HEAD_FILE="$ABA_CONCURRENT_HEAD_FILE" \
      ABA_REPO="$ABA_TARGET" ABA_ORIGINAL_HEAD="$ABA_ORIGINAL_HEAD" \
      ABA_SCOPE="$scope" ABA_SCENARIO="$scenario" PATH="$ABA_BIN:$ORIGINAL_PATH" \
      GIT_DIRTY_GUARD_TG_ALERTS=false \
      bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$ABA_TARGET" main 2>&1)
  else
    case_out=$(HOME="$INTEGRATION_HOME" \
      REAL_GIT_BIN="$REAL_GIT" ABA_REMOTE_COUNTER="$ABA_REMOTE_COUNTER" \
      ABA_FINAL_PHASE="$ABA_FINAL_PHASE" ABA_INJECTED="$ABA_INJECTED" \
      ABA_SNAPSHOT="$ABA_SNAPSHOT" ABA_CONCURRENT_HEAD_FILE="$ABA_CONCURRENT_HEAD_FILE" \
      ABA_REPO="$ABA_TARGET" ABA_ORIGINAL_HEAD="$ABA_ORIGINAL_HEAD" \
      ABA_SCOPE="$scope" ABA_SCENARIO="$scenario" PATH="$ABA_BIN:$ORIGINAL_PATH" \
      GIT_DIRTY_GUARD_REQUIRE_FETCH=true GIT_DIRTY_GUARD_TG_ALERTS=false \
      bash "$INTEGRATION_ROOT/scripts/git-dirty-guard.sh" "$ABA_TARGET" main 2>&1)
  fi
  case_rc=$?
  set -e
  assert_eq "$case_name refuses" "1" "$case_rc"
  assert_contains "$case_name diagnostic" "$case_out" "refusing"
  [ -f "$ABA_INJECTED" ] || fail "$case_name fixture did not inject"
  assert_eq "$case_name restores original HEAD" "$ABA_ORIGINAL_HEAD" \
    "$("$REAL_GIT" -C "$ABA_REPO" rev-parse HEAD)"
  if [ "$scenario" = "repeat" ]; then
    assert_eq "$case_name preserves unstaged edit" " M tracked.txt" \
      "$("$REAL_GIT" -C "$ABA_REPO" status --porcelain)"
    assert_eq "$case_name preserves worktree content" "foreign concurrent edit" \
      "$(cat "$ABA_REPO/tracked.txt")"
  else
    assert_eq "$case_name preserves staged layer" "M  tracked.txt" \
      "$("$REAL_GIT" -C "$ABA_REPO" status --porcelain)"
    assert_eq "$case_name preserves staged content" "concurrent committed layer" \
      "$("$REAL_GIT" -C "$ABA_REPO" show :tracked.txt)"
    [ -s "$ABA_CONCURRENT_HEAD_FILE" ] || fail "$case_name fixture did not create commit X"
  fi
}

run_aba_case safe repeat
run_aba_case safe pinned
run_aba_case guard repeat
run_aba_case guard pinned

# A failed porcelain read is unknown state, never an empty/clean state. Exercise
# both the guard's NUL snapshot and safe-pull's final tracked-status check.
STATUS_FAIL_REPO="$INTEGRATION_ROOT/repo-status-failure"
"$REAL_GIT" clone -q "$ORIGIN" "$STATUS_FAIL_REPO"
STATUS_FAIL_HEAD=$("$REAL_GIT" -C "$STATUS_FAIL_REPO" rev-parse HEAD)
STATUS_FAIL_BIN="$TEST_ROOT/integration/status-failure-bin"
mkdir -p "$STATUS_FAIL_BIN"
cat > "$STATUS_FAIL_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--porcelain=v2" ]; then
    if [ "$FAIL_STATUS_MODE" = "guard" ] && [ "${4:-}" = "-z" ]; then
        exit 73
    fi
    if [ "$FAIL_STATUS_MODE" = "safe" ] && [ "${3:-}" = "--branch" ] \
        && [ "${4:-}" = "--untracked-files=no" ]; then
        exit 73
    fi
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$STATUS_FAIL_BIN/git"
for fail_status_mode in guard safe; do
    set +e
    status_fail_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
        REAL_GIT_BIN="$REAL_GIT" FAIL_STATUS_MODE="$fail_status_mode" \
        PATH="$STATUS_FAIL_BIN:$ORIGINAL_PATH" GIT_DIRTY_GUARD_TG_ALERTS=false \
        bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$STATUS_FAIL_REPO" main 2>&1)
    status_fail_rc=$?
    set -e
    assert_eq "$fail_status_mode status failure refuses" "1" "$status_fail_rc"
    assert_contains "$fail_status_mode status failure diagnostic" "$status_fail_out" "refusing"
    assert_eq "$fail_status_mode status failure preserves HEAD" "$STATUS_FAIL_HEAD" \
        "$("$REAL_GIT" -C "$STATUS_FAIL_REPO" rev-parse HEAD)"
    assert_ref_absent "$fail_status_mode status failure temp-ref cleanup" "$STATUS_FAIL_REPO"
done

# The remote query must not depend on remote.origin.fetch. A stale tracking ref
# cannot cause false success because classification uses the queried branch OID.
REFSPEC_REPO="$INTEGRATION_ROOT/repo-refspec"
"$REAL_GIT" clone -q "$ORIGIN" "$REFSPEC_REPO"
REFSPEC_OLD_HEAD=$("$REAL_GIT" -C "$REFSPEC_REPO" rev-parse HEAD)
"$REAL_GIT" -C "$REFSPEC_REPO" config --unset-all remote.origin.fetch
printf 'fourth remote update\n' > "$SEED/tracked.txt"
"$REAL_GIT" -C "$SEED" add tracked.txt
"$REAL_GIT" -C "$SEED" commit -qm fourth-remote-update
"$REAL_GIT" -C "$SEED" push -q
FOURTH_REMOTE_HEAD=$("$REAL_GIT" -C "$SEED" rev-parse HEAD)
set +e
refspec_out=$(run_safe "$REFSPEC_REPO" main 2>&1)
refspec_rc=$?
set -e
assert_eq "exact remote query detects remote change" "1" "$refspec_rc"
assert_contains "exact remote query diagnostic" "$refspec_out" "object absent locally"
assert_eq "exact remote query preserves HEAD" "$REFSPEC_OLD_HEAD" "$("$REAL_GIT" -C "$REFSPEC_REPO" rev-parse HEAD)"
assert_eq "stale tracking ref is not trusted" "$REFSPEC_OLD_HEAD" "$("$REAL_GIT" -C "$REFSPEC_REPO" rev-parse refs/remotes/origin/main)"
[ "$REFSPEC_OLD_HEAD" != "$FOURTH_REMOTE_HEAD" ] || fail "refspec fixture remote did not advance"
assert_ref_absent "exact remote query creates no temporary ref" "$REFSPEC_REPO"

# Read-only-looking Git commands can lazily hydrate promised objects in a partial
# clone. The safe path must suppress that implicit fetch because it bypasses the
# explicit query timeout and writes the shared object database.
PARTIAL_ORIGIN="$TEST_ROOT/integration/partial-origin.git"
PARTIAL_SEED="$TEST_ROOT/integration/partial-seed"
PARTIAL_REPO="$INTEGRATION_ROOT/repo-partial"
"$REAL_GIT" init --bare -q "$PARTIAL_ORIGIN"
"$REAL_GIT" -C "$PARTIAL_ORIGIN" config uploadpack.allowFilter true
"$REAL_GIT" -C "$PARTIAL_ORIGIN" config uploadpack.allowAnySHA1InWant true
"$REAL_GIT" init -q "$PARTIAL_SEED"
"$REAL_GIT" -C "$PARTIAL_SEED" config user.name fixture
"$REAL_GIT" -C "$PARTIAL_SEED" config user.email fixture@example.invalid
printf 'partial base\n' > "$PARTIAL_SEED/tracked.txt"
"$REAL_GIT" -C "$PARTIAL_SEED" add tracked.txt
"$REAL_GIT" -C "$PARTIAL_SEED" commit -qm partial-base
"$REAL_GIT" -C "$PARTIAL_SEED" branch -M main
"$REAL_GIT" -C "$PARTIAL_SEED" remote add origin "$PARTIAL_ORIGIN"
"$REAL_GIT" -C "$PARTIAL_SEED" push -q -u origin main
"$REAL_GIT" -C "$PARTIAL_ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" clone -q --filter=blob:none "file://$PARTIAL_ORIGIN" "$PARTIAL_REPO"
assert_eq "partial clone marks promisor remote" "true" \
    "$("$REAL_GIT" -C "$PARTIAL_REPO" config --get remote.origin.promisor)"
printf 'promised remote commit\n' > "$PARTIAL_SEED/new.txt"
"$REAL_GIT" -C "$PARTIAL_SEED" add new.txt
"$REAL_GIT" -C "$PARTIAL_SEED" commit -qm promised-remote-commit
"$REAL_GIT" -C "$PARTIAL_SEED" push -q
PARTIAL_REMOTE_HEAD=$("$REAL_GIT" -C "$PARTIAL_SEED" rev-parse HEAD)
if GIT_NO_LAZY_FETCH=1 "$REAL_GIT" -C "$PARTIAL_REPO" \
    cat-file -e "$PARTIAL_REMOTE_HEAD^{commit}" 2>/dev/null; then
    fail "partial-clone fixture already contains the promised remote commit"
fi
PARTIAL_GIT_DIR=$("$REAL_GIT" -C "$PARTIAL_REPO" rev-parse --absolute-git-dir)
PARTIAL_HEAD=$("$REAL_GIT" -C "$PARTIAL_REPO" rev-parse HEAD)
PARTIAL_INDEX_SUM=$(cksum < "$PARTIAL_GIT_DIR/index")
PARTIAL_OBJECTS_SUM=$(object_store_checksum "$PARTIAL_GIT_DIR/objects")
PARTIAL_FETCH_HEAD_SUM=$(file_checksum_or_absent "$PARTIAL_GIT_DIR/FETCH_HEAD")
PARTIAL_REFS=$("$REAL_GIT" -C "$PARTIAL_REPO" for-each-ref \
    --format='%(refname) %(objectname)')

# Git before 2.45 ignores GIT_NO_LAZY_FETCH. Both public entry points must stop
# before any repository command, otherwise a partial clone can hydrate promised
# objects while supposedly being inspected without mutation.
LEGACY_GIT_BIN="$TEST_ROOT/integration/legacy-git-bin"
LEGACY_GIT_LOG="$TEST_ROOT/integration/legacy-git.log"
mkdir -p "$LEGACY_GIT_BIN"
cat > "$LEGACY_GIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LEGACY_GIT_LOG"
if [ "${1:-}" = "--no-lazy-fetch" ] && [ "${2:-}" = "--version" ]; then
    echo "unknown option: --no-lazy-fetch" >&2
    exit 129
fi
unset GIT_NO_LAZY_FETCH
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$LEGACY_GIT_BIN/git"
for legacy_entrypoint in iwe-safe-pull.sh git-dirty-guard.sh; do
    : > "$LEGACY_GIT_LOG"
    set +e
    legacy_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
        REAL_GIT_BIN="$REAL_GIT" LEGACY_GIT_LOG="$LEGACY_GIT_LOG" \
        PATH="$LEGACY_GIT_BIN:$ORIGINAL_PATH" GIT_DIRTY_GUARD_TG_ALERTS=false \
        bash "$INTEGRATION_ROOT/scripts/$legacy_entrypoint" "$PARTIAL_REPO" main 2>&1)
    legacy_rc=$?
    set -e
    assert_eq "$legacy_entrypoint rejects Git without no-lazy-fetch" "1" "$legacy_rc"
    assert_contains "$legacy_entrypoint old Git diagnostic" "$legacy_out" "Git 2.45+"
    assert_eq "$legacy_entrypoint stops before repository inspection" \
        "--no-lazy-fetch --version" \
        "$(cat "$LEGACY_GIT_LOG")"
    assert_eq "$legacy_entrypoint preserves partial object store" "$PARTIAL_OBJECTS_SUM" \
        "$(object_store_checksum "$PARTIAL_GIT_DIR/objects")"
    if GIT_NO_LAZY_FETCH=1 "$REAL_GIT" -C "$PARTIAL_REPO" \
        cat-file -e "$PARTIAL_REMOTE_HEAD^{commit}" 2>/dev/null; then
        fail "$legacy_entrypoint hydrated a promised object on unsupported Git"
    fi
done

set +e
partial_out=$(run_safe "$PARTIAL_REPO" main 2>&1)
partial_rc=$?
set -e
assert_eq "partial clone missing remote object refuses" "1" "$partial_rc"
assert_contains "partial clone diagnostic" "$partial_out" "object absent locally"
if GIT_NO_LAZY_FETCH=1 "$REAL_GIT" -C "$PARTIAL_REPO" \
    cat-file -e "$PARTIAL_REMOTE_HEAD^{commit}" 2>/dev/null; then
    fail "safe-pull lazily hydrated the promised remote commit"
fi
assert_eq "partial clone object store preserved" "$PARTIAL_OBJECTS_SUM" \
    "$(object_store_checksum "$PARTIAL_GIT_DIR/objects")"
assert_eq "partial clone HEAD preserved" "$PARTIAL_HEAD" \
    "$("$REAL_GIT" -C "$PARTIAL_REPO" rev-parse HEAD)"
assert_eq "partial clone index preserved" "$PARTIAL_INDEX_SUM" \
    "$(cksum < "$PARTIAL_GIT_DIR/index")"
assert_eq "partial clone FETCH_HEAD preserved" "$PARTIAL_FETCH_HEAD_SUM" \
    "$(file_checksum_or_absent "$PARTIAL_GIT_DIR/FETCH_HEAD")"
assert_eq "partial clone refs preserved" "$PARTIAL_REFS" \
    "$("$REAL_GIT" -C "$PARTIAL_REPO" for-each-ref --format='%(refname) %(objectname)')"
assert_ref_absent "partial clone creates no temporary ref" "$PARTIAL_REPO"

# Diverged history is classified from pinned OIDs and left byte-for-byte intact.
DIV_ORIGIN="$TEST_ROOT/integration/diverged-origin.git"
DIV_SEED="$TEST_ROOT/integration/diverged-seed"
DIV_REPO="$INTEGRATION_ROOT/repo-diverged"
"$REAL_GIT" init --bare -q "$DIV_ORIGIN"
"$REAL_GIT" init -q "$DIV_SEED"
"$REAL_GIT" -C "$DIV_SEED" config user.name fixture
"$REAL_GIT" -C "$DIV_SEED" config user.email fixture@example.invalid
printf 'base\n' > "$DIV_SEED/tracked.txt"
"$REAL_GIT" -C "$DIV_SEED" add tracked.txt
"$REAL_GIT" -C "$DIV_SEED" commit -qm base
"$REAL_GIT" -C "$DIV_SEED" branch -M main
"$REAL_GIT" -C "$DIV_SEED" remote add origin "$DIV_ORIGIN"
"$REAL_GIT" -C "$DIV_SEED" push -q -u origin main
"$REAL_GIT" -C "$DIV_ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" clone -q "$DIV_ORIGIN" "$DIV_REPO"
"$REAL_GIT" -C "$DIV_REPO" config user.name fixture
"$REAL_GIT" -C "$DIV_REPO" config user.email fixture@example.invalid
printf 'local\n' > "$DIV_REPO/local.txt"
"$REAL_GIT" -C "$DIV_REPO" add local.txt
"$REAL_GIT" -C "$DIV_REPO" commit -qm local
printf 'remote\n' > "$DIV_SEED/remote.txt"
"$REAL_GIT" -C "$DIV_SEED" add remote.txt
"$REAL_GIT" -C "$DIV_SEED" commit -qm remote
"$REAL_GIT" -C "$DIV_SEED" push -q
# Materialize the remote commit as an object without reconciling the histories, so
# safe-pull can distinguish true divergence while remaining query-only itself.
"$REAL_GIT" -C "$DIV_REPO" fetch -q origin main
DIV_HEAD=$("$REAL_GIT" -C "$DIV_REPO" rev-parse HEAD)
DIV_REMOTE_HEAD=$("$REAL_GIT" -C "$DIV_SEED" rev-parse HEAD)
DIV_STATUS=$("$REAL_GIT" -C "$DIV_REPO" status --porcelain)
DIV_GIT_DIR=$("$REAL_GIT" -C "$DIV_REPO" rev-parse --absolute-git-dir)
DIV_INDEX_SUM=$(cksum < "$DIV_GIT_DIR/index")
DIV_STASH=$("$REAL_GIT" -C "$DIV_REPO" stash list --format=%H)

# Repository-local replacement refs must not rewrite the ancestry decision.
DIV_TREE=$("$REAL_GIT" -C "$DIV_REPO" rev-parse "$DIV_HEAD^{tree}")
DIV_FAKE=$("$REAL_GIT" -C "$DIV_REPO" commit-tree "$DIV_TREE" \
    -p "$DIV_REMOTE_HEAD" -m replacement-graph)
"$REAL_GIT" -C "$DIV_REPO" replace "$DIV_HEAD" "$DIV_FAKE"
if ! "$REAL_GIT" -C "$DIV_REPO" merge-base --is-ancestor \
    "$DIV_REMOTE_HEAD" "$DIV_HEAD"; then
    fail "replacement-ref fixture did not forge local-ahead ancestry"
fi
if GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -C "$DIV_REPO" \
    merge-base --is-ancestor "$DIV_REMOTE_HEAD" "$DIV_HEAD"; then
    fail "replacement-ref fixture is not genuinely diverged"
fi
DIV_REPLACE_TARGET=$("$REAL_GIT" -C "$DIV_REPO" \
    rev-parse "refs/replace/$DIV_HEAD")
set +e
diverged_out=$(run_safe "$DIV_REPO" main 2>&1)
diverged_rc=$?
set -e
assert_eq "diverged history refuses" "1" "$diverged_rc"
assert_contains "diverged history diagnostic" "$diverged_out" "histories diverged"
assert_eq "diverged HEAD preserved" "$DIV_HEAD" "$("$REAL_GIT" -C "$DIV_REPO" rev-parse HEAD)"
assert_eq "diverged status preserved" "$DIV_STATUS" "$("$REAL_GIT" -C "$DIV_REPO" status --porcelain)"
assert_eq "diverged index preserved" "$DIV_INDEX_SUM" "$(cksum < "$DIV_GIT_DIR/index")"
assert_eq "diverged stash preserved" "$DIV_STASH" "$("$REAL_GIT" -C "$DIV_REPO" stash list --format=%H)"
assert_eq "replacement ref preserved but ignored" "$DIV_REPLACE_TARGET" \
    "$("$REAL_GIT" -C "$DIV_REPO" rev-parse "refs/replace/$DIV_HEAD")"
assert_ref_absent "diverged temporary-ref cleanup" "$DIV_REPO"
"$REAL_GIT" -C "$DIV_REPO" replace -d "$DIV_HEAD" >/dev/null

# Legacy grafts rewrite revision traversal even when replace refs are disabled.
# Point Git at an empty graft file so a concurrent/shared overlay cannot forge
# ancestry during the decision.
DIV_GRAFTS="$DIV_GIT_DIR/info/grafts"
printf '%s %s\n' "$DIV_HEAD" "$DIV_REMOTE_HEAD" > "$DIV_GRAFTS"
if ! GIT_GRAFT_FILE="$DIV_GRAFTS" "$REAL_GIT" -C "$DIV_REPO" \
    merge-base --is-ancestor "$DIV_REMOTE_HEAD" "$DIV_HEAD" 2>/dev/null; then
    fail "grafts fixture did not forge local-ahead ancestry"
fi
DIV_GRAFT_CONTENT=$(cat "$DIV_GRAFTS")
set +e
grafts_out=$(run_safe "$DIV_REPO" main 2>&1)
grafts_rc=$?
set -e
assert_eq "legacy graft cannot forge freshness" "1" "$grafts_rc"
assert_contains "legacy graft ignored in diagnostic" "$grafts_out" "histories diverged"
assert_eq "legacy graft file preserved" "$DIV_GRAFT_CONTENT" "$(cat "$DIV_GRAFTS")"
rm -f "$DIV_GRAFTS"

# A real conflicted rebase with a staged foreign resolution is preexisting state,
# not synthetic marker debris. Direct helper and end-to-end hook must preserve it.
REBASE_ORIGIN="$TEST_ROOT/integration/rebase-origin.git"
REBASE_SEED="$TEST_ROOT/integration/rebase-seed"
REBASE_REPO="$INTEGRATION_ROOT/repo-real-rebase"
"$REAL_GIT" init --bare -q "$REBASE_ORIGIN"
"$REAL_GIT" init -q "$REBASE_SEED"
"$REAL_GIT" -C "$REBASE_SEED" config user.name fixture
"$REAL_GIT" -C "$REBASE_SEED" config user.email fixture@example.invalid
printf 'base\n' > "$REBASE_SEED/tracked.txt"
"$REAL_GIT" -C "$REBASE_SEED" add tracked.txt
"$REAL_GIT" -C "$REBASE_SEED" commit -qm base
"$REAL_GIT" -C "$REBASE_SEED" branch -M main
"$REAL_GIT" -C "$REBASE_SEED" remote add origin "$REBASE_ORIGIN"
"$REAL_GIT" -C "$REBASE_SEED" push -q -u origin main
"$REAL_GIT" -C "$REBASE_ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" clone -q "$REBASE_ORIGIN" "$REBASE_REPO"
"$REAL_GIT" -C "$REBASE_REPO" config user.name fixture
"$REAL_GIT" -C "$REBASE_REPO" config user.email fixture@example.invalid
printf 'local conflict\n' > "$REBASE_REPO/tracked.txt"
"$REAL_GIT" -C "$REBASE_REPO" add tracked.txt
"$REAL_GIT" -C "$REBASE_REPO" commit -qm local-conflict
printf 'remote conflict\n' > "$REBASE_SEED/tracked.txt"
"$REAL_GIT" -C "$REBASE_SEED" add tracked.txt
"$REAL_GIT" -C "$REBASE_SEED" commit -qm remote-conflict
"$REAL_GIT" -C "$REBASE_SEED" push -q
"$REAL_GIT" -C "$REBASE_REPO" fetch -q origin main
set +e
"$REAL_GIT" -C "$REBASE_REPO" rebase origin/main >/dev/null 2>&1
rebase_fixture_rc=$?
set -e
[ "$rebase_fixture_rc" -ne 0 ] || fail "real rebase fixture did not conflict"
REBASE_GIT_DIR=$("$REAL_GIT" -C "$REBASE_REPO" rev-parse --absolute-git-dir)
[ -d "$REBASE_GIT_DIR/rebase-merge" ] || fail "real rebase fixture lacks rebase-merge"
printf 'foreign staged resolution\n' > "$REBASE_REPO/tracked.txt"
"$REAL_GIT" -C "$REBASE_REPO" add tracked.txt
REBASE_HEAD=$("$REAL_GIT" -C "$REBASE_REPO" rev-parse HEAD)
REBASE_STATUS=$("$REAL_GIT" -C "$REBASE_REPO" status --porcelain)
REBASE_INDEX_SUM=$(cksum < "$REBASE_GIT_DIR/index")
REBASE_META=$(find "$REBASE_GIT_DIR/rebase-merge" -type f -exec cksum {} \; | sort)
set +e
real_rebase_out=$(run_safe "$REBASE_REPO" main 2>&1)
real_rebase_rc=$?
set -e
assert_eq "real preexisting rebase refuses" "1" "$real_rebase_rc"
assert_contains "real preexisting rebase diagnostic" "$real_rebase_out" "mid-operation"
real_rebase_hook_out=$(run_real_hook "$REBASE_REPO" real-preexisting-rebase | decode_context)
assert_contains "real preexisting rebase hook warning" "$real_rebase_hook_out" "potentially stale"
[ -d "$REBASE_GIT_DIR/rebase-merge" ] || fail "helper removed real preexisting rebase"
assert_eq "real rebase HEAD preserved" "$REBASE_HEAD" "$("$REAL_GIT" -C "$REBASE_REPO" rev-parse HEAD)"
assert_eq "real rebase status preserved" "$REBASE_STATUS" "$("$REAL_GIT" -C "$REBASE_REPO" status --porcelain)"
assert_eq "real rebase index preserved" "$REBASE_INDEX_SUM" "$(cksum < "$REBASE_GIT_DIR/index")"
assert_eq "real rebase metadata preserved" "$REBASE_META" \
    "$(find "$REBASE_GIT_DIR/rebase-merge" -type f -exec cksum {} \; | sort)"

# Linked worktrees use a .git file, a common ref store and a worktree-specific
# index. Equal/behind inspection must preserve both this checkout and its sibling.
WORKTREE_OWNER="$INTEGRATION_ROOT/repo-worktree-owner"
LINKED_REPO="$INTEGRATION_ROOT/repo-linked"
"$REAL_GIT" clone -q "$ORIGIN" "$WORKTREE_OWNER"
"$REAL_GIT" -C "$WORKTREE_OWNER" checkout -qb sibling
"$REAL_GIT" -C "$WORKTREE_OWNER" worktree add -q "$LINKED_REPO" main
[ -f "$LINKED_REPO/.git" ] || fail "linked-worktree fixture lacks .git file"
LINKED_HEAD=$("$REAL_GIT" -C "$LINKED_REPO" rev-parse HEAD)
LINKED_GIT_DIR=$("$REAL_GIT" -C "$LINKED_REPO" rev-parse --absolute-git-dir)
OWNER_GIT_DIR=$("$REAL_GIT" -C "$WORKTREE_OWNER" rev-parse --absolute-git-dir)
LINKED_INDEX_SUM=$(cksum < "$LINKED_GIT_DIR/index")
OWNER_INDEX_SUM=$(cksum < "$OWNER_GIT_DIR/index")
OWNER_STATUS=$("$REAL_GIT" -C "$WORKTREE_OWNER" status --porcelain)
linked_equal_out=$(run_safe "$LINKED_REPO" main 2>&1)
assert_contains "linked equal success" "$linked_equal_out" "already matches queried"
assert_eq "linked equal HEAD preserved" "$LINKED_HEAD" "$("$REAL_GIT" -C "$LINKED_REPO" rev-parse HEAD)"
assert_eq "linked index preserved" "$LINKED_INDEX_SUM" "$(cksum < "$LINKED_GIT_DIR/index")"
assert_eq "sibling index preserved" "$OWNER_INDEX_SUM" "$(cksum < "$OWNER_GIT_DIR/index")"
assert_eq "sibling status preserved" "$OWNER_STATUS" "$("$REAL_GIT" -C "$WORKTREE_OWNER" status --porcelain)"
assert_ref_absent "linked equal temporary-ref cleanup" "$LINKED_REPO"

printf 'fifth remote update\n' > "$SEED/tracked.txt"
"$REAL_GIT" -C "$SEED" add tracked.txt
"$REAL_GIT" -C "$SEED" commit -qm fifth-remote-update
"$REAL_GIT" -C "$SEED" push -q
set +e
linked_behind_out=$(run_safe "$LINKED_REPO" main 2>&1)
linked_behind_rc=$?
set -e
assert_eq "linked behind refuses" "1" "$linked_behind_rc"
assert_contains "linked behind diagnostic" "$linked_behind_out" "shared checkout not auto-mutated"
linked_hook_out=$(run_real_hook "$LINKED_REPO" linked-worktree | decode_context)
assert_contains "linked hook recognizes .git file" "$linked_hook_out" "potentially stale"
assert_eq "linked behind HEAD preserved" "$LINKED_HEAD" "$("$REAL_GIT" -C "$LINKED_REPO" rev-parse HEAD)"
assert_eq "linked behind index preserved" "$LINKED_INDEX_SUM" "$(cksum < "$LINKED_GIT_DIR/index")"
assert_eq "linked sibling index preserved" "$OWNER_INDEX_SUM" "$(cksum < "$OWNER_GIT_DIR/index")"
assert_ref_absent "linked behind temporary-ref cleanup" "$LINKED_REPO"

# A superproject remote query must not recurse into an initialized submodule.
SUB_ORIGIN="$TEST_ROOT/integration/sub-origin.git"
SUB_SEED="$TEST_ROOT/integration/sub-seed"
SUPER_ORIGIN="$TEST_ROOT/integration/super-origin.git"
SUPER_SEED="$TEST_ROOT/integration/super-seed"
SUPER_REPO="$INTEGRATION_ROOT/repo-super"
"$REAL_GIT" init --bare -q "$SUB_ORIGIN"
"$REAL_GIT" init -q "$SUB_SEED"
"$REAL_GIT" -C "$SUB_SEED" config user.name fixture
"$REAL_GIT" -C "$SUB_SEED" config user.email fixture@example.invalid
printf 'sub one\n' > "$SUB_SEED/sub.txt"
"$REAL_GIT" -C "$SUB_SEED" add sub.txt
"$REAL_GIT" -C "$SUB_SEED" commit -qm sub-one
"$REAL_GIT" -C "$SUB_SEED" branch -M main
"$REAL_GIT" -C "$SUB_SEED" remote add origin "$SUB_ORIGIN"
"$REAL_GIT" -C "$SUB_SEED" push -q -u origin main
"$REAL_GIT" -C "$SUB_ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" init --bare -q "$SUPER_ORIGIN"
"$REAL_GIT" init -q "$SUPER_SEED"
"$REAL_GIT" -C "$SUPER_SEED" config user.name fixture
"$REAL_GIT" -C "$SUPER_SEED" config user.email fixture@example.invalid
"$REAL_GIT" -C "$SUPER_SEED" -c protocol.file.allow=always submodule add -q "$SUB_ORIGIN" sub
"$REAL_GIT" -C "$SUPER_SEED" commit -qam super-one
"$REAL_GIT" -C "$SUPER_SEED" branch -M main
"$REAL_GIT" -C "$SUPER_SEED" remote add origin "$SUPER_ORIGIN"
"$REAL_GIT" -C "$SUPER_SEED" push -q -u origin main
"$REAL_GIT" -C "$SUPER_ORIGIN" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" -c protocol.file.allow=always clone -q --recurse-submodules "$SUPER_ORIGIN" "$SUPER_REPO"
SUB_CHECKOUT="$SUPER_REPO/sub"
SUB_REF_BEFORE=$("$REAL_GIT" -C "$SUB_CHECKOUT" rev-parse refs/remotes/origin/main)
SUB_GIT_DIR=$("$REAL_GIT" -C "$SUB_CHECKOUT" rev-parse --absolute-git-dir)
printf 'submodule fetch sentinel\n' > "$SUB_GIT_DIR/FETCH_HEAD"
printf 'sub two\n' > "$SUB_SEED/sub.txt"
"$REAL_GIT" -C "$SUB_SEED" add sub.txt
"$REAL_GIT" -C "$SUB_SEED" commit -qm sub-two
"$REAL_GIT" -C "$SUB_SEED" push -q
SUB_REF_AFTER=$("$REAL_GIT" -C "$SUB_SEED" rev-parse HEAD)
"$REAL_GIT" -C "$SUPER_SEED/sub" fetch -q origin main
"$REAL_GIT" -C "$SUPER_SEED/sub" checkout -q "$SUB_REF_AFTER"
"$REAL_GIT" -C "$SUPER_SEED" add sub
"$REAL_GIT" -C "$SUPER_SEED" commit -qm super-two
"$REAL_GIT" -C "$SUPER_SEED" push -q
SUPER_HEAD=$("$REAL_GIT" -C "$SUPER_REPO" rev-parse HEAD)
set +e
submodule_out=$(run_safe "$SUPER_REPO" main 2>&1)
submodule_rc=$?
set -e
assert_eq "submodule remote query refuses behind" "1" "$submodule_rc"
assert_contains "submodule remote query diagnostic" "$submodule_out" "shared checkout not auto-mutated"
assert_eq "superproject HEAD preserved" "$SUPER_HEAD" "$("$REAL_GIT" -C "$SUPER_REPO" rev-parse HEAD)"
assert_eq "submodule tracking ref preserved" "$SUB_REF_BEFORE" \
    "$("$REAL_GIT" -C "$SUB_CHECKOUT" rev-parse refs/remotes/origin/main)"
assert_eq "submodule FETCH_HEAD preserved" "submodule fetch sentinel" "$(cat "$SUB_GIT_DIR/FETCH_HEAD")"
assert_ref_absent "submodule temporary-ref cleanup" "$SUPER_REPO"

# Portable hard timeout: make the remote query ignore TERM. The process-group watchdog must
# escalate to KILL and return within the deadline plus its one-second grace.
TIMEOUT_BIN="$TEST_ROOT/integration/timeout-bin"
TIMEOUT_MARKER="$TEST_ROOT/integration/timeout-query-started"
mkdir -p "$TIMEOUT_BIN"
for command_name in bash python3 mkdir hostname awk rm mktemp; do
    command_path=$(command -v "$command_name")
    ln -s "$command_path" "$TIMEOUT_BIN/$command_name"
done
cat > "$TIMEOUT_BIN/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "ls-remote" ] && [ ! -e "$TIMEOUT_MARKER" ]; then
    : > "$TIMEOUT_MARKER"
    trap '' TERM
    while :; do /bin/sleep 5; done
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$TIMEOUT_BIN/git"
SECONDS=0
set +e
timeout_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
    IWE_SAFE_PULL_FETCH_TIMEOUT=1 REAL_GIT_BIN="$REAL_GIT" TIMEOUT_MARKER="$TIMEOUT_MARKER" \
    PATH="$TIMEOUT_BIN" GIT_DIRTY_GUARD_TG_ALERTS=false \
    bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$REFSPEC_REPO" main 2>&1)
timeout_rc=$?
set -e
timeout_elapsed=$SECONDS
assert_eq "portable remote-query timeout refuses" "1" "$timeout_rc"
assert_contains "portable remote-query timeout diagnostic" "$timeout_out" "remote query/guard refused"
[ -e "$TIMEOUT_MARKER" ] || fail "timeout fixture never entered remote query"
[ "$timeout_elapsed" -ge 1 ] || fail "timeout returned before its one-second deadline"
[ "$timeout_elapsed" -lt 5 ] || fail "hard timeout took ${timeout_elapsed}s"
assert_eq "timeout preserves HEAD" "$REFSPEC_OLD_HEAD" "$("$REAL_GIT" -C "$REFSPEC_REPO" rev-parse HEAD)"
TIMEOUT_GIT_DIR=$("$REAL_GIT" -C "$REFSPEC_REPO" rev-parse --absolute-git-dir)
[ ! -d "$TIMEOUT_GIT_DIR/dirty-guard.lock" ] || fail "timeout leaked dirty-guard.lock"
assert_ref_absent "timeout temporary-ref cleanup" "$REFSPEC_REPO"

# External TERM/HUP/INT must also reach the isolated query process group. Otherwise
# a cancelled hook can leave git/ssh running after its EXIT cleanup has finished.
CANCEL_BIN="$TEST_ROOT/integration/cancel-bin"
CANCEL_STARTED="$TEST_ROOT/integration/cancel-query-started"
CANCEL_SURVIVED="$TEST_ROOT/integration/cancel-query-survived"
mkdir -p "$CANCEL_BIN"
cat > "$CANCEL_BIN/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "ls-remote" ]; then
    : > "$CANCEL_FETCH_STARTED"
    trap '' TERM INT HUP
    /bin/sleep 2
    : > "$CANCEL_FETCH_SURVIVED"
    exit 0
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$CANCEL_BIN/git"
HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
    IWE_SAFE_PULL_FETCH_TIMEOUT=20 REAL_GIT_BIN="$REAL_GIT" \
    CANCEL_FETCH_STARTED="$CANCEL_STARTED" CANCEL_FETCH_SURVIVED="$CANCEL_SURVIVED" \
    PATH="$CANCEL_BIN:$ORIGINAL_PATH" GIT_DIRTY_GUARD_TG_ALERTS=false \
    python3 -c '
import os
import signal
import subprocess
import sys
import time

script, repo, started, survived = sys.argv[1:]
process = subprocess.Popen(
    ["bash", script, repo, "main"],
    env=os.environ.copy(),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
deadline = time.monotonic() + 5
while not os.path.exists(started) and time.monotonic() < deadline:
    time.sleep(0.05)
if not os.path.exists(started):
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("cancel fixture never entered remote query")
os.killpg(process.pid, signal.SIGTERM)
returncode = process.wait(timeout=5)
if returncode == 0:
    raise SystemExit("cancelled safe-pull returned success")
time.sleep(2.5)
if os.path.exists(survived):
    raise SystemExit("remote-query child survived external cancellation")
' "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$REFSPEC_REPO" \
        "$CANCEL_STARTED" "$CANCEL_SURVIVED"
[ ! -d "$TIMEOUT_GIT_DIR/dirty-guard.lock" ] || fail "external cancellation leaked dirty-guard.lock"
assert_ref_absent "external cancellation temporary-ref cleanup" "$REFSPEC_REPO"

# Operations appearing after guard completion are refused and never cleaned up.
OP_REPO="$INTEGRATION_ROOT/repo-operation-race"
"$REAL_GIT" clone -q "$ORIGIN" "$OP_REPO"
INJECTED_GUARD="$TEST_ROOT/integration/injected-operation-guard.sh"
cat > "$INJECTED_GUARD" <<'EOF'
#!/usr/bin/env bash
git_dir=$("$REAL_GIT_BIN" -C "$1" rev-parse --absolute-git-dir)
case "$MARKER_KIND" in
    rebase-merge|rebase-apply) mkdir -p "$git_dir/$MARKER_KIND" ;;
    MERGE_HEAD|CHERRY_PICK_HEAD|REVERT_HEAD)
        "$REAL_GIT_BIN" -C "$1" rev-parse HEAD > "$git_dir/$MARKER_KIND"
        ;;
    *) exit 2 ;;
esac
exit 0
EOF
chmod +x "$INJECTED_GUARD"
for marker_kind in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    set +e
    operation_out=$(HOME="$INTEGRATION_HOME" IWE_ROOT="$INTEGRATION_ROOT" \
        IWE_SAFE_PULL_GUARD="$INJECTED_GUARD" REAL_GIT_BIN="$REAL_GIT" MARKER_KIND="$marker_kind" \
        GIT_DIRTY_GUARD_TG_ALERTS=false PATH="$ORIGINAL_PATH" \
        bash "$INTEGRATION_ROOT/scripts/iwe-safe-pull.sh" "$OP_REPO" main 2>&1)
    operation_rc=$?
    set -e
    assert_eq "$marker_kind race refuses" "1" "$operation_rc"
    assert_contains "$marker_kind race diagnostic" "$operation_out" "entered a git operation"
    OP_GIT_DIR=$("$REAL_GIT" -C "$OP_REPO" rev-parse --absolute-git-dir)
    case "$marker_kind" in
      *_HEAD)
        [ -f "$OP_GIT_DIR/$marker_kind" ] || fail "safe-pull removed injected $marker_kind"
        rm -f "$OP_GIT_DIR/$marker_kind"
        ;;
      *)
        [ -d "$OP_GIT_DIR/$marker_kind" ] || fail "safe-pull removed injected $marker_kind"
        rm -rf "${OP_GIT_DIR:?}/$marker_kind"
        ;;
    esac
done

assert_ref_absent "final temporary-ref cleanup" "$OP_REPO"
[ ! -s "$AUDIT_VIOLATIONS" ] || fail "mutating Git command reached integration fixture: $(cat "$AUDIT_VIOLATIONS")"
echo "PASS: Pull-on-Touch is non-mutating, retryable, and honest about stale shared checkouts"
