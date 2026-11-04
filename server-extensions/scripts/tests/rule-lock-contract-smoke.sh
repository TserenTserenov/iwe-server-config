#!/bin/bash
# rule-lock-contract-smoke.sh -- WP-7 F294: lock contract v1 between the rules-pack
# generator and the rule engine. A rule has a lock (executable) only when its hook is
# "<file>::<function>"; rules without one stay in the registry as unsupported/unknown
# and the engine never executes them. Covers the derivation table, malformed input,
# external references, the legacy registry (no `lock` key), and the engine filter.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/.claude/scripts/generate-rules-registry.py"
ENGINE="$ROOT/.claude/hooks/rule-engine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"
PACK="$H/IWE/PACK-agent-rules/rules"
REG="$H/IWE/.claude/rules-registry.yaml"

fail() { echo "FAIL: $*" >&2; exit 1; }
# HOME is swapped for the generator, which hides per-user site-packages (where PyYAML
# often lives); keep them importable.
USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
export PYTHONPATH="$USER_SITE${PYTHONPATH:+:$PYTHONPATH}"
HOME="$H" python3 -c 'import yaml' 2>/dev/null || fail "PyYAML is not importable: the test cannot reach the code under test"
gen() { HOME="$H" python3 "$GEN" "$@" >"$TMP/out" 2>"$TMP/err"; }
reset_pack() { rm -rf "$H/IWE"; mkdir -p "$PACK" "$H/IWE/.claude"; }
# rule ID TYPE PRIORITY [extra frontmatter lines...]: a valid rule plus the extras.
rule() {
    local id="$1" type="$2" prio="$3"; shift 3
    {
        printf -- '---\nid: %s\nname: rule %s\ntype: %s\npriority: %s\nstatus: active\n' "$id" "$id" "$type" "$prio"
        printf 'triggers: [evt]\ntests: {positive: [violation], negative: [compliant]}\n'
        for line in "$@"; do printf '%s\n' "$line"; done
        printf -- '---\nbody\n'
    } > "$PACK/$id.md"
}
reg_field() { python3 -c 'import sys,yaml; r=yaml.safe_load(open(sys.argv[1])); x=[q for q in r["rules"] if q["id"]==sys.argv[2]][0]; print(x.get(sys.argv[3]))' "$REG" "$1" "$2"; }

# 1. Derivation table -------------------------------------------------------------
reset_pack
rule AR.001 structural 1 'hook: rule-engine.sh::check_wp_gate'
rule AR.002 behavioural 6 'enforcement: [{mechanism: null, class: unsupported}]'
rule AR.003 behavioural 7
rule AR.004 behavioural 8 'enforcement: [{mechanism: null, class: unsupported}, {mechanism: x.sh, class: unknown}]'
rule AR.005 behavioural 9 'hook: "ArchGate review, не вшит, E3"'
rule AR.006 behavioural 10 'hook: null'
rule AR.007 behavioural 10 'enforcement: []'
rule AR.008 behavioural 10 'hook: code-style-hook.sh'
gen; rc=$?
[ "$rc" -eq 0 ] || fail "derivation: rc=$rc $(cat "$TMP/err")"
for pair in AR.001:executable AR.002:unsupported AR.003:unknown AR.004:unknown AR.005:unknown AR.006:unknown AR.007:unknown AR.008:unknown; do
    got=$(reg_field "${pair%%:*}" lock)
    [ "$got" = "${pair##*:}" ] || fail "derivation: ${pair%%:*} lock=$got, expected ${pair##*:}"
done
[ "$(reg_field AR.001 hook)" = "rule-engine.sh::check_wp_gate" ] || fail "derivation: binding lost"
[ "$(reg_field AR.002 hook)" = "None" ] || fail "derivation: hook of unbound rule must be null"
[ "$(reg_field AR.005 hook)" = "None" ] || fail "prose hook: must not stay in the hook field"
[ "$(reg_field AR.005 hook_note)" = "ArchGate review, не вшит, E3" ] || fail "prose hook: text must move to hook_note"
[ "$(reg_field AR.008 hook_note)" = "code-style-hook.sh" ] || fail "bare script name is a note, not a binding"
grep -q "^schema_version: '1.1'$" "$REG" || fail "schema_version must be 1.1"
grep -q 'lock: executable 1, unsupported 1, unknown 6' "$TMP/out" || fail "lock counts line wrong: $(cat "$TMP/out")"
# Order: priority ascending, rules without a lock are in the list too.
order=$(python3 -c 'import yaml,sys; print(" ".join(r["id"] for r in yaml.safe_load(open(sys.argv[1]))["rules"]))' "$REG")
[ "$order" = "AR.001 AR.002 AR.003 AR.004 AR.005 AR.006 AR.007 AR.008" ] || fail "order changed: $order"
gen --validate; [ "$?" -eq 0 ] || fail "strict validate must pass for rules without a lock"

# 2. Malformed input is an error, never "unknown" --------------------------------
expect_invalid() {  # description, then the extra lines of the single rule
    local what="$1"; shift
    reset_pack; rule AR.001 structural 1 "$@"
    gen --validate; rc=$?
    [ "$rc" -eq 2 ] || fail "$what: expected exit 2, got $rc"
    gen || fail "$what: generate mode must still succeed"
    grep -q 'rule_count: 0' "$REG" || fail "$what: broken rule must be skipped in generate mode"
}
expect_invalid "empty hook" 'hook: ""'
expect_invalid "blank hook" 'hook: "   "'
expect_invalid "hook of wrong type" 'hook: 123'
expect_invalid "enforcement not a list" 'enforcement: unsupported'
expect_invalid "enforcement entry not a mapping" 'enforcement: [unsupported]'
expect_invalid "unknown enforcement class" 'enforcement: [{mechanism: null, class: maybe}]'
expect_invalid "lock written in the rule file" 'lock: executable'
expect_invalid "enforcement class of the wrong type" 'enforcement: [{mechanism: null, class: []}]'
expect_invalid "enforcement entry without class" 'enforcement: [{mechanism: null}]'

# 3. References between rules ------------------------------------------------------
reset_pack
rule AR.001 structural 1 'related: {depends_on: [DP.M.020]}'
gen --validate; rc=$?
[ "$rc" -eq 0 ] || fail "external reference: rc=$rc $(cat "$TMP/err")"
grep -q 'external references to other packs.*: 1' "$TMP/err" || fail "external reference must be counted on stderr"
grep -q 'AR.001: depends_on -> DP.M.020' "$TMP/err" || fail "external reference must be listed on stderr"
if grep -q 'DP.M.020' "$TMP/out"; then fail "external reference must not go to stdout"; fi
reset_pack; rule AR.001 structural 1 'related: {depends_on: [AR.999]}'
gen --validate; [ "$?" -eq 2 ] || fail "dangling AR id must stay an error"
reset_pack; rule AR.001 structural 1 'related: {depends_on: ["DP.M.020\n"]}'
gen --validate; [ "$?" -eq 2 ] || fail "external id with a trailing newline must be an error"
reset_pack; rule AR.001 structural 1 'related: {depends_on: [DP.M.02O]}'
gen --validate; [ "$?" -eq 2 ] || fail "typo in an external id must be an error"

# 4. Engine: only executable rules run ---------------------------------------------
JOURNAL="$TMP/journal"; mkdir -p "$JOURNAL"
engine() {  # registry-file event context-json
    RULE_REGISTRY="$1" RULE_EVENT="$2" RULE_CONTEXT="$3" RULE_JOURNAL_DIR="$JOURNAL" \
        bash "$ENGINE" dispatch >"$TMP/eout" 2>"$TMP/eerr"
}
cat > "$TMP/engine-registry.yaml" <<'YAML'
schema_version: '1.1'
rule_count: 8
rules:
- {id: AR.T0, type: structural, priority: 0, status: active, triggers: [evt1], hook: null, lock: unsupported}
- {id: AR.T1, type: structural, priority: 1, status: active, triggers: [evt1], hook: 'rule-engine.sh::check_wp_gate', lock: executable}
- {id: AR.T2, type: structural, priority: 2, status: active, triggers: [evt1], hook: null, hook_note: 'not wired', lock: unknown}
- {id: AR.T3, type: structural, priority: 1, status: active, triggers: [evt2], hook: 'rule-engine.sh::check_wp_gate'}
- {id: AR.T4, type: structural, priority: 1, status: active, triggers: [evt3], hook: 'not wired, E3'}
- {id: AR.T5, type: structural, priority: 1, status: active, triggers: [evt4], hook: 'rule-engine.sh::check_function_that_does_not_exist', lock: executable}
- {id: AR.T6, type: structural, priority: 1, status: active, triggers: [evt5], hook: null, lock: executable}
- {id: AR.T7, type: structural, priority: 1, status: active, triggers: [evt6], hook: 'rule-engine.sh::check_wp_gate ', lock: executable}
YAML
engine "$TMP/engine-registry.yaml" evt1 '{"user_consent": false}'
grep -q '"verdict":"block"' "$TMP/eout" && grep -q '"rule_id":"AR.T1"' "$TMP/eout" || fail "engine: executable rule must run: $(cat "$TMP/eout")"
if grep -q 'AR.T0\|AR.T2' "$TMP/eout"; then fail "engine: rules without a lock must not appear among applied rules: $(cat "$TMP/eout")"; fi
engine "$TMP/engine-registry.yaml" evt1 '{"user_consent": true}'
grep -q '"verdict":"ok"' "$TMP/eout" || fail "engine: consent given must pass: $(cat "$TMP/eout")"
engine "$TMP/engine-registry.yaml" evt2 '{"user_consent": false}'
grep -q '"rule_id":"AR.T3"' "$TMP/eout" && grep -q '"verdict":"block"' "$TMP/eout" || fail "engine: legacy record with a valid binding must run: $(cat "$TMP/eout")"
engine "$TMP/engine-registry.yaml" evt3 '{}'
grep -q '"verdict":"ok"' "$TMP/eout" && grep -q 'no rules match' "$TMP/eout" || fail "engine: legacy record with prose hook must be skipped: $(cat "$TMP/eout")"
engine "$TMP/engine-registry.yaml" evt4 '{}'
grep -q '"verdict":"ok"' "$TMP/eout" || fail "engine: unresolvable function must not change the verdict: $(cat "$TMP/eout")"
grep -q 'not implemented' "$JOURNAL"/*.jsonl || fail "engine: unresolvable function must be journaled"
engine "$TMP/engine-registry.yaml" evt5 '{}'
grep -q '"verdict":"block"' "$TMP/eout" || fail "engine: executable without a binding must fail loudly: $(cat "$TMP/eout")"
grep -q 'executable but has no valid hook binding' "$TMP/eerr" || fail "engine: contract error must name the rule on stderr"
engine "$TMP/engine-registry.yaml" evt6 '{}'
grep -q '"verdict":"block"' "$TMP/eout" || fail "engine: hook padded with spaces is not a binding, must fail loudly: $(cat "$TMP/eout")"
sed -i.bak "s/lock: unknown/lock: bogus/" "$TMP/engine-registry.yaml"
engine "$TMP/engine-registry.yaml" evt1 '{"user_consent": true}'
grep -q '"verdict":"block"' "$TMP/eout" || fail "engine: unknown lock value must fail loudly: $(cat "$TMP/eout")"
grep -q "unknown lock value 'bogus'" "$TMP/eerr" || fail "engine: unknown lock value must be named on stderr"

echo "PASS: rule lock contract (generator + engine)"
