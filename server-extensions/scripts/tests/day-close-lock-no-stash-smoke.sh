#!/bin/bash
# day-close-lock-no-stash-smoke.sh — регресс-тест на инцидент 05.09 (WP-484).
#
# Замок закрытия дня прятал в stash ВСЁ рабочее дерево перед `pull --rebase` и трижды подряд
# стёр незакоммиченную работу параллельных сессий. Главная проверка здесь одна: после acquire
# рабочее дерево, индекс и локальный HEAD побайтово те же, что были до вызова. Остальные
# проверки — что при этом замок продолжает делать свою работу (берёт лок, видит чужой свежий
# маркер, видит уже закрытый день) и что публикация метки проходит через pre-push хук freeze.
#
# Запуск: bash scripts/tests/day-close-lock-no-stash-smoke.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_SH="$SCRIPT_DIR/../day-close-lock.sh"
# Хук живёт в governance-репозитории — это ОТДЕЛЬНЫЙ репозиторий, не подкаталог корневого,
# поэтому путь считается от корня рабочего пространства, а не от каталога этого скрипта
# (в изолированной копии корневого репо DS-my-strategy рядом просто нет).
PREPUSH_HOOK="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/.githooks/pre-push"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/day-close-lock-smoke.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: ожидалось '$3', получено '$2'"; fi; }

GOV="SANDBOX-gov"
CLONE="$SANDBOX/$GOV"

git_sandbox() { git -C "$CLONE" "$@"; }

# acquire в песочнице: WORKSPACE_DIR/GOVERNANCE_REPO подменяются через окружение,
# iwe-env-bootstrap.sh их уважает (переменная-первоисточник, п. 1 его же докстринга).
run_acquire() {
  ( cd "$CLONE" && WORKSPACE_DIR="$SANDBOX" GOVERNANCE_REPO="$GOV" bash "$LOCK_SH" acquire >/dev/null 2>&1 )
  echo $?
}

setup_sandbox() {
  git init --quiet --bare "$SANDBOX/origin.git"
  git clone --quiet "$SANDBOX/origin.git" "$CLONE"
  git_sandbox config user.email "smoke@example.invalid"
  git_sandbox config user.name "Smoke Test"
  echo "base" > "$CLONE/tracked.txt"
  git_sandbox add tracked.txt
  git_sandbox commit --quiet -m "base"
  git_sandbox push --quiet -u origin HEAD:main
  git_sandbox branch --quiet -M main
  git_sandbox branch --quiet --set-upstream-to=origin/main main
}

# Слепок ровно того, что прежняя реализация теряла: содержимое рабочих файлов,
# состояние индекса и позиция локального HEAD.
tree_fingerprint() {
  {
    git_sandbox status --porcelain
    git_sandbox rev-parse HEAD
    git_sandbox stash list
    for f in tracked.txt staged.txt untracked.txt; do
      [ -f "$CLONE/$f" ] && printf '%s %s\n' "$f" "$(shasum -a 256 "$CLONE/$f" | cut -d' ' -f1)"
    done
  } 2>/dev/null
}

make_tree_dirty() {
  echo "правка живой параллельной сессии" >> "$CLONE/tracked.txt"
  echo "новый файл, ещё не закоммичен" > "$CLONE/staged.txt"
  git_sandbox add staged.txt
  echo "неотслеживаемый файл чужой сессии" > "$CLONE/untracked.txt"
}

echo "== 1. Грязное дерево переживает acquire =="
setup_sandbox
make_tree_dirty
BEFORE=$(tree_fingerprint)
RC=$(run_acquire)
AFTER=$(tree_fingerprint)

check "acquire на свободном дне вернул 0" "$RC" "0"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "рабочее дерево, индекс и HEAD не изменились"
else
  bad "дерево изменилось после acquire:"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/     /'
fi
check "новых записей в stash не появилось" "$(git_sandbox stash list | wc -l | tr -d ' ')" "0"

MARKER_SUBJECT=$(git_sandbox log origin/main -1 --format=%s 2>/dev/null)
check "метка запушена в origin" "${MARKER_SUBJECT%% by *}" "day-close-start: $(TZ=UTC date +%Y-%m-%d)"
MARKER_TREE=$(git_sandbox rev-parse "origin/main^{tree}")
PARENT_TREE=$(git_sandbox rev-parse "origin/main^^{tree}")
check "метка пустая (дерево не изменилось)" "$MARKER_TREE" "$PARENT_TREE"

echo "== 2. Свежая чужая метка останавливает второй прогон =="
check "повторный acquire вернул 3" "$(run_acquire)" "3"

echo "== 3. Уже закрытый день останавливает прогон =="
rm -rf "${SANDBOX:?}/origin.git" "$CLONE"
setup_sandbox
git_sandbox commit --quiet --allow-empty -m "day-close: $(TZ=UTC date +%Y-%m-%d)"
git_sandbox push --quiet origin HEAD:main
check "acquire на закрытом дне вернул 1" "$(run_acquire)" "1"

echo "== 4. Метка проходит pre-push хук freeze, обычный push — нет =="
rm -rf "${SANDBOX:?}/origin.git" "$CLONE"
setup_sandbox
if [ -f "$PREPUSH_HOOK" ]; then
  cp "$PREPUSH_HOOK" "$CLONE/.git/hooks/pre-push"
  chmod +x "$CLONE/.git/hooks/pre-push"
  echo "правка, которую freeze обязан не пустить" >> "$CLONE/tracked.txt"
  git_sandbox add tracked.txt
  git_sandbox commit --quiet -m "содержательный коммит"
  if ( cd "$CLONE" && IWE_FROZEN_CANONICAL_PATH="$CLONE" git push --quiet origin HEAD:main >/dev/null 2>&1 ); then
    bad "обычный push с замороженного чекаута прошёл — хук не сработал, тест ниже недоказателен"
  else
    ok "обычный push с замороженного чекаута отбит хуком"
  fi
  git_sandbox reset --quiet --hard origin/main
  RC_FROZEN=$( ( cd "$CLONE" && IWE_FROZEN_CANONICAL_PATH="$CLONE" WORKSPACE_DIR="$SANDBOX" GOVERNANCE_REPO="$GOV" \
      bash "$LOCK_SH" acquire >/dev/null 2>&1 ); echo $? )
  check "acquire под freeze вернул 0 (самоавторизация пустой метки)" "$RC_FROZEN" "0"
else
  bad "pre-push хук не найден ($PREPUSH_HOOK) — проверка freeze пропущена"
fi

echo
echo "Итого: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
