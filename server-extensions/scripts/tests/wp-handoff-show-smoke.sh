#!/usr/bin/env bash
# wp-handoff-show-smoke.sh -- WP-484 F257 M3: the reader prints freshness, the
# three handoff fields from the origin snapshot and the card digest, and says so
# plainly when something is missing.  Disposable repos only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
CHECKER="${IWE_HANDOFF_CHECKER_SRC:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/wp-handoff-check.py}"
if [ ! -f "$CHECKER" ]; then
  echo "SKIP: wp-handoff-check.py не найден ($CHECKER); задать IWE_HANDOFF_CHECKER_SRC"
  exit 0
fi
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2" && ok || bad "$3 (нет строки: $2)"; }
lacks() { printf '%s' "$1" | grep -qF -- "$2" && bad "$3 (лишняя строка: $2)" || ok; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wp-handoff-show-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
git init -q --bare "$TMP/origin.git"
mkdir -p "$TMP/iwe" && git clone -q "$TMP/origin.git" "$TMP/iwe/DS-test" 2>/dev/null
G="$TMP/iwe/DS-test"
git -C "$G" config user.email t@example.com
git -C "$G" config user.name test
git -C "$G" checkout -q -b main
mkdir -p "$G/inbox/WP-9" "$G/scripts"
cp "$CHECKER" "$G/scripts/wp-handoff-check.py"
cat >"$G/inbox/WP-9/WP-9.md" <<'CARD'
---
wp: 9
phases:
  Ф1: in_progress
---

# Карточка

## Осталось

**Следующий шаг:** Ф1 — начать с проверки хука
**Контекст для следующей сессии:** см. отчёт
**Актуально до:** 01.01.2020
→ memory: none

## Закрытие
CARD
git -C "$G" add -A && git -C "$G" commit -q -m card && git -C "$G" push -q origin main 2>/dev/null

run() { IWE_ROOT="$TMP/iwe" IWE_SCRIPTS="$SCRIPTS" IWE_GOVERNANCE_REPO=DS-test bash "$SCRIPTS/wp-handoff-show.sh" "$@" 2>&1; }

OUT="$(run WP-9)"
has "$OUT" "Передача работы по WP-9" "заголовок"
has "$OUT" "Свежесть копии: OK" "свежая копия"
lacks "$OUT" "читать только со снимка origin" "свежая копия без предупреждения"
has "$OUT" "Следующий шаг: Ф1 — начать с проверки хука" "поле Следующий шаг"
has "$OUT" "Контекст для следующей сессии: см. отчёт" "поле Контекст"
has "$OUT" "Актуально до: 01.01.2020 (дата прошла)" "прошедшая дата помечена"
has "$OUT" "Ревизия карточки (отпечаток):" "отпечаток ревизии"

# A second clone pushes a new card revision; the first copy is now behind.
git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
git -C "$TMP/other" config user.email t@example.com
git -C "$TMP/other" config user.name test
sed -i.bak 's/начать с проверки хука/новое значение с origin/' "$TMP/other/inbox/WP-9/WP-9.md"
rm -f "$TMP/other/inbox/WP-9/WP-9.md.bak"
git -C "$TMP/other" commit -q -am newer && git -C "$TMP/other" push -q origin main 2>/dev/null
git -C "$G" fetch -q origin
OUT="$(run WP-9)"
has "$OUT" "Свежесть копии: STALE" "отставание обнаружено"
has "$OUT" "Карточку читать только со снимка origin" "предупреждение при STALE"
has "$OUT" "новое значение с origin" "значение берётся со снимка origin, не из рабочей копии"
lacks "$OUT" "начать с проверки хука" "старое значение рабочей копии не показано"

# The reader never fetches.  A server revision that is not local at all is called out
# (the older local snapshot is shown, loudly marked); when the server commit is already
# local the reader pins exactly that commit even though the local origin/main lags.
OLD_ORIGIN="$(git -C "$G" rev-parse origin/main)"
sed -i.bak 's/новое значение с origin/третье значение сервера/' "$TMP/other/inbox/WP-9/WP-9.md"
rm -f "$TMP/other/inbox/WP-9/WP-9.md.bak"
git -C "$TMP/other" commit -q -am third && git -C "$TMP/other" push -q origin main 2>/dev/null
OUT="$(run WP-9)"
has "$OUT" "Внимание: локальный снимок origin/main отстаёт от сервера" "объекта сервера нет локально: предупреждение"
has "$OUT" "новое значение с origin" "показан локальный снимок"
lacks "$OUT" "третье значение сервера" "сервер не читался молча"
git -C "$G" fetch -q origin main:refs/heads/snap 2>/dev/null
git -C "$G" update-ref refs/remotes/origin/main "$OLD_ORIGIN"
OUT="$(run WP-9)"
has "$OUT" "Снимок: серверная версия" "объект сервера локально: читается по нему"
has "$OUT" "третье значение сервера" "значение с сервера, не из отстающей ссылки"
lacks "$OUT" "Внимание: локальный снимок" "при закреплённом снимке нет предупреждения об отставании"
git -C "$G" update-ref refs/remotes/origin/main "$(git -C "$G" rev-parse refs/heads/snap)"

OUT="$(run WP-404)"
has "$OUT" "на origin/main не найдена" "нет карточки"

OUT="$(env -u IWE_GOVERNANCE_REPO IWE_ROOT="$TMP/iwe" IWE_SCRIPTS="$SCRIPTS" bash "$SCRIPTS/wp-handoff-show.sh" WP-9 2>&1)"
has "$OUT" "Репозиторий управления не задан" "нет IWE_GOVERNANCE_REPO"

OUT="$(run not-a-wp)"; RC=$?
has "$OUT" "usage:" "плохой аргумент"
[ "$RC" = 0 ] && ok || bad "плохой аргумент не должен ронять вызывающего (rc=$RC)"

OUT="$(IWE_ROOT="$TMP/iwe" IWE_SCRIPTS="$SCRIPTS" IWE_GOVERNANCE_REPO=DS-missing bash "$SCRIPTS/wp-handoff-show.sh" WP-9 2>&1)"
has "$OUT" "не найден" "нет репозитория"

echo "wp-handoff-show smoke: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
