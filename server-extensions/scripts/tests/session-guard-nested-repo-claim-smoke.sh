#!/usr/bin/env bash
# session-guard-nested-repo-claim-smoke.sh -- regression suite for repo-name
# resolution of `commit:` claims (WP-537, peer session 2026-09-19-09
# with Kimi+Codex).
#
# The defect: the WRITER recorded a name the READER could not resolve.
# `note-commit` stores `basename` of the checkout it was called from, while
# both it and `_claimed_commits_have_publish_proof` looked only under
# "$IWE_ROOT/<name>". A checkout that does not sit directly under the root --
# DS-MCP/mentorship-service, DS-IT-systems/neon-migrations -- was accepted
# when written and then refused at close with "claimed commit не читается",
# for a commit that was in fact delivered.
#
# Both halves are covered here, at the level where each is observable:
#   * the writer through the real CLI (`note-commit`), which is where the
#     unresolvable name was minted;
#   * the reader at `_resolve_repo_checkout`, the function its claim loop now
#     delegates to. The loop itself is reachable only from deep inside
#     `close` (scripts/session-guard.sh:6444, :6619), behind ORZ scaffolding
#     and a delivery transition; driving all of that would test the close
#     pipeline, not this resolution rule. The resolver is extracted and
#     evaluated by name -- if it is ever renamed this suite fails loudly,
#     which is the intended signal, not a silent pass.
#
# Everything runs against a throwaway $IWE_ROOT under $TMPDIR; the real
# checkout is never touched.
#
# Запуск: bash scripts/tests/session-guard-nested-repo-claim-smoke.sh
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SG="${IWE_SESSION_GUARD:-$ROOT_DIR/scripts/session-guard.sh}"
[ -x "$SG" ] || { echo "FAIL: session-guard.sh не найден: $SG"; exit 1; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

SANDBOX=$(mktemp -d)
trap 'cd / ; rm -rf "$SANDBOX"' EXIT

IWE_ROOT="$SANDBOX/IWE"
mkdir -p "$IWE_ROOT"
export IWE_ROOT
export IWE_GOVERNANCE_REPO=DS-strategy

init_repo() {  # init_repo <dir> [origin url] -- one-commit repo, prints its sha
  local dir="$1" origin="${2:-}"
  mkdir -p "$dir"
  git init --initial-branch=main "$dir" >/dev/null
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
  echo "seed" > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -m "seed" >/dev/null
  git -C "$dir" rev-parse HEAD
}

add_commit() {  # add_commit <dir> <marker> -- prints the new sha
  local dir="$1" marker="$2"
  echo "$marker" > "$dir/$marker.txt"
  git -C "$dir" add "$marker.txt"
  git -C "$dir" commit -m "$marker" >/dev/null
  git -C "$dir" rev-parse HEAD
}

init_repo "$IWE_ROOT" >/dev/null
GOV_DIR="$IWE_ROOT/DS-strategy"
GOV_SHA=$(init_repo "$GOV_DIR")

# The repo this defect was found on: a checkout one level below the root.
NESTED_DIR="$IWE_ROOT/DS-MCP/mentorship-service"
NESTED_SHA=$(init_repo "$NESTED_DIR")

# A plain (non-repo) directory inside the root, to prove the resolver demands
# a real checkout root and not merely an existing path.
mkdir -p "$IWE_ROOT/DS-MCP/not-a-repo"

# Two checkouts, DIFFERENT origins: a genuine collision of two repositories
# that happen to share a directory name. Must refuse.
init_repo "$IWE_ROOT/DS-ai-systems" "https://example.invalid/a/DS-ai-systems.git" >/dev/null
init_repo "$IWE_ROOT/DS-IT-systems/DS-ai-systems" "https://example.invalid/b/DS-ai-systems.git" >/dev/null

# Two checkouts, SAME origin: one repository in two copies, which is what all
# three duplicated names in the real installation actually are. Must resolve,
# and must pick the copy that holds the claimed commit.
DUP_ORIGIN="https://example.invalid/shared/neon-migrations.git"
init_repo "$IWE_ROOT/neon-migrations" "$DUP_ORIGIN" >/dev/null
DUP_NESTED="$IWE_ROOT/DS-IT-systems/neon-migrations"
init_repo "$DUP_NESTED" "$DUP_ORIGIN" >/dev/null
DUP_ONLY_NESTED_SHA=$(add_commit "$DUP_NESTED" "only-in-nested")

# One checkout with an origin, one without: identity of the second is unknown,
# and unknown is never evidence of sameness. Must refuse.
init_repo "$IWE_ROOT/half-origin" "https://example.invalid/x/half-origin.git" >/dev/null
init_repo "$IWE_ROOT/DS-IT-systems/half-origin" >/dev/null

# Two checkouts with DIFFERENT origins where the claimed commit exists in
# exactly one. Identity is decided before the commit is consulted, so this
# must still refuse -- otherwise a SHA would silently pick a winner between
# two genuinely different repositories.
init_repo "$IWE_ROOT/split-brain" "https://example.invalid/a/split-brain.git" >/dev/null
SPLIT_NESTED="$IWE_ROOT/DS-IT-systems/split-brain"
init_repo "$SPLIT_NESTED" "https://example.invalid/b/split-brain.git" >/dev/null
SPLIT_ONLY_NESTED_SHA=$(add_commit "$SPLIT_NESTED" "only-in-b")

# Two checkouts, NEITHER with an origin: two unknowns are not one repository.
init_repo "$IWE_ROOT/both-anonymous" >/dev/null
init_repo "$IWE_ROOT/DS-IT-systems/both-anonymous" >/dev/null

# A lone checkout with no origin at all: resolvable (the reader refuses it
# later, on its own "no origin" rule, which is a different and clearer error).
init_repo "$IWE_ROOT/no-origin-repo" >/dev/null

# The same checkout reachable through two containers -- the live `memory`
# shape. One repository seen twice must not read as two candidates.
DEDUPE_DIR="$IWE_ROOT/dedupe-me"
init_repo "$DEDUPE_DIR" "https://example.invalid/x/dedupe-me.git" >/dev/null
mkdir -p "$IWE_ROOT/DS-MCP"
ln -s "$DEDUPE_DIR" "$IWE_ROOT/DS-MCP/dedupe-me"

# One origin, two spellings, and one copy shallow. Covers three things at
# once: normalize_remote_url makes "file://X" and "X" the same identity; a
# shallow copy can hold the object yet fail the ancestry proof; the shallow
# one is deliberately FIRST in container order, so picking the full clone can
# only happen by the preference rule and not by luck of iteration.
DEPTH_ORIGIN="$SANDBOX/depth-origin.git"
git init --bare -q --initial-branch=main "$DEPTH_ORIGIN"
init_repo "$SANDBOX/depth-src" >/dev/null
DEPTH_TIP_SHA=$(add_commit "$SANDBOX/depth-src" "tip")
git -C "$SANDBOX/depth-src" push -q "$DEPTH_ORIGIN" main
git clone -q --depth 1 "file://$DEPTH_ORIGIN" "$IWE_ROOT/depth-test" 2>/dev/null
DEPTH_FULL="$IWE_ROOT/DS-IT-systems/depth-test"
git clone -q "$DEPTH_ORIGIN" "$DEPTH_FULL" 2>/dev/null

# A symlink whose own name differs from its target's basename. The claim must
# be recorded under the name the caller asked for, not the target's basename
# (Codex cold review 19.09) -- otherwise the reader looks for another name.
EXTERNAL_DIR="$SANDBOX/external/service-checkout"
EXTERNAL_SHA=$(init_repo "$EXTERNAL_DIR" "https://example.invalid/x/service.git")
ln -s "$EXTERNAL_DIR" "$IWE_ROOT/service"

# === writer: the real CLI ===

export IWE_SESSION_ID="nested-repo-claim"
export IWE_FROZEN_CANONICAL_PATH=""
cd "$GOV_DIR" || exit 1
IWE_AGENT=claude-code "$SG" open --wp WP-999 --task t --slug nested-repo-claim \
  --agent claude-code >/dev/null 2>&1 \
  || { echo "FAIL: подготовка — open не создал семафор"; exit 1; }
SEM_FILE="$IWE_ROOT/.iwe-runtime/sessions/claude-code-nested-repo-claim.open"
[ -f "$SEM_FILE" ] || { echo "FAIL: подготовка — семафор не найден: $SEM_FILE"; exit 1; }

note_commit() {  # note_commit <sha> [--repo <name>]
  NC_RC=0
  NC_OUT=$(IWE_AGENT=claude-code "$SG" note-commit "$@" --slug nested-repo-claim 2>&1) || NC_RC=$?
}

note_commit "$NESTED_SHA" --repo mentorship-service
if [ "$NC_RC" -eq 0 ] && grep -qxF "commit: mentorship-service $NESTED_SHA" "$SEM_FILE"; then
  pass "--repo <вложенный репозиторий> принят и записан под своим basename"
else
  fail "--repo mentorship-service отклонён (exit $NC_RC): $NC_OUT"
fi

cd "$NESTED_DIR" || exit 1
note_commit "$NESTED_SHA"
if [ "$NC_RC" -eq 0 ] && [ "$(grep -cxF "commit: mentorship-service $NESTED_SHA" "$SEM_FILE")" -eq 1 ]; then
  pass "вызов из каталога вложенного репозитория даёт то же имя, без дубля строки"
else
  fail "вызов без --repo из вложенного репозитория записал другое имя: $(grep '^commit: ' "$SEM_FILE" | tr '\n' ' ')"
fi
cd "$GOV_DIR" || exit 1

note_commit "$GOV_SHA" --repo DS-strategy
if [ "$NC_RC" -eq 0 ] && grep -qxF "commit: DS-strategy $GOV_SHA" "$SEM_FILE"; then
  pass "прямой потомок корня заявляется как прежде (регрессии нет)"
else
  fail "заявка обычного репозитория сломана (exit $NC_RC): $NC_OUT"
fi

note_commit "$GOV_SHA" --repo DS-ai-systems
if [ "$NC_RC" -ne 0 ] && printf '%s' "$NC_OUT" | grep -q 'РАЗНЫМИ origin'; then
  pass "два репозитория с разными origin под одним именем отклонены как коллизия"
else
  fail "коллизия разных origin не отклонена или отклонена не тем сообщением (exit $NC_RC): $NC_OUT"
fi

note_commit "$DUP_ONLY_NESTED_SHA" --repo neon-migrations
if [ "$NC_RC" -eq 0 ] && grep -qxF "commit: neon-migrations $DUP_ONLY_NESTED_SHA" "$SEM_FILE"; then
  pass "две копии одного origin — не коллизия: заявка принята по копии, где коммит есть"
else
  fail "дубль чекаута с одним origin не разрешён (exit $NC_RC): $NC_OUT"
fi

note_commit "$EXTERNAL_SHA" --repo service
if [ "$NC_RC" -eq 0 ] && grep -qxF "commit: service $EXTERNAL_SHA" "$SEM_FILE"; then
  pass "симлинк записан под запрошенным именем, а не под basename цели"
else
  fail "имя заявки для симлинка искажено (exit $NC_RC): $(grep '^commit: ' "$SEM_FILE" | tr '\n' ' ')"
fi

# A linked worktree is named after the session, not after the repository. Its
# own basename resolves to nothing, so the claim must carry the canonical
# repo's name instead (caught live while closing the session that wrote the
# first half of this fix).
LINKED_WT="$IWE_ROOT/.iwe-runtime/isolated-worktrees/agent-1789831272-656a"
mkdir -p "$(dirname "$LINKED_WT")"
git -C "$GOV_DIR" worktree add -q --detach "$LINKED_WT" HEAD 2>/dev/null
WT_SHA=$(add_commit "$LINKED_WT" "worktree-work")
cd "$LINKED_WT" || exit 1
note_commit "$WT_SHA"
cd "$GOV_DIR" || exit 1
if [ "$NC_RC" -eq 0 ] && grep -qxF "commit: DS-strategy $WT_SHA" "$SEM_FILE"; then
  pass "заявка из изолированной копии записана под именем канонического репозитория"
else
  fail "заявка из изолированной копии записана под именем каталога worktree (exit $NC_RC): $(grep "$WT_SHA" "$SEM_FILE" || echo 'строки нет')"
fi

note_commit "$GOV_SHA" --repo not-a-repo
if [ "$NC_RC" -ne 0 ]; then
  pass "существующий каталог без .git репозиторием не считается"
else
  fail "каталог без .git принят как репозиторий"
fi

note_commit "$GOV_SHA" --repo DS-no-such-repo
if [ "$NC_RC" -ne 0 ] && printf '%s' "$NC_OUT" | grep -q 'не найден'; then
  pass "несуществующее имя отклонено именно как отсутствие"
else
  fail "несуществующее имя отклонено не тем сообщением (exit $NC_RC): $NC_OUT"
fi

# === reader: the resolver its claim loop delegates to ===

resolve() {  # resolve <name> [<sha>] -- stdout in $R_OUT, stderr in $R_ERR, exit code in $R_RC
  R_RC=0
  # normalize_remote_url is a collaborator of the resolver, so it is extracted
  # alongside it rather than restated here (a local copy would let the suite
  # pass while the real comparison rule drifts).
  #
  # Extract into variables, never `eval "$(sed ... "...{/,/^}/p" ...)"` inline:
  # bash 3.2 (macOS /bin/bash, which the launchd test gate resolves `bash` to)
  # brace-expands that word -- its brace scanner takes the inner opening quote
  # for the outer closing one, so `{/,/^}` splits the sed script into two broken
  # ones (`... //p` and `... /^/p`), both functions vanish and every resolve()
  # reports "not found" (delivery Mac->server stalled 19-24.09.2026 on this).
  # An assignment's right-hand side is never brace-expanded.
  #
  # stderr is kept, not sent to /dev/null: those sed errors stayed invisible for
  # five days because the inner shell's stderr was discarded. It is captured
  # apart from stdout because the resolver legitimately prints candidate paths
  # to stderr on exit 3, and $R_OUT is compared for equality with a path.
  R_ERR_FILE="$SANDBOX/resolve.stderr"
  R_OUT=$(IWE_ROOT="$IWE_ROOT" bash -c '
    set -uo pipefail
    src_normalize=$(sed -n "/^normalize_remote_url() {/,/^}/p" "$1")
    src_resolver=$(sed -n "/^_resolve_repo_checkout() {/,/^}/p" "$1")
    eval "$src_normalize"
    eval "$src_resolver"
    for fn in normalize_remote_url _resolve_repo_checkout; do
      declare -F "$fn" >/dev/null || { echo "not found: $fn (bash $BASH_VERSION)"; exit 90; }
    done
    _resolve_repo_checkout "$2" "$3"
  ' _ "$SG" "$1" "${2:-}" 2>"$R_ERR_FILE") || R_RC=$?
  R_ERR=$(tr '\n' ' ' <"$R_ERR_FILE" 2>/dev/null || true)
}

# Failure text for the resolve() checks: the resolver's stderr is evidence
# (extraction errors, or the candidate list behind an exit 3).
resolve_fail() { fail "$1${R_ERR:+ | stderr: $R_ERR}"; }

resolve mentorship-service
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$NESTED_DIR" && pwd -P)" ]; then
  pass "читатель разрешает вложенный репозиторий в его настоящий каталог"
else
  resolve_fail "вложенный репозиторий не разрешён (exit $R_RC): '$R_OUT'"
fi

resolve iwe-root
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$IWE_ROOT" && pwd -P)" ]; then
  pass "алиас корня разрешается в корень"
else
  resolve_fail "алиас корня сломан (exit $R_RC): '$R_OUT'"
fi

resolve DS-ai-systems
if [ "$R_RC" -eq 3 ]; then
  pass "читатель отказывает на разных origin отдельным кодом (3), не выбирая кандидата"
else
  resolve_fail "коллизия разных origin у читателя дала exit $R_RC вместо 3: '$R_OUT'"
fi

resolve neon-migrations "$DUP_ONLY_NESTED_SHA"
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$DUP_NESTED" && pwd -P)" ]; then
  pass "среди копий одного origin выбрана та, где заявленный коммит есть"
else
  resolve_fail "копия с коммитом не выбрана (exit $R_RC): '$R_OUT'"
fi

resolve neon-migrations
if [ "$R_RC" -eq 0 ]; then
  pass "копии одного origin разрешаются и без указания коммита"
else
  resolve_fail "дубль одного origin без коммита дал exit $R_RC вместо 0"
fi

resolve half-origin
if [ "$R_RC" -eq 3 ]; then
  pass "кандидат без origin не сливается с кандидатом с origin — неоднозначность"
else
  resolve_fail "пара 'с origin + без origin' дала exit $R_RC вместо 3: '$R_OUT'"
fi

resolve no-origin-repo
if [ "$R_RC" -eq 0 ]; then
  pass "единственный кандидат без origin разрешается (отказ — забота читателя)"
else
  resolve_fail "единственный кандидат без origin дал exit $R_RC вместо 0"
fi

resolve service
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$EXTERNAL_DIR" && pwd -P)" ]; then
  pass "симлинк разрешается в физический каталог цели"
else
  resolve_fail "симлинк не разрешён (exit $R_RC): '$R_OUT'"
fi

resolve split-brain "$SPLIT_ONLY_NESTED_SHA"
if [ "$R_RC" -eq 3 ]; then
  pass "SHA не разрешает коллизию разных origin — идентичность решается до коммита"
else
  resolve_fail "SHA выбрал победителя между разными origin (exit $R_RC): '$R_OUT'"
fi

resolve both-anonymous
if [ "$R_RC" -eq 3 ]; then
  pass "два кандидата без origin не считаются одним репозиторием"
else
  resolve_fail "пара безымянных по origin дала exit $R_RC вместо 3: '$R_OUT'"
fi

resolve dedupe-me
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$DEDUPE_DIR" && pwd -P)" ]; then
  pass "один чекаут, видимый через два контейнера, не читается как два кандидата"
else
  resolve_fail "дедупликация по физическому пути не сработала (exit $R_RC): '$R_OUT'"
fi

# Обратная совместимость: семафоры, открытые до правки писателя, несут заявки
# под именем изолированной копии. Их нельзя переписать (чужие живые сессии),
# значит читатель обязан их разрешать — в канонический репозиторий копии.
resolve "$(basename "$LINKED_WT")"
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$GOV_DIR" && pwd -P)" ]; then
  pass "старая заявка под именем изолированной копии разрешается в канонический репозиторий"
else
  resolve_fail "имя изолированной копии не разрешено (exit $R_RC): '$R_OUT'"
fi

resolve neon-migrations 0000000000000000000000000000000000000000
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$IWE_ROOT/neon-migrations" && pwd -P)" ]; then
  pass "коммита нет ни в одной копии — возвращается первая, отказ остаётся за читателем"
else
  resolve_fail "при отсутствии коммита вернулась не первая копия (exit $R_RC): '$R_OUT'"
fi

if [ -d "$DEPTH_FULL" ] && [ "$(git -C "$IWE_ROOT/depth-test" rev-parse --is-shallow-repository)" = "true" ]; then
  resolve depth-test "$DEPTH_TIP_SHA"
  if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(cd "$DEPTH_FULL" && pwd -P)" ]; then
    pass "при одном origin в двух написаниях выбран полный клон, а не shallow (шедший первым)"
  else
    fail "предпочтение полного клона не сработало (exit $R_RC): '$R_OUT'"
  fi
else
  fail "подготовка shallow/full пары не удалась — правило предпочтения не проверено"
fi

resolve DS-no-such-repo
if [ "$R_RC" -eq 2 ]; then
  pass "отсутствующее имя даёт отдельный код (2), отличимый от неоднозначности"
else
  fail "отсутствующее имя дало exit $R_RC вместо 2"
fi

resolve "../escape"
if [ "$R_RC" -eq 2 ]; then
  pass "имя с обходом каталога отклонено"
else
  fail "имя с обходом каталога дало exit $R_RC вместо 2: '$R_OUT'"
fi

echo ""
echo "Итог: $PASS прошли, $FAIL упали."
[ "$FAIL" -eq 0 ]
