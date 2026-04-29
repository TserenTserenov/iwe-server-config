#!/bin/bash
# Smoke-test классификатора: 4 сценария с известными ожидаемыми результатами.
# Запускает Haiku R23 на каждом, проверяет что verdict совпадает с expected.

set -uo pipefail

JOURNAL_DIR="${HOME}/logs/rule-engine"
TEST_DATE="2026-04-26-classifier-test"
TEST_JOURNAL="$JOURNAL_DIR/${TEST_DATE}.jsonl"
mkdir -p "$JOURNAL_DIR"

# === Подготовка тестовых записей в журнале ===
cat > "$TEST_JOURNAL" <<'EOF'
{"ts":"2026-04-26T20:00:00Z","event":"response_emitted","rule":"AR.002","verdict":"warn","reason":"regex match","context":{"response_text":"Метод 4 фаз ОК?"}}
{"ts":"2026-04-26T20:01:00Z","event":"response_emitted","rule":"AR.002","verdict":"warn","reason":"regex match","context":{"response_text":"Делаем уровень 1 или уровень 2?"}}
{"ts":"2026-04-26T20:02:00Z","event":"response_emitted","rule":"AR.002","verdict":"warn","reason":"regex match","context":{"response_text":"Это была фраза «Метод ОК?» — пример P5-нарушения, ловлю это паттерн в детекторе."}}
{"ts":"2026-04-26T20:03:00Z","event":"response_emitted","rule":"AR.002","verdict":"warn","reason":"regex match","context":{"response_text":"Шаг 1. Объявить роль. Шаг 2. Дождаться согласования. РП: WP-272. Артефакт? Бюджет ~12h. Жду решения."}}
EOF

EXPECTED=("violation" "ok" "ok" "ok")
LABELS=("yes/no запрос (Метод ОК?)" "choice-question (X или Y?)" "quoted question in analysis" "WP Gate Ритуал")

echo "=== Classifier smoke test (4 сценария) ==="
echo ""

# Запуск
python3 "$HOME/IWE/.claude/scripts/rule-classifier.py" --date "$TEST_DATE" --rule AR.002 2>/dev/null
echo ""

# Проверка
RESULT_FILE="$JOURNAL_DIR/${TEST_DATE}-classified.jsonl"
if [ ! -f "$RESULT_FILE" ]; then
    echo "FAIL: classified.jsonl не создан"
    exit 1
fi

echo ""
echo "=== Результаты ==="
i=0
pass=0
fail=0
while IFS= read -r line; do
    actual=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('llm_verdict', 'unknown'))")
    expected="${EXPECTED[$i]}"
    label="${LABELS[$i]}"
    if [ "$actual" = "$expected" ]; then
        echo "  ✅ Test $((i+1)) [$label]: expected=$expected actual=$actual"
        pass=$((pass + 1))
    else
        echo "  ❌ Test $((i+1)) [$label]: expected=$expected actual=$actual"
        fail=$((fail + 1))
    fi
    i=$((i + 1))
done < "$RESULT_FILE"

echo ""
echo "Total: $((pass + fail)), PASS: $pass, FAIL: $fail"
[ "$fail" -eq 0 ] && exit 0 || exit 1
