#!/bin/bash
# day-close-lock-no-stash-smoke.sh — регресс-тест на инцидент 05.09 (WP-484).
#
# Замок закрытия дня прятал в stash ВСЁ рабочее дерево перед `pull --rebase` и трижды подряд
# стёр незакоммиченную работу параллельных сессий. Главная проверка здесь одна: после acquire
# рабочее дерево, индекс и локальный HEAD побайтово те же, что были до вызова. Остальные
# проверки — что при этом замок продолжает делать свою работу (берёт лок, видит чужой свежий
# маркер, видит уже закрытый день) и что публикация метки проходит через pre-push хук freeze.
#
# Запуск: bash scripts/tests/day-close-lock-no-stash-smoke.sh -- требует
# .claude/lib/ рядом с этим чекаутом (day-close-lock.sh источник его
# безусловно). Здесь, в корневом ~/IWE, она настоящая; при синхронизации
# этого файла в iwe-server-config/server-extensions/ (sync-extensions.sh)
# та же папка там называется claude-lib/ без точки -- sync-extensions-auto.sh
# готовит там временный шим перед тестовым гейтом (setup_test_env(), WP-530
# 2026-09-16). Явная проверка вместо невразумительного «acquire вернул 1»
# в среде, где шим не готов (cold-review, Critical, та же сессия).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_SH="$SCRIPT_DIR/../day-close-lock.sh"
if [ ! -f "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" ]; then
  echo "SKIP: .claude/lib/ отсутствует рядом с этим чекаутом -- в iwe-server-config/server-extensions запусти через scripts/sync-extensions-auto.sh (готовит шим) или создай симлинки вручную" >&2
  exit 1
fi
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
run_acquire() {  # [agent override -- simulates a DIFFERENT session for contention scenarios]
  local agent="${1:-}"
  (
    cd "$CLONE" && export WORKSPACE_DIR="$SANDBOX" GOVERNANCE_REPO="$GOV"
    [ -n "$agent" ] && export IWE_AGENT="$agent"
    bash "$LOCK_SH" acquire >/dev/null 2>&1
  )
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
  # day-close-lock.sh (с перехода на publish-lease.sh, Ф25 06.09) читает
  # $REPO_DIR/scripts/lib/{publish-lease.sh,gateway-lock.py} обычным `source`
  # с диска, не из git-истории -- симлинки на настоящие файлы избавляют от
  # копии, которая иначе тихо разошлась бы с оригиналом при следующей правке
  # (найдено WP-530, пир-сессия 2026-09-16-15 с Kimi).
  local lib_dir="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/lib"
  mkdir -p "$CLONE/scripts/lib"
  ln -sf "$lib_dir/publish-lease.sh" "$CLONE/scripts/lib/publish-lease.sh"
  ln -sf "$lib_dir/gateway-lock.py" "$CLONE/scripts/lib/gateway-lock.py"
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

# С перехода на publish-lease.sh (Ф25, 06.09) лиза живёт на отдельном
# git-ref (refs/notes/iwe-day-close-lock), не коммитом на origin/main —
# старая проверка тут молчала на "base" (subject первого коммита песочницы)
# вместо реального содержимого лизы (найдено WP-530, пир-сессия
# 2026-09-16-15 с Kimi). Коммит лизы — orphan (без родителя, commit-tree от
# пустого дерева) на каждый acquire, поэтому "дерево не изменилось" теперь
# проверяется как "дерево лизы совпадает с пустым деревом", а не как
# "совпадает с деревом родителя" (родителя у orphan-коммита просто нет).
git_sandbox fetch --quiet origin refs/notes/iwe-day-close-lock:refs/iwe-day-close-lock-check 2>/dev/null
LEASE_REASON=$(git_sandbox log -1 --format=%B refs/iwe-day-close-lock-check 2>/dev/null | sed -n 's/^reason: //p')
check "метка запушена в лизу (refs/notes/iwe-day-close-lock)" "${LEASE_REASON%% by *}" "day-close-start: $(TZ=UTC date +%Y-%m-%d)"
LEASE_TREE=$(git_sandbox rev-parse "refs/iwe-day-close-lock-check^{tree}" 2>/dev/null)
EMPTY_TREE=$(git_sandbox hash-object -t tree /dev/null)
check "метка пустая (дерево не изменилось)" "$LEASE_TREE" "$EMPTY_TREE"

echo "== 2. Свежая чужая метка останавливает второй прогон =="
# publish_lease_acquire намеренно разрешает тому же owner (agent@host)
# перезахватить свою же лизу (renewal, не contention) — второй вызов из
# ТОГО ЖЕ процесса под тем же IWE_AGENT раньше "проходил" только потому,
# что старый branch-marker механизм не различал владельцев вообще, любой
# существующий коммит-маркер блокировал безусловно (найдено той же сессией).
# Чтобы реально проверить отказ чужому агенту, второй вызов должен НЕСТИ
# другого owner — иначе это не contention-сценарий, а renewal.
check "повторный acquire вернул 3" "$(run_acquire other-session)" "3"

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
