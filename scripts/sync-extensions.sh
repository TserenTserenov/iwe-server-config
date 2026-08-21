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
#   memory/*.md с explicit delivery: managed + delivery_authority: root-repository
#                                                              → server-extensions/memory/ (см. classify-memory.py)
#
# После push → CD деплоит → activation script на сервере распаковывает в правильные пути.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$REPO_ROOT/server-extensions"

if [ ! -d "$HOME/IWE/scripts" ]; then
    echo "ERROR: $HOME/IWE/scripts не найден — это запускается на Mac, не на сервере" >&2
    exit 1
fi

echo "Синхронизация в $DST/..."

mkdir -p "$DST"/{scripts,extensions,claude-skills,claude-scripts,claude-hooks,memory}

# ROOT_COMMIT_SHA — читается iwe-extensions-sync.nix activation script для
# iwe-release.json (version-handshake, WP-484). Пишется здесь, не в Nix,
# потому что git доступен на Mac в момент staging, не на сервере в момент
# сборки (nix build sandbox не имеет сетевого доступа к .git).
git -C "$HOME/IWE" rev-parse HEAD > "$DST/ROOT_COMMIT_SHA"

# Root-level CLAUDE.md (slim-ядро инструкций, нужен агенту на сервере)
if [ -f "$HOME/IWE/CLAUDE.md" ]; then
    cp "$HOME/IWE/CLAUDE.md" "$DST/CLAUDE.md"
fi

rsync -a --delete "$HOME/IWE/scripts/"                    "$DST/scripts/"
rsync -a --delete "$HOME/IWE/extensions/"                 "$DST/extensions/"
# Все скиллы целиком — раньше копировался только day-open, из-за этого audit-installation
# и др. отсутствовали на сервере (SchedulerReport 6 мая «Source not found»).
rsync -a --delete "$HOME/IWE/.claude/skills/"             "$DST/claude-skills/"
rsync -a --delete "$HOME/IWE/.claude/hooks/"              "$DST/claude-hooks/"
rsync -a --delete "$HOME/IWE/.claude/scripts/"            "$DST/claude-scripts/"

# Memory: classify-memory.py решает, что managed (см. модуль для критерия
# и обоснования — hardcoded-список из 9 имён был тем же классом дыры, что
# 03.08 нашла для root<->FMT-шаблона: файл появился в memory/, никто не
# вспомнил добавить его в список, дальше он просто не доставлялся).
python3 "$REPO_ROOT/scripts/classify-memory.py"

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
