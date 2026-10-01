#!/usr/bin/env bash
# runtime-env-split-readers-smoke.sh -- WP-530 Ф75, step 2 (01.10.2026, peer-session 2026-10-01-11-wp530-f75-runtime-env-split).
# Remaining root-repo readers of the runtime directory after step 1 (see runtime-env-split-smoke.sh for the contract:
# IWE_RUNTIME is the HOST NAME, the runtime DIRECTORY is IWE_RUNTIME_DIR):
#   - scripts/wp-archive-closed-phases.py   resolve_runtime_dir(): lock and journal directory of the archiver
#                                          (A1-A4 the function, A5 the command line: the directory --apply really uses)
#   - .claude/skills/*/SKILL.md             no snippet may build a path from "${IWE_RUNTIME:-...}" (static check)
#   - bootstrap -> canon-reconcile-published.sh   integration: both read the same runtime directory
# Usage: runtime-env-split-readers-smoke.sh [<repo-root>]   (default: the repository that contains this file)
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
ARCHIVER="$ROOT/scripts/wp-archive-closed-phases.py"
[ -f "$ARCHIVER" ] || { echo "FAIL: $ARCHIVER not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is required" >&2; exit 0; }
T=$(mktemp -d "$(printf '%s' "${TMPDIR:-/tmp}" | sed 's#/*$##')/runtime-env-split-readers.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/legacy-rt"
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

resolve() {  # <runtime-dir-arg|-> <env assignments...> -> the directory the archiver would use for its lock and journal
  local arg="$1"; shift
  [ "$arg" = "-" ] && arg=""
  env -i PATH="$PATH" "$@" python3 - "$ARCHIVER" "$arg" "/ws" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("wp_archive", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.resolve_runtime_dir(sys.argv[2] or None, os.environ, sys.argv[3]), end="")
PY
}

echo "scenario A1: IWE_RUNTIME=claude-code (host name) is never taken for a directory"
assert "$(resolve - IWE_RUNTIME=claude-code)" "/ws/.iwe-runtime" "falls back to <workspace>/.iwe-runtime"

echo "scenario A2: IWE_RUNTIME_DIR wins over the host name, over a legacy absolute directory and over the default"
assert "$(resolve - IWE_RUNTIME=claude-code IWE_RUNTIME_DIR=/d)" "/d" "IWE_RUNTIME_DIR used"
assert "$(resolve - IWE_RUNTIME="$T/legacy-rt" IWE_RUNTIME_DIR=/d)" "/d" "IWE_RUNTIME_DIR beats an existing legacy absolute IWE_RUNTIME"

echo "scenario A3: a legacy ABSOLUTE IWE_RUNTIME that is an existing directory is still accepted"
assert "$(resolve - IWE_RUNTIME="$T/legacy-rt")" "$T/legacy-rt" "legacy directory used"
assert "$(resolve - IWE_RUNTIME=/nonexistent/abs)" "/ws/.iwe-runtime" "an absolute path that is not a directory is not used"

echo "scenario A4: the explicit --runtime-dir argument wins over everything"
assert "$(resolve /arg IWE_RUNTIME_DIR=/d IWE_RUNTIME=claude-code)" "/arg" "argument used"

echo "scenario A5 (command line): --apply writes its recovery journal into the resolved directory, never into claude-code/ under the working directory"
# a minimal governance directory: one card with two closed phases to archive (the last two phase sections stay) and a guard that always allows
make_gov() {  # <governance dir>
  mkdir -p "$1/inbox/WP-9301" "$1/scripts"
  printf '#!/usr/bin/env bash\necho %s\nexit 0\n' "'{\"guard_version\":\"2.2\",\"verdict\":\"allow\",\"rules_triggered\":[],\"evidence\":[],\"incoming_links\":[]}'" > "$1/scripts/archive-section-guard.sh"
  cat > "$1/inbox/WP-9301/WP-9301.md" <<'C'
---
wp: 9301
title: "Fixture"
status: in_progress
created: 2026-08-01
phases:
  Ф1: done
  Ф2: done
  Ф3: done
  Ф4: in_progress
---
# WP-9301

## Ф1 ✅ closed
Body one.

## Ф2 ✅ closed
Body two.

## Ф3 ✅ closed
Body three.

## Ф4 open
Body four.

## Осталось

**Что пробовали:** x
**Что узнали:** y
**Что дальше:**
- [ ] finish Ф4
**Следующий шаг:** Ф4 → довести
**Контекст для следующей сессии:** z
**Заблокировано:** нет
**Зависит от:** нет
**Актуально до:** н/п

## Журнал

- 2026-08-01: создана
C
}
cli_run() {  # <name> <env assignments...> -> "<exit code> <labels of the directories that received a journal>"
  local name="$1"; shift
  local base="$T/cli-$name" rc out="" d
  mkdir -p "$base/cwd" "$base/ws" "$base/legacy"; make_gov "$base/gov"
  ( cd "$base/cwd" && env -i PATH="$PATH" HOME="$T/home" IWE_WORKSPACE="$base/ws" "$@" python3 "$ARCHIVER" 9301 --governance-repo "$base/gov" --apply --lock-wait 1 >"$base/out" 2>&1 )
  rc=$?
  for d in ws/.iwe-runtime cwd/claude-code rtd legacy; do [ -d "$base/$d/wp-archive-journal" ] && out="$out${out:+,}$d"; done
  printf '%s %s' "$rc" "$out"
}
mkdir -p "$T/home"
# each run gets its own base directory $T/cli-<name>; the directory values in the environment point into it
assert "$(cli_run a IWE_RUNTIME=claude-code)" "0 ws/.iwe-runtime" "host name only: journal under <workspace>/.iwe-runtime, nothing under claude-code/"
assert "$(cli_run b IWE_RUNTIME=claude-code IWE_RUNTIME_DIR="$T/cli-b/rtd")" "0 rtd" "IWE_RUNTIME_DIR: journal under that directory"
assert "$(cli_run c IWE_RUNTIME="$T/cli-c/legacy")" "0 legacy" "legacy absolute IWE_RUNTIME: journal under that directory"

echo "scenario K1 (static): no skill snippet builds a path from \${IWE_RUNTIME:-...}"
bad=$(grep -rl '\${IWE_RUNTIME:-' "$ROOT/.claude/skills" 2>/dev/null | wc -l | tr -d ' ')
assert "$bad" "0" "no SKILL.md reads the host name as a directory"

BOOT="$ROOT/.claude/lib/iwe-env-bootstrap.sh"; GUARD="$ROOT/scripts/canon-reconcile-published.sh"
if [ -f "$BOOT" ] && [ -f "$GUARD" ]; then
  git_ok() { command -v git >/dev/null 2>&1; }
  git_ok || { echo "SKIP: git is required for the integration scenarios" >&2; }
  # a throwaway repository without origin: the guard refuses early ("git fetch origin main failed") but writes its log into the runtime directory it resolved
  run_chain() {  # <workspace> <repo> <env assignments...>
    local ws="$1" repo="$2"; shift 2
    env -i HOME="$T/home" PATH="$PATH" WORKSPACE_DIR="$ws" "$@" bash -c 'source "'"$BOOT"'" >/dev/null 2>&1; cd "'"$T"'" && bash "'"$GUARD"'" "'"$repo"'" main' >/dev/null 2>&1
  }
  mkdir -p "$T/home"

  echo "scenario I1: legacy ABSOLUTE IWE_RUNTIME -> bootstrap -> guard: the guard logs into that same directory"
  git init -q -b main "$T/repo-i1"; mkdir -p "$T/legacy-i1" "$T/ws-i1"
  run_chain "$T/ws-i1" "$T/repo-i1" IWE_RUNTIME="$T/legacy-i1"
  assert "$([ -f "$T/legacy-i1/canon-reconcile-published.log" ] && echo legacy-dir || echo missing)" "legacy-dir" "log written into the legacy directory"
  assert "$([ -e "$T/ws-i1/.iwe-runtime/canon-reconcile-published.log" ] && echo default-dir || echo none)" "none" "nothing written into the workspace default directory"

  echo "scenario I2: IWE_RUNTIME=claude-code (settings.json) -> bootstrap -> guard: log in the workspace runtime directory, nothing inside the repository"
  git init -q -b main "$T/repo-i2"; mkdir -p "$T/ws-i2"
  run_chain "$T/ws-i2" "$T/repo-i2" IWE_RUNTIME=claude-code
  assert "$([ -f "$T/ws-i2/.iwe-runtime/canon-reconcile-published.log" ] && echo default-dir || echo missing)" "default-dir" "log written into <workspace>/.iwe-runtime"
  assert "$([ -e "$T/repo-i2/claude-code" ] && echo inside-repo || echo clean)" "clean" "no claude-code/ directory appeared inside the repository"
else
  echo "scenario I*: skipped (no bootstrap or guard under $ROOT)"
fi

[ "$fails" -eq 0 ] && { echo "PASS: all scenarios"; exit 0; } || { echo "FAIL: $fails assertion(s)"; exit 1; }
