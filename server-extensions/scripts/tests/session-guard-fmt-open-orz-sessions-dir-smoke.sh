#!/usr/bin/env bash
# Regression for WP-484 (16.09, peer-session 2026-09-16-18, Claude+Kimi):
# the FMT-copy point-patch from 15.09 (PR #829) taught open() to write
# governance_worktree but not orz_sessions_dir. That made a semaphore this
# copy wrote "partially modern" for the canonical close's
# _repo_scope_has_publish_proof(): governance_worktree present makes
# structurally_legacy false, but orz_sessions_dir is still absent, so the
# sessions-repo lookup inside that same scoped check (other_repos, used to
# resolve this session's own ORZ file, which always lives in a SEPARATE
# sessions repo) can never find it -- close refused the session's own ORZ
# file as "путь отсутствует или неоднозначен между репозиториями" whenever
# the GOVERNANCE checkout had diverged from origin/main (the routine case
# under parallel sessions, which is when the plain ancestry check fails and
# this scoped fallback is what gets asked to rescue it). Fix: FMT open() now
# also writes orz_sessions_dir, reusing the same $ORZ_DIR already resolved
# for the ORZ file path itself.
#
# Scope note: this smoke test exercises the GOVERNANCE-repo divergence path
# (session-guard.sh:6337, _repo_head_has_publish_proof "governance checkout"
# ... "$SEM_FILE" ...) -- the one call site that actually wires up
# _repo_scope_has_publish_proof and is what this patch affects.  A SEPARATE,
# earlier gate for the sessions checkout itself
# (session-guard.sh:6134-6140, _repo_head_has_publish_proof "sessions
# checkout" with NO third argument, so no scoped-fallback at all) has no
# rescue path and was NOT touched by this patch -- found live while writing
# this fixture (see peer-session 03-peer.md for the follow-up with Kimi).
# Diverging MC-sessions itself here would exercise that other, unrelated gate
# and produce a different failure message than the one this patch fixes.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
FMT_OPEN="${FMT_SESSION_GUARD:-}"
if [ -z "$FMT_OPEN" ] || [ ! -f "$FMT_OPEN" ]; then
  echo "SKIP: FMT_SESSION_GUARD не задан или файл не найден -- укажи путь к патченной FMT-копии session-guard.sh" >&2
  exit 0
fi
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-fmt-orz-sessions-dir.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

setup_repo() {
  local repo="$1" origin="$2"
  mkdir -p "$repo"
  git init --bare -q "$origin"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Test"
  git -C "$repo" remote add origin "$origin"
}

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<'EOF'
---
date: 2026-09-16
type: work
wp: WP-484
duration_h: 0.1
artifacts: []
agent: fixture
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

# Diverge the GOVERNANCE repo the same way
# session-guard-close-legacy-no-governance-fields-smoke.sh Scenario D does:
# an outside push lands unrelated history on origin, our own change is
# committed on the OLD base (never fast-forwarded), and a separate republish
# clone lands the SAME content under a fresh SHA (the isolate-push shape) --
# not a trivial "local is behind", which the plain ancestry check would pass
# on its own without ever reaching the scoped fallback.
diverge_governance_after_own_commit() {
  local repo="$1" own_sha_var="$2" file1="$3" file2="$4" origin outside republish

  origin=$(git -C "$repo" remote get-url origin)
  outside="$TEST_ROOT/$(basename "$repo")-outside"
  git clone -q "$origin" "$outside"
  git -C "$outside" config user.email outside@test
  git -C "$outside" config user.name outside
  echo "unrelated parallel-session work" > "$outside/UNRELATED.md"
  git -C "$outside" add UNRELATED.md
  git -C "$outside" commit -qm "unrelated parallel-session commit"
  git -C "$outside" push -q origin HEAD:main

  if git -C "$repo" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "FAIL: fixture setup -- local HEAD всё ещё ancestor старого origin/main (before outside push) -- проверка бессмысленна" >&2
    exit 1
  fi

  republish="$TEST_ROOT/$(basename "$repo")-republish"
  git clone -q "$origin" "$republish"
  git -C "$republish" config user.email republish@test
  git -C "$republish" config user.name republish
  mkdir -p "$republish/$(dirname "$file1")" "$republish/$(dirname "$file2")"
  cp "$repo/$file1" "$republish/$file1"
  cp "$repo/$file2" "$republish/$file2"
  git -C "$republish" add "$file1" "$file2"
  git -C "$republish" commit -qm "same content, republished onto fresh origin/main under a new SHA"
  git -C "$republish" push -q origin HEAD:main

  git -C "$repo" fetch -q origin
  if git -C "$repo" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "FAIL: fixture setup -- local HEAD оказался ancestor origin/main после republish -- divergence не достигнута" >&2
    exit 1
  fi
  eval "$own_sha_var=\$(git -C \"\$repo\" rev-parse HEAD)"
}

strip_orz_sessions_dir() {
  local sem="$1"
  grep -v '^orz_sessions_dir: ' "$sem" > "$sem.stripped"
  mv "$sem.stripped" "$sem"
}

run_close() {
  local label="$1" iwe_root="$2" repo="$3" sessions="$4" slug="$5" own_sha="$6"
  cat > "$repo/inbox/agent/tasks/RUN-quick-close-$slug.md" <<EOF
---
process_id: quick-close
run_id: quick-close-$slug
requested_slug: $slug
status: completed
current_step: done
owner_session_id: session-$slug
results:
  gather-session-facts:
    wp: WP-484
---
EOF
  local sem
  sem=$(grep -l "^slug: $slug\$" "$iwe_root"/.iwe-runtime/sessions/fixture-*.open)
  {
    echo "file: inbox/agent/tasks/RUN-quick-close-$slug.md"
    echo "commit: $(basename "$repo") $own_sha"
  } >> "$sem"

  local close_out
  if close_out=$(CLAUDE_CODE_SESSION_ID="session-$slug" bash "$GUARD" close --wp WP-484 --slug "$slug" --agent fixture 2>&1); then
    echo "PASS [$label]: close прошёл" && return 0
  else
    echo "$close_out"
    return 1
  fi
}

# --- Общая почва: sessions-репо НЕ расходится (вне scope этого патча,
# см. комментарий в шапке файла) -- только governance-репо.
IWE_ROOT="$TEST_ROOT/iwe"
REPO="$IWE_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
setup_repo "$REPO" "$ORIGIN"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

SESSIONS="$IWE_ROOT/MC-sessions"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
setup_repo "$SESSIONS" "$SESSIONS_ORIGIN"
echo seed > "$SESSIONS/README.md"
git -C "$SESSIONS" add README.md
git -C "$SESSIONS" commit -qm init
git -C "$SESSIONS" push -q origin HEAD:main

export IWE_ROOT
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

# --- Scenario 1 (fix works): open() через патченную FMT-копию, governance-
# репо расходится с origin -- close обязан пройти через scoped-фолбэк
# благодаря добавленному полю orz_sessions_dir (сессионный ORZ-файл лежит в
# ОТДЕЛЬНОМ sessions-репо, и без этого поля тот же фолбэк не находит его).
CLAUDE_CODE_SESSION_ID="session-fixed" bash "$FMT_OPEN" open --wp WP-484 --task fixture --slug fmt-fixed --agent fixture >/dev/null
SEM_1=$(grep -l '^slug: fmt-fixed$' "$IWE_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q "^orz_sessions_dir: $SESSIONS\$" "$SEM_1" \
  || { echo "FAIL [fixed]: семафор не содержит ожидаемого orz_sessions_dir: $SESSIONS" >&2; cat "$SEM_1" >&2; exit 1; }
echo "PASS [fixed]: open() через патченную FMT-копию записал корректный orz_sessions_dir"

ORZ_BASENAME_1=$(grep '^orz_file: ' "$SEM_1" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_1"
git -C "$SESSIONS" add "$ORZ_BASENAME_1"
git -C "$SESSIONS" commit -qm "orz fmt-fixed"
git -C "$SESSIONS" push -q origin HEAD:main

echo "owned result" > "$REPO/owned-fmt-fixed.txt"
git -C "$REPO" add owned-fmt-fixed.txt
git -C "$REPO" commit -qm "own change, not yet fast-forwarded onto foreign history"
diverge_governance_after_own_commit "$REPO" OWN_SHA_1 "owned-fmt-fixed.txt" "owned-fmt-fixed.txt"

if OUT_1=$(run_close "fixed" "$IWE_ROOT" "$REPO" "$SESSIONS" "fmt-fixed" "$OWN_SHA_1"); then
  echo "$OUT_1"
else
  echo "FAIL [fixed]: close отказал: $OUT_1" >&2
  exit 1
fi

# --- Scenario 2 (regression, must stay caught): orz_sessions_dir вручную
# вырезан из семафора сразу после open() -- симулирует ДОпатченную FMT-копию.
# На том же самом расхождении close обязан ПО-ПРЕЖНЕМУ отказать, иначе
# сценарий 1 ничего не доказывает.
CLAUDE_CODE_SESSION_ID="session-nopatch" bash "$FMT_OPEN" open --wp WP-484 --task fixture --slug fmt-nopatch --agent fixture >/dev/null
SEM_2=$(grep -l '^slug: fmt-nopatch$' "$IWE_ROOT"/.iwe-runtime/sessions/fixture-*.open)
strip_orz_sessions_dir "$SEM_2"
grep -q '^orz_sessions_dir: ' "$SEM_2" \
  && { echo "FAIL: fixture setup -- orz_sessions_dir всё ещё в семафоре после вырезания" >&2; exit 1; }

ORZ_BASENAME_2=$(grep '^orz_file: ' "$SEM_2" | cut -d' ' -f2-)
write_orz "$SESSIONS/$ORZ_BASENAME_2"
git -C "$SESSIONS" add "$ORZ_BASENAME_2"
git -C "$SESSIONS" commit -qm "orz fmt-nopatch"
git -C "$SESSIONS" push -q origin HEAD:main

echo "owned result" > "$REPO/owned-fmt-nopatch.txt"
git -C "$REPO" add owned-fmt-nopatch.txt
git -C "$REPO" commit -qm "own change, not yet fast-forwarded onto foreign history"
diverge_governance_after_own_commit "$REPO" OWN_SHA_2 "owned-fmt-nopatch.txt" "owned-fmt-nopatch.txt"

if OUT_2=$(run_close "no-patch regression" "$IWE_ROOT" "$REPO" "$SESSIONS" "fmt-nopatch" "$OWN_SHA_2"); then
  echo "FAIL: без orz_sessions_dir close на разошедшемся governance-репо ПРОШЁЛ -- сценарий не воспроизводит баг, тест ничего не доказывает" >&2
  exit 1
else
  if grep -q 'неоднозначен между репозиториями' <<<"$OUT_2"; then
    echo "PASS [no-patch regression]: без orz_sessions_dir close по-прежнему отказывает ровно так, как в живом инциденте -- патч действительно нужен"
  else
    echo "FAIL: close без orz_sessions_dir отказал по другой причине (фикстура могла устареть): $OUT_2" >&2
    exit 1
  fi
fi

# --- Scenario 3: немигрированная установка (MC-sessions не существует вовсе).
# Здесь sessions-репо = governance-репо, содержательная проверка --
# resolve_orz_sessions_dir() легаси-ветка резолвится, обычный open/close
# (без расхождения) проходит.
IWE_ROOT_3="$TEST_ROOT/scenario-legacy"
REPO_3="$IWE_ROOT_3/DS-strategy"
ORIGIN_3="$TEST_ROOT/scenario-legacy-origin.git"
setup_repo "$REPO_3" "$ORIGIN_3"
mkdir -p "$REPO_3/inbox/agent/tasks" "$REPO_3/scripts"
cp "$REPO/scripts/process-runner.py" "$REPO_3/scripts/process-runner.py"
git -C "$REPO_3" add scripts/process-runner.py
git -C "$REPO_3" commit -qm init
git -C "$REPO_3" push -q origin HEAD:main

export IWE_ROOT="$IWE_ROOT_3"
CLAUDE_CODE_SESSION_ID="session-legacy" bash "$FMT_OPEN" open --wp WP-484 --task fixture --slug fmt-legacy --agent fixture >/dev/null
SEM_3=$(grep -l '^slug: fmt-legacy$' "$IWE_ROOT_3"/.iwe-runtime/sessions/fixture-*.open)
grep -q "^orz_sessions_dir: $REPO_3/sessions\$" "$SEM_3" \
  || { echo "FAIL [legacy]: ожидал orz_sessions_dir: $REPO_3/sessions, получил:" >&2; cat "$SEM_3" >&2; exit 1; }
echo "PASS [legacy]: немигрированная установка -- orz_sessions_dir резолвится в legacy-путь \$GOV_REPO/sessions"

ORZ_BASENAME_3=$(grep '^orz_file: ' "$SEM_3" | cut -d' ' -f2-)
write_orz "$REPO_3/sessions/$ORZ_BASENAME_3"
git -C "$REPO_3" add "sessions/$ORZ_BASENAME_3"
git -C "$REPO_3" commit -qm "orz fmt-legacy"
git -C "$REPO_3" push -q origin HEAD:main

cat > "$REPO_3/inbox/agent/tasks/RUN-quick-close-fmt-legacy.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-fmt-legacy
requested_slug: fmt-legacy
status: completed
current_step: done
owner_session_id: session-legacy
results:
  gather-session-facts:
    wp: WP-484
---
EOF
echo "file: inbox/agent/tasks/RUN-quick-close-fmt-legacy.md" >> "$SEM_3"

if CLOSE_OUT_3=$(CLAUDE_CODE_SESSION_ID="session-legacy" bash "$GUARD" close --wp WP-484 --slug fmt-legacy --agent fixture 2>&1); then
  echo "PASS [legacy]: обычное закрытие (без расхождения) на немигрированной установке проходит"
else
  echo "FAIL [legacy]: close отказал: $CLOSE_OUT_3" >&2
  exit 1
fi

echo "ALL PASS: 3/3 сценария (fixed + no-patch-regression + legacy-unmigrated)"
