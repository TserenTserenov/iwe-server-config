#!/usr/bin/env bash
# Regression for WP-484 V(b) (01.09, пир-сессия с Kimi+Codex): close's
# RUN-quick-close-*.md selection globs by SLUG only -- two sessions sharing a
# task name (or the same slug reused after the first session's card wasn't
# cleaned up) let a foreign session's completed card satisfy THIS session's
# close gate. Fix: when this session's own harness_session_id is known,
# RUNNER_CARDS is filtered to cards whose owner_session_id matches it before
# any of the RUNNER_OK-selecting branches see them.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-owner-session.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<EOF
---
date: 2026-09-01
type: work
wp: WP-484
duration_h: 0.1
artifacts: []
agent: ${2:-fixture}
---

# Fixture session

## Главный инсайт
fixture

## Контекст
fixture

## Достигнуто
fixture

## Ключевые решения
fixture
EOF
}

# --- Scenario A: foreign owner_session_id must NOT satisfy the gate --------
CLAUDE_CODE_SESSION_ID="session-A" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-a --agent fixture >/dev/null
SEM_A=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
grep -q '^harness_session_id: session-A$' "$SEM_A" || { echo "FAIL: fixture setup — harness_session_id not recorded in semaphore" >&2; exit 1; }
ORZ_BASENAME_A=$(grep '^orz_file: ' "$SEM_A" | cut -d' ' -f2-)
git -C "$REPO" add "sessions/$ORZ_BASENAME_A" 2>/dev/null || true
write_orz "$REPO/sessions/$ORZ_BASENAME_A"
git -C "$REPO" add "sessions/$ORZ_BASENAME_A"
git -C "$REPO" commit -qm "orz A"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-owner-smoke-a.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-owner-smoke-a
requested_slug: owner-smoke-a
status: completed
current_step: done
owner_session_id: session-FOREIGN
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-a.md" >> "$SEM_A"

if CLAUDE_CODE_SESSION_ID="session-A" bash "$GUARD" close --wp WP-484 --slug owner-smoke-a --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a card owned by a foreign session (session-FOREIGN != session-A)" >&2
  exit 1
else
  echo "PASS: foreign owner_session_id card does not satisfy close gate"
fi

# --- Scenario B: matching owner_session_id DOES satisfy the gate -----------
CLAUDE_CODE_SESSION_ID="session-B" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-b --agent fixture >/dev/null
SEM_B=$(grep -l '^slug: owner-smoke-b$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_B=$(grep '^orz_file: ' "$SEM_B" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_BASENAME_B"
git -C "$REPO" add "sessions/$ORZ_BASENAME_B"
git -C "$REPO" commit -qm "orz B"
git -C "$REPO" push -q origin HEAD:main

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-owner-smoke-b.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-owner-smoke-b
requested_slug: owner-smoke-b
status: completed
current_step: done
owner_session_id: session-B
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-b.md" >> "$SEM_B"

if CLAUDE_CODE_SESSION_ID="session-B" bash "$GUARD" close --wp WP-484 --slug owner-smoke-b --agent fixture; then
  echo "PASS: matching owner_session_id card satisfies close gate"
else
  echo "FAIL: close rejected a card owned by this same session (session-B)" >&2
  exit 1
fi

# --- Scenario C: card without owner_session_id (legacy) is rejected --------
# when this session's own harness_session_id IS known (narrow fail-closed
# case -- distinct from scenario D, where THIS session's own id is unknown).
CLAUDE_CODE_SESSION_ID="session-C" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-c --agent fixture >/dev/null
SEM_C=$(grep -l '^slug: owner-smoke-c$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_C=$(grep '^orz_file: ' "$SEM_C" | cut -d' ' -f2-)
write_orz "$REPO/sessions/$ORZ_BASENAME_C"
git -C "$REPO" add "sessions/$ORZ_BASENAME_C"
git -C "$REPO" commit -qm "orz C"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-owner-smoke-c.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-owner-smoke-c
requested_slug: owner-smoke-c
status: completed
current_step: done
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-c.md" >> "$SEM_C"

if CLAUDE_CODE_SESSION_ID="session-C" bash "$GUARD" close --wp WP-484 --slug owner-smoke-c --agent fixture 2>/dev/null; then
  echo "FAIL: close accepted a legacy card without owner_session_id while this session's own id was known" >&2
  exit 1
else
  echo "PASS: legacy card without owner_session_id rejected when this session's own id is known"
fi

# --- Scenario D: this session's harness_session_id is absent, so the guard's
# own runtime-neutral UUID is the exact card owner.  This is the Kimi-like
# shape: absence of a Claude harness must not weaken owner identity.
REPO2="$TEST_ROOT/DS-strategy-noharness"
mkdir -p "$REPO2/sessions" "$REPO2/inbox/agent/tasks" "$REPO2/scripts"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email test@example.com
git -C "$REPO2" config user.name "Test"
ORIGIN2="$TEST_ROOT/origin-noharness.git"
git init --bare -q "$ORIGIN2"
git -C "$REPO2" remote add origin "$ORIGIN2"
cp "$REPO/scripts/process-runner.py" "$REPO2/scripts/process-runner.py"
chmod +x "$REPO2/scripts/process-runner.py"
echo "placeholder" > "$REPO2/sessions/00-index.md"
git -C "$REPO2" add sessions/00-index.md scripts/process-runner.py
git -C "$REPO2" commit -qm init
git -C "$REPO2" push -q origin HEAD:main

unset CLAUDE_CODE_SESSION_ID
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy-noharness" bash "$GUARD" open --wp WP-484 --task fixture --slug owner-smoke-d --agent fixture >/dev/null
SEM_D=$(grep -l '^slug: owner-smoke-d$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q '^harness_session_id: ' "$SEM_D" && { echo "FAIL: fixture setup — harness_session_id unexpectedly recorded" >&2; exit 1; }
GUARD_SESSION_D=$(sed -n 's/^session_id: //p' "$SEM_D")
ORZ_BASENAME_D=$(grep '^orz_file: ' "$SEM_D" | cut -d' ' -f2-)
write_orz "$REPO2/sessions/$ORZ_BASENAME_D"
git -C "$REPO2" add "sessions/$ORZ_BASENAME_D"
git -C "$REPO2" commit -qm "orz D"
git -C "$REPO2" push -q origin HEAD:main

cat > "$REPO2/inbox/agent/tasks/RUN-quick-close-owner-smoke-d.md" <<EOF
---
process_id: quick-close
run_id: quick-close-owner-smoke-d
requested_slug: owner-smoke-d
status: completed
current_step: done
owner_session_id: $GUARD_SESSION_D
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-owner-smoke-d.md" >> "$SEM_D"

if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy-noharness" bash "$GUARD" close --wp WP-484 --slug owner-smoke-d --agent fixture; then
  echo "PASS: runtime-neutral guard UUID binds a no-harness terminal card"
else
  echo "FAIL: close rejected a no-harness card owned by the exact guard UUID" >&2
  exit 1
fi

exercise_codex_owner() {
  local slug="$1" legacy="$2" sem guard_id orz native="codex-$1"
  (
    cd "$REPO2"
    IWE_GOVERNANCE_REPO=DS-strategy-noharness IWE_AGENT=codex CODEX_THREAD_ID="$native" \
      CLAUDE_CODE_SESSION_ID=foreign-inherited-claude \
      bash "$GUARD" open --wp WP-484 --task fixture --slug "$slug" --agent codex >/dev/null
  )
  sem=$(grep -l "^slug: $slug$" "$TEST_ROOT"/.iwe-runtime/sessions/codex-*.open)
  grep -q "^harness_session_id: $native$" "$sem" || { echo "FAIL: native Codex identity not stored" >&2; exit 1; }
  guard_id=$(sed -n 's/^session_id: //p' "$sem")
  orz=$(sed -n 's/^orz_file: //p' "$sem")
  write_orz "$REPO2/sessions/$orz" codex
  git -C "$REPO2" add "sessions/$orz"
  git -C "$REPO2" commit -qm "Codex ORZ $slug"
  git -C "$REPO2" push -q origin HEAD:main
  if [ "$legacy" = true ]; then
    # Only the disposable fixture models a semaphore created before the fix.
    sed '/^harness_session_id: /d' "$sem" > "$sem.fixture"
    mv "$sem.fixture" "$sem"
    chmod 600 "$sem"
  fi
  local card="$REPO2/inbox/agent/tasks/RUN-quick-close-$slug.md"
  cat > "$card" <<EOF
---
process_id: quick-close
run_id: quick-close-$slug
requested_slug: $slug
status: completed
current_step: done
owner_session_id: foreign-owner
results:
  gather-session-facts:
    wp: WP-484
---
EOF
  echo "file: inbox/agent/tasks/RUN-quick-close-$slug.md" >> "$sem"
  if (cd "$REPO2"; IWE_GOVERNANCE_REPO=DS-strategy-noharness IWE_AGENT=codex \
      IWE_SESSION_ID="$guard_id" CODEX_THREAD_ID="$native" \
      bash "$GUARD" close --wp WP-484 --slug "$slug" --agent codex >/dev/null 2>&1); then
    echo "FAIL: Codex accepted foreign card ($slug)" >&2; exit 1
  fi
  [ -f "$sem" ] || { echo "FAIL: refused close mutated semaphore" >&2; exit 1; }
  sed "s/owner_session_id: foreign-owner/owner_session_id: $native/" "$card" > "$card.fixture"
  mv "$card.fixture" "$card"
  if [ "$legacy" = true ]; then
    if (cd "$REPO2"; IWE_GOVERNANCE_REPO=DS-strategy-noharness IWE_AGENT=codex \
        IWE_SESSION_ID=wrong-guard CODEX_THREAD_ID="$native" \
        bash "$GUARD" close --wp WP-484 --slug "$slug" --agent codex >/dev/null 2>&1); then
      echo "FAIL: legacy close accepted mismatched guard ID" >&2; exit 1
    fi
    if (cd "$REPO"; IWE_GOVERNANCE_REPO=DS-strategy-noharness IWE_AGENT=codex \
        IWE_SESSION_ID="$guard_id" CODEX_THREAD_ID="$native" \
        bash "$GUARD" close --wp WP-484 --slug "$slug" --agent codex >/dev/null 2>&1); then
      echo "FAIL: legacy close accepted wrong worktree" >&2; exit 1
    fi
  fi
  (cd "$REPO2"; IWE_GOVERNANCE_REPO=DS-strategy-noharness IWE_AGENT=codex \
    IWE_SESSION_ID="$guard_id" CODEX_THREAD_ID="$native" \
    bash "$GUARD" close --wp WP-484 --slug "$slug" --agent codex)
  [ ! -f "$sem" ] && [ -f "$sem.closed" ] || { echo "FAIL: exact Codex close not terminal" >&2; exit 1; }
  echo "PASS: exact Codex owner closes ($slug); foreign owner rejected"
}

exercise_codex_owner owner-smoke-native false
exercise_codex_owner owner-smoke-legacy true
python3 - "$GUARD" "$REPO2" "$REPO" "$TEST_ROOT" <<'PY'
from pathlib import Path
import subprocess
import sys

guard, repo, foreign, root = map(Path, sys.argv[1:])
source = guard.read_text()
start = source.index('_declared_governance_card_dir() {')
function = source[start:source.index('\n}\n', start) + 3]
worktree = root / 'governance-worktree'
subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '--detach', str(worktree)],
               check=True, capture_output=True)
alias = root / 'governance-alias'
alias.symlink_to(worktree)
for path, accepted in ((repo, True), (worktree, True), (foreign, False),
                       (alias, False), (worktree / 'scripts', False)):
    result = subprocess.run(['bash', '-c', function + '\n_declared_governance_card_dir "$1" "$2"',
                             'fixture', str(path), str(repo)], capture_output=True, text=True)
    assert (result.returncode == 0) == accepted, (path, result.stderr)
    if accepted:
        assert result.stdout.strip() == str(path / 'inbox/agent/tasks')
print('PASS: registered governance route; foreign repository, symlink and subdirectory rejected')
PY
echo "PASS: session-guard quick-close owner_session_id gate (WP-484 V(b))"
