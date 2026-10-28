#!/usr/bin/env bash
# write-path-day-close-guard.sh — PreToolUse-хук (Edit|Write|MultiEdit|NotebookEdit):
# пока эта сессия владеет интерактивным закрытием дня (РП-561 Ф32), запись в
# общий каталог планов запрещена — писать можно только в изолированную копию.
# Пир-сессия 2026-10-27-24-wp561-f32-live-fail-retry (Claude+Kimi+Codex).
#
# Что защищает: ошибку агента (путь от канона вместо корня копии, символическая
# ссылка на канон). Что НЕ защищает (граница названа): хук видит аргументы
# вызова, а не открытый файл, поэтому подмена каталога между проверкой и записью
# и жёсткая ссылка остаются возможными; работает только в Claude Code, правки
# через bash, другие рантаймы и редактор идут мимо него.
#
# Чужие сессии не затрагиваются: блок только если session_id вызова равен
# DAY_CLOSE_NATIVE_SESSION_ID из файла состояния закрытия дня.
set -uo pipefail

INPUT=$(cat)
IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"
VARS="$IWE_ROOT/.iwe-runtime/day-close-interactive.vars"
[ -f "$VARS" ] || exit 0

HOOK_INPUT="$INPUT" python3 - "$VARS" "$IWE_ROOT" <<'PYEOF'
import json, os, re, sys

vars_file, iwe_root = sys.argv[1:3]
try:
    call = json.loads(os.environ.get("HOOK_INPUT", ""))
except ValueError:
    sys.exit(0)

def exported(name):
    m = re.search(r"^export (?:.* )?%s=(\S+)" % name, open(vars_file, encoding="utf-8").read(), re.M)
    return m.group(1).strip("'\"") if m else ""

owner = exported("DAY_CLOSE_NATIVE_SESSION_ID")
worktree = exported("DAY_CLOSE_WORKTREE")
if not owner or call.get("session_id") != owner:
    sys.exit(0)

ti = call.get("tool_input", {})
target = ti.get("file_path") or ti.get("notebook_path") or ""
if not target:
    sys.exit(0)
real_target = os.path.realpath(os.path.expanduser(target))

def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")

if worktree and inside(real_target, os.path.realpath(worktree)):
    sys.exit(0)
for repo in ("DS-my-strategy", "DS-strategy"):
    canon = os.path.realpath(os.path.join(iwe_root, repo))
    if os.path.isdir(canon) and inside(real_target, canon):
        sys.stderr.write(
            "STOP: идёт интерактивное закрытие дня этой сессии, запись в общий каталог планов запрещена.\n"
            "Цель: %s\nПисать только в изолированную копию: %s\n"
            "Корень копии берёт `day-close-interactive.sh --context <токен>` (правило путей записи в навыке day-close).\n"
            % (real_target, worktree or "(путь копии не прочитан из файла состояния)"))
        sys.exit(2)
sys.exit(0)
PYEOF
