#!/usr/bin/env bash
# phase-gate-check.sh -- WP-561 Ф45 (20.10, peer session 2026-10-20-16): single
# source for "are this WP's open phases what the last close baselined",
# extracted out of wp-sync-bundle.sh (WP-561 Ф42, 2026-10-19-24, Claude+Codex)
# so the open-time gate and the new day-close recheck (Ф45) call the exact
# same classifier instead of growing a second implementation (P2).
#
# Caller contract: before sourcing, set ARCHIVE_SCRIPT, FIND_PYTHON3 and
# STRATEGY_DIR to the same values wp-sync-bundle.sh resolves them to --
# ARCHIVE_SCRIPT/scripts/wp-archive-closed-phases.py and
# FIND_PYTHON3/scripts/lib/find-python3.sh from the IWE workspace root (not
# the governance repo -- these two ship from a different repository);
# STRATEGY_DIR is the governance repo itself, the one that holds the card
# being checked (phase_gate_check passes it to the archiver as
# --governance-repo, found the hard way 20.10: an unset STRATEGY_DIR makes
# the archiver fail "card not found" for every call, which this function
# then reports as PARSE_FAILED -- not a loud crash, so a caller that forgets
# this would see every WP it checks come back silently unverifiable).
#
# phase_gate_check <wp_num> <wp_file> prints one line "OUTCOME|detail" to
# stdout: MATCH|, MISMATCH|<diff>, NO_BASELINE|<reason>, PARSE_FAILED|<reason>.
# Never exits non-zero on its own -- callers decide what each outcome means.

extract_self_phase_snapshot() {
  local file="$1" wp_num="$2" py
  py="$("$FIND_PYTHON3" --stdlib-only 2>/dev/null)" || { echo "ABSENT"; return; }
  "$py" - "$file" "WP-${wp_num}" <<'PYEOF'
import csv
import re
import sys

path, want = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

fm = []
fence_count = 0
for ln in lines:
    if ln.strip() == "---":
        fence_count += 1
        if fence_count == 2:
            break
        continue
    if fence_count == 1:
        fm.append(ln)

try:
    start = next(i for i, ln in enumerate(fm) if ln.strip() == "handoff_snapshot:")
except StopIteration:
    print("ABSENT")
    sys.exit(0)

block = []
for ln in fm[start + 1:]:
    if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:", ln):
        break
    block.append(ln)

entries = []
cur = None
for ln in block:
    m = re.match(r"^\s*-\s*ref:\s*(.+)$", ln)
    if m:
        if cur is not None:
            entries.append(cur)
        cur = {"ref": m.group(1).strip().strip('"'), "has_key": False, "items": []}
        continue
    if cur is None:
        continue
    m2 = re.match(r"^\s+observed_open_phases:\s*\[(.*)\]\s*$", ln)
    if m2:
        cur["has_key"] = True
        raw = m2.group(1).strip()
        if raw:
            # csv.reader respects quotes (cold review, peer-session
            # 2026-10-19-24): a bare raw.split(",") would split a quoted
            # item that itself contains a comma into phantom extra entries.
            parsed_row = next(csv.reader([raw], skipinitialspace=True), [])
            cur["items"] = [x.strip().strip('"') for x in parsed_row if x.strip()]
if cur is not None:
    entries.append(cur)

self_entries = [e for e in entries if e["ref"] == want]
if not self_entries:
    print("ABSENT")
elif not self_entries[-1]["has_key"]:
    print("MALFORMED")
else:
    print("FOUND")
    for it in self_entries[-1]["items"]:
        print("ITEM:" + it)
PYEOF
}

# WP-561 Ф42, peer-session 2026-10-19-24 (Claude+Codex, консенсус ходов 1-7):
# сверяет фактический список открытых фаз (## ФN без терминального маркера,
# тем же классификатором, что использует архивация -- Card.analyze() внутри
# wp-archive-closed-phases.py --json, read-only, без --apply) со снимком,
# который прошлый close записал в self-entry handoff_snapshot. Единый снимок
# байт карточки: архиватор сам читает файл один раз (Card.__init__); эта
# функция читает тот же файл отдельным вызовом только для self-entry --
# расхождение между двумя чтениями одного файла в рамках одного bundle-рана
# не рассматривается отдельно (тот же файл, та же git-проверка снимка, что
# уже выполнена выше в main() до вызова этой функции).
# Печатает ОДНУ строку "OUTCOME|detail": MATCH|, MISMATCH|<diff>,
# NO_BASELINE|<reason>, PARSE_FAILED|<reason>.
phase_gate_check() {
  local wp_num="$1" wp_file="$2"
  local py
  py="$("$FIND_PYTHON3" --stdlib-only 2>/dev/null)" || { echo "PARSE_FAILED|нет интерпретатора python3"; return; }
  if [[ ! -r "$ARCHIVE_SCRIPT" ]]; then
    echo "PARSE_FAILED|архиватор не найден: ${ARCHIVE_SCRIPT}"
    return
  fi

  local report_json rc
  report_json=$("$py" "$ARCHIVE_SCRIPT" "$wp_num" --json --governance-repo "$STRATEGY_DIR" 2>/dev/null)
  rc=$?
  if [[ $rc -eq 1 ]]; then
    echo "PARSE_FAILED|архиватор: карточка не найдена или ошибка usage (exit 1)"
    return
  fi
  if [[ -z "$report_json" ]]; then
    echo "PARSE_FAILED|архиватор вернул пустой вывод (exit ${rc})"
    return
  fi
  # rc==3 здесь не отдельная ветка: self_check.match уже внутри report_json
  # и проверяется ниже тем же JSON-разбором -- не дублируем условие.

  local current_ids
  current_ids=$("$py" -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    print("__JSON_ERROR__")
    sys.exit(0)
if not r.get("self_check", {}).get("match", False):
    print("__SELF_CHECK_MISMATCH__")
    sys.exit(0)
for n in r.get("no_terminal_marker", []):
    print(n["phase"])
' <<<"$report_json")

  if [[ "$current_ids" == "__JSON_ERROR__" ]]; then
    echo "PARSE_FAILED|JSON-вывод архиватора не распарсился"
    return
  fi
  if [[ "$current_ids" == "__SELF_CHECK_MISMATCH__" ]]; then
    echo "PARSE_FAILED|архиватор: self-check mismatch (независимый скан не совпал с парсером фаз)"
    return
  fi

  local snapshot_raw
  snapshot_raw=$(extract_self_phase_snapshot "$wp_file" "$wp_num")
  if [[ "$snapshot_raw" == "ABSENT" ]]; then
    echo "NO_BASELINE|нет self-entry handoff_snapshot для WP-${wp_num} — baseline появится при следующем close (best-effort)"
    return
  fi
  if [[ "$snapshot_raw" == "MALFORMED" ]]; then
    echo "PARSE_FAILED|self-entry handoff_snapshot для WP-${wp_num} существует без observed_open_phases"
    return
  fi

  local snapshot_ids added removed
  snapshot_ids=$(printf '%s\n' "$snapshot_raw" | grep '^ITEM:' | sed 's/^ITEM://')
  added=$(comm -23 <(printf '%s\n' "$current_ids" | grep -v '^$' | sort -u) <(printf '%s\n' "$snapshot_ids" | grep -v '^$' | sort -u) || true)
  removed=$(comm -13 <(printf '%s\n' "$current_ids" | grep -v '^$' | sort -u) <(printf '%s\n' "$snapshot_ids" | grep -v '^$' | sort -u) || true)

  if [[ -z "$added" && -z "$removed" ]]; then
    echo "MATCH|"
  else
    local added_label removed_label
    added_label=$(printf '%s' "$added" | tr '\n' ' ')
    removed_label=$(printf '%s' "$removed" | tr '\n' ' ')
    echo "MISMATCH|появились открытые: [${added_label}]; пропали из текущего списка (возможно переоткрыты/сменили id): [${removed_label}]"
  fi
}