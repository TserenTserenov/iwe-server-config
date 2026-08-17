#!/usr/bin/env bash
# routing: helper  called-by=day-close(5g)  deterministic=true
# see WP-530 Ф5 п.1, 17.08 peer-session с Kimi (DS-my-strategy/sessions/2026-08/17/2026-08-17-08-lock-hot-file-wp-context/)
#
# day-close-5g-apply.sh — line-exact чекбокс-замена в WP-context файле поверх
# wp-context-guarded-edit (session-guard.sh): находит подпункт по тексту
# задачи (игнорируя текущий статус чекбокса — [ ]/[x]/[X] — при поиске),
# переключает статус, пишет только если hash файла на момент вызова
# совпадает с тем, что вызывающий (LLM-агент в day-close шаге 5g) прочитал
# ранее через Read.
#
# Почему отдельный скрипт, не встроено в wp-context-guarded-edit: тот —
# чистый lock+hash-check примитив без знания о семантике markdown-чекбоксов
# (Kimi, ход 1 — single responsibility). Почему не через LLM Edit tool
# напрямую: Edit tool не проходит через session-guard.sh как процесс, не
# может участвовать в lock-протоколе (Kimi, ход 5 — вариант В).
#
# Ввод (JSON через stdin, не аргументы — надёжнее разделителя в командной
# строке при произвольном тексте задач, Kimi ход 5/6):
#   {"pairs": [{"text": "<точный текст подпункта без чекбокса>",
#               "target_status": " "|"x"}, ...]}
#
# Результат — по каждой паре, JSON-строка в stdout:
#   {"result": "ok", "line": "..."}                              — статус сменён
#   {"result": "no-op", "reason": "already_done", "line": "..."} — уже целевой статус (не эта команда его выставила — Kimi ход 9, идемпотентность ≠ silent success)
#   {"result": "error", "reason": "LINE_NOT_FOUND", "text": "..."}
#   {"result": "error", "reason": "LINE_AMBIGUOUS", "text": "...", "count": N}
#
# Все пары одного вызова защищены ОДНИМ hash-check в начале (не N отдельных
# lock-циклов) — принятый trade-off, см. комментарий wp-context-guarded-edit
# в session-guard.sh (Kimi ход 7/8: защищает от конфликта с другими guarded
# writers, не от процессов, пишущих в обход протокола).
#
# Использование:
#   echo '{"pairs":[...]}' | day-close-5g-apply.sh <file> --expected-hash <hash> [IWE_ROOT]
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

FILE=""
EXPECTED_HASH=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-hash) EXPECTED_HASH="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
FILE="${POSITIONAL[0]:-}"
IWE="${POSITIONAL[1]:-${IWE_ROOT:-$HOME/IWE}}"

if [[ -z "$FILE" ]]; then
  echo "Использование: echo '{\"pairs\":[...]}' | $0 <file> --expected-hash <hash> [IWE_ROOT]" >&2
  exit 1
fi
if [[ -z "$EXPECTED_HASH" ]]; then
  echo "day-close-5g-apply.sh: --expected-hash обязателен" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_GUARD="$SCRIPT_DIR/session-guard.sh"
if [[ ! -x "$SESSION_GUARD" ]]; then
  echo "day-close-5g-apply.sh: session-guard.sh не найден рядом ($SESSION_GUARD)" >&2
  exit 1
fi

# Written to a temp file, not interpolated into the python source below --
# pair text comes from arbitrary WP-context markdown, and a literal `"""`
# in it would have broken out of a triple-quoted string and injected code
# (found in self-review before sending this to Kimi for cold-context review).
PAIRS_JSON_FILE=$(mktemp)
trap 'rm -f "$PAIRS_JSON_FILE"' EXIT
cat > "$PAIRS_JSON_FILE"

# Applies every pair inside ONE python3 process so the whole batch runs under
# a single wp-context-guarded-edit lock hold (accepted trade-off, see header
# comment above) instead of re-reading/re-writing the file per pair.
IWE_ROOT="$IWE" bash "$SESSION_GUARD" wp-context-guarded-edit "$FILE" --expected-hash "$EXPECTED_HASH" -- \
  python3 - "$FILE" "$PAIRS_JSON_FILE" <<'PYEOF'
import json, os, re, sys

file_path, pairs_json_path = sys.argv[1], sys.argv[2]
with open(pairs_json_path, "r", encoding="utf-8") as f:
    pairs = json.load(f).get("pairs", [])

with open(file_path, "r", encoding="utf-8") as f:
    lines = f.read().split("\n")

results = []
for pair in pairs:
    text = pair["text"]
    target_status = pair["target_status"]
    pattern = re.compile(r"^(\s*-\s*\[)[ xX](\]\s*)" + re.escape(text) + r"\s*$")
    matches = [i for i, line in enumerate(lines) if pattern.match(line)]

    if len(matches) == 0:
        results.append({"result": "error", "reason": "LINE_NOT_FOUND", "text": text})
        continue
    if len(matches) > 1:
        results.append({"result": "error", "reason": "LINE_AMBIGUOUS", "text": text, "count": len(matches)})
        continue

    idx = matches[0]
    current_status = re.match(r"^\s*-\s*\[([ xX])\]", lines[idx]).group(1)
    # " " has no case; x/X both mean "done" -- compare case-insensitively so
    # an already-[X] line isn't reported as "ok" for a target_status of "x".
    if current_status.lower() == target_status.lower():
        results.append({"result": "no-op", "reason": "already_done", "line": lines[idx]})
        continue

    lines[idx] = pattern.sub(r"\g<1>" + target_status + r"\g<2>" + text, lines[idx])
    results.append({"result": "ok", "line": lines[idx]})

# Write back only if at least one pair actually changed something — an
# all-no-op batch shouldn't touch mtime/hash for the next reader. Atomic
# tmp+rename (not a direct overwrite): a kill -9 mid-write on a direct
# open(file_path, "w") truncates the file immediately on open, before any
# content lands -- os.replace is a single filesystem rename, so a crash
# either leaves the original file untouched or the new one fully in place,
# never a half-written mix (found by cold-context review before deploy).
if any(r["result"] == "ok" for r in results):
    tmp_path = file_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp_path, file_path)

for r in results:
    print(json.dumps(r, ensure_ascii=False))

# ok/no-op both count as a successful outcome for the caller (Kimi turn 10);
# any error (LINE_NOT_FOUND/LINE_AMBIGUOUS) must not be maskable by an
# overall exit 0 -- the caller has to parse the per-pair JSON either way, but
# the exit code alone should already say "at least one pair needs attention".
sys.exit(1 if any(r["result"] == "error" for r in results) else 0)
PYEOF
STATUS=$?

exit "$STATUS"
