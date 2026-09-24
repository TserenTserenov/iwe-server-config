#!/usr/bin/env bash
# scripts/sync-extensions.sh — синхронизация L3 файлов с Mac в server-extensions/
#
# Использование (на Mac):
#   bash scripts/sync-extensions.sh
#   git add server-extensions/ && git commit -m "sync: extensions" && git push
#
# Что делает:
#   ~/IWE/CLAUDE.md                                           → server-extensions/CLAUDE.md
#   ~/IWE/scripts/                                            → server-extensions/scripts/
#   ~/IWE/extensions/                                         → server-extensions/extensions/
#   ~/IWE/.claude/skills/                                     → server-extensions/claude-skills/        (все скиллы)
#   ~/IWE/.claude/hooks/                                      → server-extensions/claude-hooks/
#   ~/IWE/.claude/scripts/                                    → server-extensions/claude-scripts/
#   ~/IWE/.claude/lib/                                        → server-extensions/claude-lib/
#   memory/*.md с explicit delivery: managed + delivery_authority: root-repository
#                                                              → server-extensions/memory/ (см. classify-memory.py)
#
# После push → CD деплоит → activation script на сервере распаковывает в правильные пути.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$REPO_ROOT/server-extensions"
SOURCE_ROOT="${IWE_EXTENSIONS_SOURCE_ROOT:-$HOME/IWE}"

if [ ! -d "$SOURCE_ROOT/scripts" ]; then
    echo "ERROR: $SOURCE_ROOT/scripts не найден — источник расширений неполон" >&2
    exit 1
fi

echo "Синхронизация в $DST/..."

mkdir -p "$DST"/{scripts,extensions,claude-skills,claude-scripts,claude-hooks,claude-lib,memory}

# ROOT_COMMIT_SHA — читается iwe-extensions-sync.nix activation script для
# iwe-release.json (version-handshake, WP-484). Пишется здесь, не в Nix,
# потому что git доступен на Mac в момент staging, не на сервере в момент
# сборки (nix build sandbox не имеет сетевого доступа к .git).
git -C "$SOURCE_ROOT" rev-parse HEAD > "$DST/ROOT_COMMIT_SHA"

# Root-level CLAUDE.md (slim-ядро инструкций, нужен агенту на сервере)
if [ -f "$SOURCE_ROOT/CLAUDE.md" ]; then
    cp "$SOURCE_ROOT/CLAUDE.md" "$DST/CLAUDE.md"
fi

# WP-538 Ф8 (11.09, пир-сессия Codex+Kimi): регресс-гейт для источников,
# шлющих Telegram напрямую через curl (git-dirty-guard.sh/semaphore-watchdog.sh/
# day-open-preflight.sh) — они физически не видны рантайм-гейту допуска
# scripts/lib/telegram.sh, потому что сознательно от него не зависят (Nix-
# деплой из этого репозитория, не из DS-my-strategy). Это единственная точка,
# через которую гарантированно проходит любая правка перед попаданием на
# сервер, независимо от того, где она сделана — в ~/IWE/scripts (обычный путь)
# или руками в server-extensions/scripts (нештатный).
LINT="${SYNC_EXTENSIONS_LINT:-$HOME/IWE/DS-my-strategy/scripts/tests/telegram-raw-text-lint-smoke.sh}"
if [ ! -x "$LINT" ]; then
    echo "ERROR: $LINT не найден или не исполняем — это единственный гейт для 3 raw-curl watchdog-скриптов, синк остановлен" >&2
    exit 1
fi
echo "Проверка читаемости Telegram-текста (raw-curl источники)..."
bash "$LINT" || { echo "ERROR: сырой Telegram-текст найден — синк остановлен, см. вывод выше" >&2; exit 1; }

rsync -a --delete "$SOURCE_ROOT/scripts/"                 "$DST/scripts/"
rsync -a --delete "$SOURCE_ROOT/extensions/"              "$DST/extensions/"
# Все скиллы целиком — раньше копировался только day-open, из-за этого audit-installation
# и др. отсутствовали на сервере (SchedulerReport 6 мая «Source not found»).
rsync -a --delete "$SOURCE_ROOT/.claude/skills/"          "$DST/claude-skills/"
rsync -a --delete "$SOURCE_ROOT/.claude/hooks/"           "$DST/claude-hooks/"
rsync -a --delete "$SOURCE_ROOT/.claude/scripts/"         "$DST/claude-scripts/"
# WP-484 (24.09.2026, пир-сессия 2026-09-24-08): эта пара отсутствовала —
# server-extensions/claude-lib отставал от источника (1 файл вместо 8),
# скрипты в server-extensions/scripts ссылались на несуществующие
# .claude/lib/frontmatter.sh, iwe_event_emit.sh, behaviour-report.sh.
rsync -a --delete "$SOURCE_ROOT/.claude/lib/"              "$DST/claude-lib/"

# Memory: classify-memory.py решает, что managed (см. модуль для критерия
# и обоснования — hardcoded-список из 9 имён был тем же классом дыры, что
# 03.08 нашла для root<->FMT-шаблона: файл появился в memory/, никто не
# вспомнил добавить его в список, дальше он просто не доставлялся).
CLASSIFIER="${SYNC_EXTENSIONS_CLASSIFIER:-$REPO_ROOT/scripts/classify-memory.py}"
python3 "$CLASSIFIER"

echo ""
echo "Изменения:"
cd "$REPO_ROOT"
git -C "$REPO_ROOT" status --short server-extensions/ || true

echo ""
echo "Готово. Дальше:"
echo "  cd $REPO_ROOT"
echo "  git add server-extensions/"
echo "  git commit -m 'sync: extensions'"
echo "  git push                 # CD автоматически задеплоит на tsekh-1"
