#!/usr/bin/env bash
# wp-archive-closed-phases-smoke.sh -- WP-561 Ф24 (peer-session 2026-09-27-09):
# fixture card with mixed phases; asserts candidate selection (positive marker
# required, vetoes honoured), atomic --apply, delta post-check, idempotent rerun,
# guard skip, recovery-journal refusal. Pure files, no git needed.
set -uo pipefail
TOOL="$(cd "$(dirname "$0")/.." && pwd)/wp-archive-closed-phases.py"
[ -f "$TOOL" ] || { echo "FAIL: $TOOL not found"; exit 1; }
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
GOV="$SANDBOX/gov"; RT="$SANDBOX/runtime"; mkdir -p "$GOV/inbox/WP-9201" "$GOV/scripts" "$RT"
CARD="$GOV/inbox/WP-9201/WP-9201.md"
cat > "$GOV/scripts/archive-section-guard.sh" <<'G'
#!/usr/bin/env bash
# fixture guard (mimics archive-section-guard.sh v2.2 payloads), behaviour chosen by keyword in the heading
case "$*" in
  *GUARDFAIL*)   echo '{"guard_version":"2.2","verdict":"block","rules_triggered":["R0"],"evidence":[{"line":1,"rule":"R0","text":"x"}],"incoming_links":[]}'; exit 1;;
  *ESC_R3*)      echo '{"guard_version":"2.2","verdict":"escalate","rules_triggered":["R3"],"evidence":[{"line":1,"rule":"R3","text":"отдельного действия не требуется"}],"incoming_links":[]}'; exit 2;;
  *ESC_LINK*)    echo '{"guard_version":"2.2","verdict":"escalate","rules_triggered":[],"evidence":[],"incoming_links":[{"kind":"ambiguous-html-link","line":9}]}'; exit 2;;
  *ESC_R2*)      echo '{"guard_version":"2.2","verdict":"escalate","rules_triggered":["R2","R3"],"evidence":[{"line":1,"rule":"R2","text":"y"},{"line":2,"rule":"R3","text":"z"}],"incoming_links":[]}'; exit 2;;
  *ESC_BROKEN*)  echo 'not json at all'; exit 2;;
  *ESC_UNKNOWN*) echo '{"guard_version":"2.2","verdict":"escalate","rules_triggered":["R9"],"evidence":[{"line":1,"rule":"R9","text":"q"}],"incoming_links":[]}'; exit 2;;
  *MUTATE*)      printf '\n<!-- external writer touched the card during guard checks -->\n' >> "$1"; echo '{"guard_version":"2.2","verdict":"allow","rules_triggered":[],"evidence":[],"incoming_links":[]}'; exit 0;;
  *GUARD_ERR*)   echo 'usage: archive-section-guard.sh <file> --section ...' >&2; exit 3;;
esac
echo '{"guard_version":"2.2","verdict":"allow","rules_triggered":[],"evidence":[],"incoming_links":[]}'; exit 0
G
write_card() {
cat > "$CARD" <<'C'
---
wp: 9201
title: "Fixture"
status: in_progress
created: 2026-08-01
phases:
  Ф3: done
  Ф4: in_progress
---
# WP-9201

## Ф1 ✅ — closed by heading marker
Body of phase one.

## Ф2 — no marker, no checkboxes (prose-open)
Body of phase two.

## Ф3 — closed via frontmatter
Body of phase three.

## Ф4 ✅ — heading says closed but frontmatter says in_progress
Body of phase four.

## Ф5 ✅ — has an unchecked item
- [ ] still open

## Ф6 ✅ — has an anchor
<!-- h id=H-1 -->
Body six.

## Ф7 ✅ GUARDFAIL — guard will refuse
Body seven.

## Ф8 ✅ — referenced by next step
Body eight.

## Ф11 ✅ ESC_R3 — guard escalates on verbs only
Body eleven, всё сделано, отдельного действия не требуется.

## Ф12 ✅ ESC_LINK — guard escalates on incoming link
Body twelve.

## Ф13 ✅ ESC_R2 — guard escalates with a structural rule too
Body thirteen.

## Ф14 ✅ ESC_BROKEN — guard output unparsable
Body fourteen.

## Ф15 ✅ ESC_UNKNOWN — guard reports an unknown rule
Body fifteen.

## Ф9 ✅ — keep-last victim 1
Body nine.

## Ф10 ✅ — keep-last victim 2
Body ten.

## Осталось

**Что пробовали:** x
**Что узнали:** y
**Что дальше:**
- [ ] finish Ф8
**Следующий шаг:** Ф8 → довести
**Контекст для следующей сессии:** z
**Заблокировано:** нет
**Зависит от:** нет
**Актуально до:** н/п

## Журнал

- 2026-08-01: создана
C
}
run() { python3 "$TOOL" 9201 --governance-repo "$GOV" --runtime-dir "$RT" --json "$@"; }
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

echo "scenario 1: dry-run candidate selection"
write_card
out=$(run)
assert "$(printf '%s' "$out" | jq_ "','.join(sorted(c['phase'] for c in d['candidates']))")" "Ф1,Ф11,Ф12,Ф13,Ф14,Ф15,Ф3,Ф7" "candidates = ✅/frontmatter closed without vetoes (guard runs only on apply)"
assert "$(printf '%s' "$out" | jq_ "','.join(sorted(v['phase'] for v in d['vetoed']))")" "Ф10,Ф4,Ф5,Ф6,Ф8,Ф9" "vetoed: fm in_progress, unchecked, anchor, next-step ref, keep-last x2"
assert "$(printf '%s' "$out" | jq_ "','.join(n['phase'] for n in d['no_terminal_marker'])")" "Ф2" "prose-open phase without marker is not a candidate"
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['ok'] if 'ostalos' in d else 'n/a'")" "n/a" "ostalos check only on request"
assert "$(test -f "$GOV/inbox/WP-9201/WP-9201-archive.md" && echo yes || echo no)" "no" "dry-run writes nothing"

echo "scenario 2: --ostalos-check on a healthy section"
out=$(run --ostalos-check)
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['ok']")" "True" "8 fields present, no subsections -> ok"

echo "scenario 3: --apply moves Ф1, Ф3; Ф7 skipped by guard; journal done; frontmatter/journal updated"
before_lines=$(wc -l < "$CARD" | tr -d ' ')
out=$(run --apply); rc=$?
assert "$rc" "0" "exit 0"
assert "$(printf '%s' "$out" | jq_ "','.join(d['result']['moved'])")" "Ф1,Ф3,Ф11" "moved = allow (Ф1, Ф3) + escalate with PURE R3 (Ф11)"
assert "$(printf '%s' "$out" | jq_ "','.join(d['result']['moved_under_escalation'])")" "Ф11" "the R3-escalated move is flagged"
assert "$(printf '%s' "$out" | jq_ "','.join(s['phase'] for s in d['result']['skipped_by_guard'])")" "Ф7,Ф12,Ф13,Ф14,Ф15" "block, incoming link, structural rule, unparsable, unknown rule -> all skipped (fail closed)"
assert "$(grep -c 'Ф11 → архив.*перенесено под эскалацией Стража R3 (v2.2), эвиденс: «отдельного действия не требуется»' "$CARD")" "1" "journal line names the escalation and quotes the evidence (Kimi)"
assert "$(python3 -c 'import json,glob,sys; j=json.load(open(glob.glob(sys.argv[1]+"/*.json")[0])); b=[x for x in j["blocks"] if x["phase"]=="Ф11"][0]; print(b["guard"]["version"], b["guard"]["verdict"], b["guard"]["payload"]["rules_triggered"][0], "range" in b)' "$RT/wp-archive-journal")" "2.2 escalate-overridden-pure-R3 R3 True" "recovery journal keeps guard version, verdict, full payload and section range (Codex)"
ARCH="$GOV/inbox/WP-9201/WP-9201-archive.md"
assert "$(grep -c '^## Ф1 ✅' "$ARCH")" "1" "Ф1 block in archive"
assert "$(grep -c '^## Ф3 ' "$ARCH")" "1" "Ф3 block in archive"
assert "$(grep -c '^## Ф1 ✅' "$CARD")" "0" "Ф1 gone from card"
assert "$(grep -c '^## Ф3 ' "$CARD")" "0" "Ф3 gone from card"
assert "$(grep -c '^## Ф7 ' "$CARD")" "1" "Ф7 kept in card"
assert "$(grep -c '^archive: WP-9201-archive.md$' "$CARD")" "1" "frontmatter archive:"
assert "$(grep -c "^archived_last: $(date +%F)$" "$CARD")" "1" "frontmatter archived_last:"
assert "$(grep -c '^auto_archive_policy: protocol-close-5c-2026-09-27$' "$CARD")" "1" "audit trail of the executed policy (Codex: trail, not licence)"
assert "$(grep -c 'Ф1 → архив (автоархивация при закрытии' "$CARD")" "1" "journal line for Ф1"
assert "$(grep -c 'Ф3 → архив (автоархивация при закрытии' "$CARD")" "1" "journal line for Ф3"
assert "$(grep -c '^## Осталось$' "$CARD")" "1" "«Осталось» untouched"
assert "$(grep -c '^phases:$' "$CARD")" "1" "frontmatter phases map preserved"
assert "$(ls "$RT/wp-archive-journal" | wc -l | tr -d ' ')" "1" "one journal file"
assert "$(python3 -c 'import json,glob,sys; print(json.load(open(glob.glob(sys.argv[1]+"/*.json")[0]))["state"])' "$RT/wp-archive-journal")" "done" "journal state done"
assert "$(ls "$RT/wp-archive-locks" 2>/dev/null | wc -l | tr -d ' ')" "0" "lock released"
after_lines=$(wc -l < "$CARD" | tr -d ' ')
assert "$([ "$after_lines" -lt "$before_lines" ] && echo shorter || echo not-shorter)" "shorter" "card shrank"

echo "scenario 4: rerun is idempotent (nothing left to move, no duplicate journal lines)"
out=$(run --apply); rc=$?
assert "$rc" "0" "exit 0"
assert "$(printf '%s' "$out" | jq_ "d['result'].get('reason','') if not d['result'].get('applied') else 'applied-again'")" "no candidate passed the guard" "remaining candidates are all guard-vetoed"
assert "$(grep -c 'Ф1 → архив' "$CARD")" "1" "journal line not duplicated"
assert "$(grep -c '^## Перенесено' "$ARCH")" "1" "archive section not duplicated"

echo "scenario 5: pending recovery journal blocks a new --apply (exit 3)"
write_card; rm -f "$ARCH"
python3 - "$RT/wp-archive-journal/WP-9201-1.json" <<'J'
import json,sys; json.dump({"wp":"9201","state":"archive_written"}, open(sys.argv[1],"w"))
J
out=$(run --apply); rc=$?
assert "$rc" "3" "exit 3 on pending journal"
assert "$(printf '%s' "$out" | jq_ "'recovery pending' in d['result'].get('refused','')")" "True" "refusal names the pending journal"
assert "$(grep -c '^## Ф1 ✅' "$CARD")" "1" "card untouched"
rm -f "$RT"/wp-archive-journal/*.json

echo "scenario 6: guard missing -> --apply refused (exit 3), dry-run still works"
mv "$GOV/scripts/archive-section-guard.sh" "$GOV/scripts/guard.bak"
out=$(run --apply); rc=$?
assert "$rc" "3" "exit 3 without the guard"
assert "$(grep -c '^## Ф1 ✅' "$CARD")" "1" "card untouched"
out=$(run); rc=$?
assert "$rc" "0" "dry-run exit 0 without the guard"
mv "$GOV/scripts/guard.bak" "$GOV/scripts/archive-section-guard.sh"

echo "scenario 7: duplicate H2 heading -> ambiguous, vetoed"
write_card; printf '\n## Ф1 ✅ — closed by heading marker\nA second section with the same heading.\n' >> "$CARD"
out=$(run)
assert "$(printf '%s' "$out" | jq_ "any(v['phase']=='Ф1' and any('не уникален' in x for x in v['vetoes']) for v in d['vetoed'])")" "True" "duplicate heading vetoes Ф1"

echo "scenario 8: lock busy -> exit 3, bounded wait"
write_card; mkdir -p "$RT/wp-archive-locks/WP-9201.lock"; printf 'pid=%s\n' "$$" > "$RT/wp-archive-locks/WP-9201.lock/owner"
out=$(python3 "$TOOL" 9201 --governance-repo "$GOV" --runtime-dir "$RT" --json --apply --lock-wait 1); rc=$?
assert "$rc" "3" "exit 3 when a live owner holds the lock"
rm -rf "$RT/wp-archive-locks/WP-9201.lock"

echo "scenario 9: --ostalos-check flags nested history and missing fields"
write_card; python3 - "$CARD" <<'P'
import sys; p=sys.argv[1]; t=open(p).read()
t=t.replace("**Актуально до:** н/п", "### Ф3 (история)\nold layer here")
open(p,"w").write(t)
P
out=$(run --ostalos-check)
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['ok']")" "False" "not ok"
assert "$(printf '%s' "$out" | jq_ "','.join(d['ostalos']['missing_fields'])")" "Актуально до" "missing field named"
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['subsections_inside']")" "1" "nested subsection counted"


mkcard() {  # <frontmatter-extra-lines> <body>  -> writes $CARD with standard head/Осталось/Журнал
  { printf -- '---\nwp: 9201\ntitle: "Fixture"\nstatus: in_progress\ncreated: 2026-08-01\n%s---\n# WP-9201\n\n%s\n## Осталось\n\n**Что пробовали:** x\n**Что узнали:** y\n**Что дальше:**\n- [ ] z\n**Следующий шаг:** нет\n**Контекст для следующей сессии:** z\n**Заблокировано:** нет\n**Зависит от:** нет\n**Актуально до:** н/п\n\n## Журнал\n\n- 2026-08-01: создана\n' "$1" "$2"; } > "$CARD"
}
reset_rt() { rm -rf "$RT/wp-archive-journal" "$RT/wp-archive-locks" "$GOV/inbox/WP-9201/WP-9201-archive.md"; }

echo "scenario 10 (review C1): sub-phase Ф16.2 is its own id -- frontmatter Ф16: done must not license it"
reset_rt; mkcard $'phases:\n  Ф16: done\n' $'## Ф16 ✅ — parent closed\nBody 16.\n\n## Ф16.2 — sub-phase still open in prose\nBody 16.2 (no checkbox, no marker).\n\n## Ф17 ✅ — pad\nBody.\n\n## Ф18 ✅ — pad\nBody.\n\n## Ф19 ✅ — pad\nBody.\n'
out=$(run)
assert "$(printf '%s' "$out" | jq_ "','.join(sorted(c['phase'] for c in d['candidates']))")" "Ф16,Ф17" "Ф16 (fm done) and Ф17 (✅) are candidates; Ф16.2 is not"
assert "$(printf '%s' "$out" | jq_ "','.join(n['phase'] for n in d['no_terminal_marker'])")" "Ф16.2" "Ф16.2 reported with its FULL id as lacking a marker"

echo "scenario 11 (review H1): block followed by three blank lines moves without a false rollback"
reset_rt; mkcard '' $'## Ф1 ✅ — closed\nBody one.\n\n\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n'
out=$(run --apply); rc=$?
assert "$rc" "0" "exit 0"
assert "$(printf '%s' "$out" | jq_ "','.join(d['result']['moved'])")" "Ф1" "Ф1 moved"
assert "$(grep -c '^## Ф1 ✅' "$GOV/inbox/WP-9201/WP-9201-archive.md")" "1" "block landed in the archive exactly once"
assert "$(python3 -c 'import json,glob,sys; print(json.load(open(glob.glob(sys.argv[1]+"/*.json")[0]))["state"])' "$RT/wp-archive-journal")" "done" "journal done, no rollback"
assert "$(grep -c '^## Ф2 ✅' "$CARD")" "1" "neighbour section intact"

echo "scenario 12 (review C2): an external writer changes the card while the guard runs -> refused, nothing written"
reset_rt; mkcard '' $'## Ф1 ✅ MUTATE — guard side effect\nBody.\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n'
out=$(run --apply); rc=$?
assert "$rc" "3" "exit 3"
assert "$(printf '%s' "$out" | jq_ "'changed on disk' in d['result'].get('refused','')")" "True" "refusal names the on-disk change"
assert "$(test -f "$GOV/inbox/WP-9201/WP-9201-archive.md" && echo yes || echo no)" "no" "archive not created"
assert "$(grep -c '^## Ф1 ✅ MUTATE' "$CARD")" "1" "section still in the card"

echo "scenario 13 (review M1): a ~~~ line inside a \`\`\` fence does not swallow the rest of the card"
reset_rt; mkcard '' $'## Ф1 ✅ — has code\n```\n~~~ not a fence toggle\nstill code\n```\nBody.\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n'
out=$(run --ostalos-check)
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['exact_headings']")" "1" "«Осталось» still found after the fence"
assert "$(printf '%s' "$out" | jq_ "','.join(sorted(c['phase'] for c in d['candidates']))")" "Ф1" "Ф1 still a candidate (sections parsed)"

echo "scenario 14 (review M3): list-form frontmatter phases (- id / status) are honoured"
reset_rt; mkcard $'phases:\n  - id: Ф2\n    status: in_progress\n' $'## Ф1 ✅ — pad\nBody.\n\n## Ф2 ✅ — heading says closed, frontmatter list says in_progress\nBody.\n\n## Ф3 ✅ — pad\nBody.\n\n## Ф4 ✅ — pad\nBody.\n'
out=$(run)
assert "$(printf '%s' "$out" | jq_ "any(v['phase']=='Ф2' and any('phases.Ф2=in_progress' in x for x in v['vetoes']) for v in d['vetoed'])")" "True" "Ф2 vetoed by list-form frontmatter status"

echo "scenario 15 (review M2): «Следующий шаг агента:» with a multi-line value still vetoes the referenced phase"
reset_rt; mkcard '' $'## Ф8 ✅ — referenced below\nBody.\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n'
python3 - "$CARD" <<'P'
import sys; p=sys.argv[1]; t=open(p).read()
t=t.replace("**Следующий шаг:** нет", "**Следующий шаг агента:**\n- сначала Ф8 → довести\n- потом остальное")
open(p,"w").write(t)
P
out=$(run)
assert "$(printf '%s' "$out" | jq_ "any(v['phase']=='Ф8' and any('Следующий шаг' in x for x in v['vetoes']) for v in d['vetoed'])")" "True" "Ф8 vetoed via the variant field name and continuation line"

echo "scenario 16 (review M2): a shadow «## Осталось (старое)» blocks --apply and is reported"
reset_rt; mkcard '' $'## Ф1 ✅ — pad\nBody.\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n\n## Осталось (старое)\n\n- [ ] leftover\n'
out=$(run --ostalos-check --apply); rc=$?
assert "$rc" "3" "exit 3"
assert "$(printf '%s' "$out" | jq_ "'hygiene precondition' in d['result'].get('refused','')")" "True" "refusal names the hygiene precondition"
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['ostalos_headings']")" "2" "both Осталось-like headings counted"
assert "$(printf '%s' "$out" | jq_ "d['ostalos']['ok']")" "False" "hygiene check flags the shadow section"

echo "scenario 17 (review M5): guard usage/io error (rc 3) aborts --apply instead of counting as a skip"
reset_rt; mkcard '' $'## Ф1 ✅ GUARD_ERR — broken guard call\nBody.\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n'
out=$(run --apply); rc=$?
assert "$rc" "3" "exit 3"
assert "$(printf '%s' "$out" | jq_ "'guard.sh error' in d['result'].get('refused','')")" "True" "refusal names the guard error"

echo "scenario 18 (review M6): file mode survives the atomic rewrite"
reset_rt; mkcard '' $'## Ф1 ✅ — pad\nBody.\n\n## Ф2 ✅ — pad\nBody.\n\n## Ф3 ✅ — pad\nBody.\n'; chmod 644 "$CARD"
out=$(run --apply); rc=$?
assert "$rc" "0" "exit 0"
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
assert "$(mode "$CARD")" "644" "card keeps 644"
assert "$(mode "$GOV/inbox/WP-9201/WP-9201-archive.md")" "644" "new archive is world-readable (0666 & ~umask)"

[ "$fails" = 0 ] && echo "PASS: all scenarios" || { echo "FAIL: $fails assertion(s)"; exit 1; }
