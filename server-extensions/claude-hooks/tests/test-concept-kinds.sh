#!/bin/bash
# test-concept-kinds.sh — concept-kind registry copy feeds the A14 detector (РП-388 Ф21).
# Proves the point of the registry: a term added ONLY to the registry changes what the
# detector catches, with no change to hook code; generator guards bad input and drift.
#
# Run: bash .claude/hooks/tests/test-concept-kinds.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() {  # check <name> <command...>: passes when the command succeeds
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   $name"; else FAIL=$((FAIL+1)); echo "FAIL $name"; fi
}

# Minimal registry: one system term, one description term ("колод")
registry() {  # registry <extra term line>
  cat <<YAML
schema_version: 1
kinds:
  - {id: system, name: система, test: "q", part_relation: "x"}
  - {id: description, name: описание, test: "q", part_relation: "x"}
  - {id: ambiguous, name: неоднозначно, test: "q", part_relation: "x"}
terms:
  - {term: агент, kind: system, stems: [агент], status: pilot, basis: "b"}
$1
YAML
}
build() {  # build <registry-file> <tsv-file>
  CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$ROOT/scripts/build-concept-kinds-tsv.py" >/dev/null 2>"$TMP/build.err"
}
# Copy of the hooks dir so the hook reads the test's own lib/concept-kinds.tsv
mkdir -p "$TMP/hooks/lib" "$TMP/home/.claude" "$TMP/proj"
cp "$ROOT/.claude/hooks/response-clarity-hook.sh" "$TMP/hooks/"
cp "$ROOT"/.claude/hooks/*.py "$TMP/hooks/" 2>/dev/null || true

LIST='Агент — это система. В ней есть:

- **Агент-ядро** — принимает запрос.
- **Колода** — хранит порядок.
- **Мир** — всё остальное.'
python3 -I - "$TMP/t.jsonl" <<PY
import json, sys
rows = [{"type": "user", "message": {"content": [{"type": "text", "text": "q"}]}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": """$LIST"""}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY
fires() {  # fires: did the hook log A14 for the list reply?
  rm -f "$TMP/home/.claude/logs/style-violations.log"
  printf '{"transcript_path":"%s","session_id":"s"}' "$TMP/t.jsonl" \
    | HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$TMP/hooks/response-clarity-hook.sh" >/dev/null 2>&1
  grep -q "| A14 |" "$TMP/home/.claude/logs/style-violations.log" 2>/dev/null
}

registry "" >"$TMP/r0.yaml"
build "$TMP/r0.yaml" "$TMP/hooks/lib/concept-kinds.tsv"
NOT_CAUGHT=1; fires && NOT_CAUGHT=0
check "term absent from the registry: list not flagged" test "$NOT_CAUGHT" -eq 1

registry "  - {term: колода, kind: description, stems: [колод], status: draft, basis: \"b\"}" >"$TMP/r1.yaml"
build "$TMP/r1.yaml" "$TMP/hooks/lib/concept-kinds.tsv"
check "same term added to the registry only: list flagged" fires

registry "  - {term: колода, kind: ambiguous, stems: [колод], status: draft, basis: \"b\"}" >"$TMP/r2.yaml"
build "$TMP/r2.yaml" "$TMP/hooks/lib/concept-kinds.tsv"
NOT_CAUGHT=1; fires && NOT_CAUGHT=0
check "ambiguous kind never blocks" test "$NOT_CAUGHT" -eq 1

# Ambiguous words: part-whole sentence is logged as A14_AMBIGUOUS, never as a blocking A14
python3 -I - "$TMP/t2.jsonl" <<'PY'
import json, sys
rows = [{"type": "user", "message": {"content": [{"type": "text", "text": "q"}]}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "Колода входит в агента."}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY
logged() {  # logged <rule>: did the hook log this exact rule for the sentence reply?
  rm -f "$TMP/home/.claude/logs/style-violations.log"
  printf '{"transcript_path":"%s","session_id":"s"}' "$TMP/t2.jsonl" \
    | HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$TMP/hooks/response-clarity-hook.sh" >/dev/null 2>&1
  grep -q "| $1 |" "$TMP/home/.claude/logs/style-violations.log" 2>/dev/null
}
build "$TMP/r2.yaml" "$TMP/hooks/lib/concept-kinds.tsv"
check "ambiguous term in a part-whole sentence: logged as A14_AMBIGUOUS" logged A14_AMBIGUOUS
NOT_CAUGHT=1; logged A14 && NOT_CAUGHT=0
check "ambiguous term never produces a blocking A14" test "$NOT_CAUGHT" -eq 1
build "$TMP/r1.yaml" "$TMP/hooks/lib/concept-kinds.tsv"
check "same sentence with a description term: A14" logged A14

# Generator guards
registry "  - {term: x, kind: nosuchkind, stems: [икс], status: draft, basis: \"b\"}" >"$TMP/bad1.yaml"
check "unknown kind is rejected" bash -c '! CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$3" >/dev/null 2>&1' _ "$TMP/bad1.yaml" "$TMP/o.tsv" "$ROOT/scripts/build-concept-kinds-tsv.py"
registry "  - {term: x, kind: description, stems: [\"a;rm -rf\"], status: draft, basis: \"b\"}" >"$TMP/bad2.yaml"
check "stem outside the allowed charset is rejected" bash -c '! CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$3" >/dev/null 2>&1' _ "$TMP/bad2.yaml" "$TMP/o.tsv" "$ROOT/scripts/build-concept-kinds-tsv.py"
registry "  - {term: x, kind: description, stems: [икс], status: draft}" >"$TMP/bad3.yaml"
check "term without basis is rejected" bash -c '! CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$3" >/dev/null 2>&1' _ "$TMP/bad3.yaml" "$TMP/o.tsv" "$ROOT/scripts/build-concept-kinds-tsv.py"
# A stem that does not compile, or that matches the empty string, would silently break or flood A14
registry "  - {term: x, kind: description, stems: [\"аб(\"], status: draft, basis: \"b\"}" >"$TMP/bad4.yaml"
check "unbalanced stem is rejected" bash -c '! CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$3" >/dev/null 2>&1' _ "$TMP/bad4.yaml" "$TMP/o.tsv" "$ROOT/scripts/build-concept-kinds-tsv.py"
registry "  - {term: x, kind: description, stems: [\"аб|\"], status: draft, basis: \"b\"}" >"$TMP/bad5.yaml"
check "stem with an empty alternative is rejected" bash -c '! CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$3" >/dev/null 2>&1' _ "$TMP/bad5.yaml" "$TMP/o.tsv" "$ROOT/scripts/build-concept-kinds-tsv.py"

# --check-fpf: a section reference must match the section heading, not just the pattern heading
printf '## A.7 - Strict Distinction\n\n#### A.7:5.6 - Formal inclusion\n\n### A.7:End\n' >"$TMP/spec.md"
registry "" >"$TMP/fpf-ok.yaml"; printf '# cites A.7:5.6\n' >>"$TMP/fpf-ok.yaml"
registry "" >"$TMP/fpf-bad.yaml"; printf '# cites A.7:99.99\n' >>"$TMP/fpf-bad.yaml"
check "--check-fpf accepts an existing section" bash -c 'CONCEPT_KINDS_REGISTRY="$1" FPF_SPEC="$2" python3 "$3" --check-fpf >/dev/null 2>&1' _ "$TMP/fpf-ok.yaml" "$TMP/spec.md" "$ROOT/scripts/build-concept-kinds-tsv.py"
check "--check-fpf rejects a section that does not exist" bash -c '! CONCEPT_KINDS_REGISTRY="$1" FPF_SPEC="$2" python3 "$3" --check-fpf >/dev/null 2>&1' _ "$TMP/fpf-bad.yaml" "$TMP/spec.md" "$ROOT/scripts/build-concept-kinds-tsv.py"

build "$TMP/r1.yaml" "$TMP/d.tsv"
echo "# stale" >>"$TMP/d.tsv"
check "--check detects a drifted copy" bash -c '! CONCEPT_KINDS_REGISTRY="$1" CONCEPT_KINDS_TSV="$2" python3 "$3" --check >/dev/null 2>&1' _ "$TMP/r1.yaml" "$TMP/d.tsv" "$ROOT/scripts/build-concept-kinds-tsv.py"

# No copy at all: the hook falls back to its built-in lists and still runs
rm -f "$TMP/hooks/lib/concept-kinds.tsv"
printf '{"transcript_path":"%s","session_id":"s"}' "$TMP/t.jsonl" \
  | HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$TMP/hooks/response-clarity-hook.sh" >/dev/null 2>&1
check "missing copy: hook still exits 0" test "$?" -eq 0

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
