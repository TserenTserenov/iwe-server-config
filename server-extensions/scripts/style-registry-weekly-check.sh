#!/usr/bin/env bash
# style-registry-weekly-check.sh — weekly checks for the concept-kinds registry and the A14
# detector (РП-388 Ф22). Called from extensions/week-close.after.style-registry-checks.md.
#
# Four blocking checks (exit 1 if any fails) and one report:
#   1. the detector's copy of the registry is in sync with the Pack registry
#   2. every FPF pattern cited in the registry still exists in the local FPF copy
#   3. the detector and entry test suites pass
#   4. no registry-like file in any workspace repo is missing from the registry catalog
#   report: A14 / A14_AMBIGUOUS hits of the last 7 days by agent, ambiguous heads that recur,
#           registry rows still in draft, and the age of the last A14 acceptance run
#
# Env: IWE_ROOT (default $HOME/IWE), STYLE_LOG (default $HOME/.claude/logs/style-violations.log).

set -uo pipefail

ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG="${STYLE_LOG:-$HOME/.claude/logs/style-violations.log}"
REGISTRY="${CONCEPT_KINDS_REGISTRY:-$ROOT/PACK-digital-platform/pack/digital-platform/concept-kinds-registry.yaml}"
CATALOG_SCRIPT="$ROOT/DS-ecosystem-development/0.OPS/scripts/registry-catalog.py"
export CONCEPT_KINDS_REGISTRY="$REGISTRY"

FAILED=0
check() {  # check <title> <command...>
  local title="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    echo "ok    $title"
  else
    echo "FAIL  $title"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
    FAILED=$((FAILED + 1))
  fi
}

echo "## Проверки реестра понятий и родов ($(date +%F))"
check "копия реестра для детектора совпадает с реестром в паке" python3 "$ROOT/scripts/build-concept-kinds-tsv.py" --check
check "все ссылки реестра на FPF находятся в локальной копии FPF" python3 "$ROOT/scripts/build-concept-kinds-tsv.py" --check-fpf
for suite in test-response-clarity-hook.sh test-concept-kinds.sh test-style-entries.sh; do
  check "тесты $suite" bash "$ROOT/.claude/hooks/tests/$suite"
done
if [ -f "$CATALOG_SCRIPT" ]; then
  check "в каталоге реестров нет пропущенных реестров" env IWE_ROOT="$ROOT" python3 "$CATALOG_SCRIPT" --orphans --strict
else
  check "в каталоге реестров нет пропущенных реестров (скрипт каталога найден)" test -f "$CATALOG_SCRIPT"
fi

echo
echo "## Журнал детектора за 7 дней"
if [ -r "$LOG" ]; then
  SINCE=$(date -v-7d +%F 2>/dev/null || date -d '7 days ago' +%F)
  awk -F' \\| ' -v since="$SINCE" '
    substr($1, 1, 10) >= since && ($3 == "A14" || $3 == "A14_AMBIGUOUS") { n[$2 " " $3]++ }
    END { if (length(n) == 0) print "  срабатываний A14 нет"; for (k in n) printf "  %s: %d\n", k, n[k] }
  ' "$LOG" | sort
  echo "  Неоднозначные слова, которые чаще всего попадали в предложения о частях (кандидаты на уточнение в реестре):"
  python3 - "$LOG" "$SINCE" "$ROOT/.claude/hooks/lib/concept-kinds.tsv" <<'PY'
import collections, re, sys
log, since, tsv = sys.argv[1:4]
stems = [ln.rstrip("\n").split("\t")[1] for ln in open(tsv, encoding="utf-8")
         if ln.count("\t") == 1 and ln.startswith("ambiguous\t")]
counts = collections.Counter()
for line in open(log, encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split(" | ")
    if len(parts) > 4 and parts[0][:10] >= since and parts[2] == "A14_AMBIGUOUS":
        for stem in stems:
            if re.search(r"(?<![а-яё])" + stem, parts[4].lower()):
                counts[stem] += 1
for stem, n in counts.most_common(5):
    print(f"    {n:3d}  {stem}")
if not counts:
    print("    нет")
PY
else
  echo "  журнал $LOG не найден"
fi

echo
echo "## Реестр"
if [ -f "$REGISTRY" ]; then
  python3 - "$REGISTRY" <<'PY'
import sys, yaml, collections
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
c = collections.Counter(t["status"] for t in d["terms"])
print(f"  {len(d['kinds'])} родов, {len(d['terms'])} понятий; по статусам: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items())))
draft = [t["term"] for t in d["terms"] if t["status"] == "draft"]
if draft:
    print(f"  ждут подтверждения пилота ({len(draft)}): " + ", ".join(draft))
PY
else
  echo "  реестр не найден: $REGISTRY"
fi
LAST=$(ls -1d "$ROOT"/.iwe-runtime/a14-acceptance/*/ 2>/dev/null | sort | tail -1)
if [ -n "$LAST" ]; then
  echo "  последний прогон приёмки A14: $(basename "$LAST")"
else
  echo "  прогон приёмки A14 ещё не повторяли: python3 scripts/a14-acceptance.py run"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "Итог: все проверки пройдены."; else echo "Итог: не прошли $FAILED проверок(и)."; fi
[ "$FAILED" -eq 0 ]
