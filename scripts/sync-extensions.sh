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
#   ~/.claude/projects/-Users-$USER-IWE/memory/{7 файлов}     → server-extensions/memory/
#
# После push → CD деплоит → activation script на сервере распаковывает в правильные пути.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$REPO_ROOT/server-extensions"
USER_NAME="$(whoami)"
MAC_MEMORY="$HOME/.claude/projects/-Users-$USER_NAME-IWE/memory"

if [ ! -d "$HOME/IWE/scripts" ]; then
    echo "ERROR: $HOME/IWE/scripts не найден — это запускается на Mac, не на сервере" >&2
    exit 1
fi

echo "Синхронизация в $DST/..."

mkdir -p "$DST"/{scripts,extensions,claude-skills,claude-scripts,claude-hooks,memory}

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

# Memory: только эти файлы (остальное — личные feedback/project, не нужны на сервере)
# t-checklist и r-questionnaire добавлены 2026-05-06: нужны Day/Week/Month Close на сервере
for f in templates-dayplan protocol-open protocol-close protocol-work MEMORY lessons_day_rituals checklists t-checklist r-questionnaire; do
    if [ -f "$MAC_MEMORY/$f.md" ]; then
        cp "$MAC_MEMORY/$f.md" "$DST/memory/"
    fi
done

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
