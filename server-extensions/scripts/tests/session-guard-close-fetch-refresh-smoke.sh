#!/usr/bin/env bash
# session-guard-close-fetch-refresh-smoke.sh — WP-484 (18.08, ArchGate "case Б-1"):
# _untracked_matches_published/validate_orz's published-ref check compares an
# untracked file against refs/remotes/*, which is only as fresh as the last
# fetch. _refresh_remote_refs_for_close() does one best-effort `git fetch`
# (3s timeout, WARN-and-continue on failure) before that comparison runs.
#
# Extracts the two functions by line range rather than sourcing the whole
# script -- session-guard.sh is a CLI entrypoint (argument parsing + exit at
# the bottom), not a function library, so a plain `source` would execute it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
FUNCS_START=$(grep -n '^_untracked_matches_published()' "$GUARD" | head -1 | cut -d: -f1)
FUNCS_END=$(grep -n '^_refresh_remote_refs_for_close()' "$GUARD" | head -1 | cut -d: -f1)
FUNCS_END=$(awk -v start="$FUNCS_END" 'NR>=start && /^}/{print NR; exit}' "$GUARD")
[ -n "$FUNCS_START" ] && [ -n "$FUNCS_END" ] || { echo "FAIL: could not locate functions in $GUARD" >&2; exit 1; }
FUNCS_SRC=$(sed -n "${FUNCS_START},${FUNCS_END}p" "$GUARD")

TEST_ROOT=$(mktemp -d /private/tmp/session-guard-close-fetch.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

# A real bare origin -- not just a remote-add -- so `git fetch` has something
# genuine to pull, exercising the actual network-shaped code path.
ORIGIN="$TEST_ROOT/origin.git"
git init -q --bare "$ORIGIN"

CLONE_A="$TEST_ROOT/clone-a"   # publishes a file to origin
CLONE_B="$TEST_ROOT/clone-b"   # holds an untracked copy, stale refs/remotes
git clone -q "$ORIGIN" "$CLONE_A"
git -C "$CLONE_A" config user.email a@test
git -C "$CLONE_A" config user.name clone-a
echo seed > "$CLONE_A/README.md"
git -C "$CLONE_A" add README.md
git -C "$CLONE_A" commit -q -m seed
git -C "$CLONE_A" push -q origin main

git clone -q "$ORIGIN" "$CLONE_B"
git -C "$CLONE_B" config user.email b@test
git -C "$CLONE_B" config user.name clone-b

# Scenario 1: origin advances (clone-a pushes a new file) AFTER clone-b's last
# fetch. clone-b independently creates an untracked byte-identical copy of
# that same file -- the exact "content already published elsewhere" case
# _untracked_matches_published exists to recognize. Without a fresh fetch,
# clone-b's refs/remotes/* predates the push and the match must fail.
echo "published content" > "$CLONE_A/report.md"
git -C "$CLONE_A" add report.md
git -C "$CLONE_A" commit -q -m "publish report"
git -C "$CLONE_A" push -q origin main
echo "published content" > "$CLONE_B/report.md"  # untracked in clone-b

bash -c "
  $FUNCS_SRC
  _untracked_matches_published '$CLONE_B' report.md
" && STALE_MATCH_RC=0 || STALE_MATCH_RC=$?
if [ "$STALE_MATCH_RC" -eq 0 ]; then
  echo "FAIL: stale refs/remotes (no fetch yet) unexpectedly matched -- fixture invalid" >&2
  exit 1
fi
echo "OK: stale refs/remotes correctly misses a just-published file (fixture sanity)"

# Scenario 2: after _refresh_remote_refs_for_close does its fetch, the same
# comparison must now succeed -- this is the false-negative case-Б-1 fixes.
REFRESH_OUT=$(bash -c "
  $FUNCS_SRC
  _refresh_remote_refs_for_close '$CLONE_B' 2>&1
  _untracked_matches_published '$CLONE_B' report.md
") && FRESH_MATCH_RC=0 || FRESH_MATCH_RC=$?
if [ "$FRESH_MATCH_RC" -ne 0 ]; then
  echo "FAIL: after refresh, refs/remotes should recognize the published file: $REFRESH_OUT" >&2
  exit 1
fi
echo "OK: after _refresh_remote_refs_for_close, the just-published file is recognized"

# Scenario 3: unreachable origin -- fetch must fail closed on TIME, not on
# the caller: a WARN is printed, no exception propagates, and a SECOND call
# in the same process does not fetch again (REMOTE_REFS_REFRESHED_FOR_CLOSE
# guard) so a slow/offline network only costs one timeout per close, not one
# per refs/remotes reader.
CLONE_C="$TEST_ROOT/clone-c"
git clone -q "$ORIGIN" "$CLONE_C"
git -C "$CLONE_C" remote set-url origin "https://127.0.0.1:1/nonexistent-origin.git"
OFFLINE_OUT=$(bash -c "
  $FUNCS_SRC
  _refresh_remote_refs_for_close '$CLONE_C'
  _refresh_remote_refs_for_close '$CLONE_C'
  echo REFRESH_CALLED_TWICE_OK
" 2>&1) && OFFLINE_RC=0 || OFFLINE_RC=$?
if [ "$OFFLINE_RC" -ne 0 ]; then
  echo "FAIL: unreachable origin must degrade gracefully, not abort the caller: $OFFLINE_OUT" >&2
  exit 1
fi
if ! grep -q 'не удался/не уложился' <<<"$OFFLINE_OUT"; then
  echo "FAIL: unreachable origin must print the fallback WARN: $OFFLINE_OUT" >&2
  exit 1
fi
if ! grep -q 'REFRESH_CALLED_TWICE_OK' <<<"$OFFLINE_OUT"; then
  echo "FAIL: second refresh call in the same process must not re-abort: $OFFLINE_OUT" >&2
  exit 1
fi
WARN_COUNT=$(grep -c 'не удался/не уложился' <<<"$OFFLINE_OUT")
if [ "$WARN_COUNT" -ne 1 ]; then
  echo "FAIL: expected exactly one fetch attempt (once-per-close guard), got $WARN_COUNT WARNs: $OFFLINE_OUT" >&2
  exit 1
fi
echo "OK: unreachable origin warns once, degrades to cache, second call in-process is a no-op"

echo "PASS: session-guard close-time remote-refs refresh"

# Code branch delivery uses a frozen runner receipt and freshly fetched exact OIDs.
python3 - "$GUARD" "$TEST_ROOT" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import yaml

script, sandbox = map(Path, sys.argv[1:])
source = script.read_text()
start = source.index('_code_branch_claim_has_publish_proof() {')
end = source.index('\n_claimed_commits_have_publish_proof()', start)
helper = sandbox / 'branch-proof-functions.sh'
helper.write_text(source[start:end])


def git(path, *args):
    return subprocess.run(['git', '-C', str(path), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def init(path, origin):
    path.mkdir(parents=True, exist_ok=True)
    git(path, 'init', '-q', '-b', 'main')
    git(path, 'config', 'user.email', 'test@example.com')
    git(path, 'config', 'user.name', 'test')
    git(path, 'remote', 'add', 'origin', str(origin))


def commit(path, text):
    (path / 'code.txt').write_text(text)
    git(path, 'add', 'code.txt')
    git(path, 'commit', '-q', '-m', text)
    return git(path, 'rev-parse', 'HEAD')


def fixture(name):
    case = sandbox / name
    root, remote = case / 'IWE', case / 'origin.git'
    remote.mkdir(parents=True)
    git(remote, 'init', '-q', '--bare', '-b', 'main')
    gov, orz, code = root / 'governance', root / 'sessions', root / 'DS-MCP/product'
    for path in (root, gov, orz):
        init(path, case / (path.name + '-origin.git'))
    init(code, remote)
    seed = commit(code, 'seed')
    git(code, 'push', '-q', '-u', 'origin', 'main')
    wt = root / '.iwe-runtime/isolated-worktrees/code'
    wt.parent.mkdir(parents=True)
    git(code, 'worktree', 'add', '-q', '-b', 'wp579', str(wt))
    first = commit(wt, 'first')
    head = commit(wt, 'second')
    git(wt, 'push', '-q', '-u', 'origin', 'wp579')
    metadata = {'slug': 'wp579', 'session_id': 'own-session',
                'governance_worktree': str(gov), 'orz_sessions_dir': str(orz)}
    card = {'process_id': 'quick-close', 'owner_session_id': 'own-session',
            'requested_slug': 'wp579', 'results': {'commit-push': {
                'all_pushed': True, 'failed': [], 'pushed': [
                    {'repo': str(wt.relative_to(root)), 'sha': head}]}}}
    return dict(root=root, remote=remote, gov=gov, orz=orz, code=code, wt=wt,
                first=first, head=head, seed=seed, metadata=metadata, card=card)


def verify(name, expected, mutate=None):
    f = fixture(name)
    if mutate:
        mutate(f)
    card_path = f['gov'] / 'inbox/agent/tasks/RUN-quick-close-wp579.md'
    card_path.parent.mkdir(parents=True)
    card_path.write_text('---\n' + yaml.safe_dump(f['card']) + '---\n')
    git(f['gov'], 'add', 'inbox/agent/tasks/RUN-quick-close-wp579.md')
    git(f['gov'], 'commit', '-q', '-m', 'freeze receipt')
    frozen = git(f['gov'], 'rev-parse', 'HEAD')
    # Live card is deliberately unusable: only the frozen Git blob may decide.
    card_path.write_text('mutable live content is not a receipt\n')
    sem = f['root'] / 'session.open'
    sem.write_text('---\n' + yaml.safe_dump(f['metadata']) + '---\n'
                   + f"close_delivery_source_head: {frozen}\n"
                   + f"commit: product {f['first']}\ncommit: product {f['head']}\n")
    for claim in (f['first'], f['head']):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"; _code_branch_claim_has_publish_proof "$2" "$3" "$4" product',
             'test', str(helper), str(sem), str(f['code']), claim],
            env={**os.environ, 'IWE_ROOT': str(f['root'])}, capture_output=True, text=True,
        )
        assert (result.returncode == 0) == expected, (name, claim, result.stderr)
    print('OK: branch-proof ' + name)


def stale_deleted(f):
    git(f['remote'], 'update-ref', '-d', 'refs/heads/wp579')


def wrong_ref(f):
    git(f['wt'], 'config', 'branch.wp579.merge', 'refs/heads/main')


def nonancestor(f):
    f['first'] = git(f['code'], 'commit-tree', f"{f['head']}^{{tree}}", '-p', f['seed'], '-m', 'foreign')
    f['head'] = f['first']


def patch_only(f):
    alternate = git(f['code'], 'commit-tree', f"{f['head']}^{{tree}}", '-p', f['first'], '-m', 'rewritten')
    git(f['code'], 'push', '-q', 'origin', alternate + ':refs/heads/rewritten')
    git(f['remote'], 'update-ref', 'refs/heads/wp579', alternate)


def protected(f, field):
    if field == 'root':
        git(f['root'], 'remote', 'set-url', 'origin', str(f['remote']))
    else:
        f['metadata'][field] = str(f['code'])


def other_origin(f):
    other = f['remote'].parent / 'different-origin.git'
    git(f['remote'].parent, 'clone', '-q', '--bare', str(f['remote']), str(other))
    git(f['code'], 'remote', 'set-url', 'origin', str(other))
    # Same OIDs in a different repo must not make its worktree our receipt's source.
    foreign = f['root'] / 'DS-MCP/foreign'
    git(f['root'], 'clone', '-q', str(other), str(foreign))
    git(foreign, 'checkout', '-q', 'wp579')
    f['card']['results']['commit-push']['pushed'][0]['repo'] = str(foreign.relative_to(f['root']))


def hidden(f, flag):
    git(f['wt'], 'update-index', flag, 'code.txt')
    (f['wt'] / 'code.txt').write_text('hidden unpublished content')


verify('fresh-own-two-claims', True)
verify('fresh-no-cached-ref', True, lambda f: git(f['code'], 'update-ref', '-d', 'refs/remotes/origin/wp579'))
verify('stale-cache-deleted-ref', False, stale_deleted)
verify('wrong-upstream-ref', False, wrong_ref)
verify('nonancestor', False, nonancestor)
verify('patch-equivalent-only', False, patch_only)
verify('samehash-different-origin', False, other_origin)
verify('protected-root-origin', False, lambda f: protected(f, 'root'))
verify('protected-governance-common', False, lambda f: protected(f, 'governance_worktree'))
verify('protected-orz-common', False, lambda f: protected(f, 'orz_sessions_dir'))
verify('dirty-worktree', False, lambda f: (f['wt'] / 'code.txt').write_text('unpublished'))
verify('hidden-assume-unchanged', False, lambda f: hidden(f, '--assume-unchanged'))
verify('hidden-skip-worktree', False, lambda f: hidden(f, '--skip-worktree'))
verify('foreign-receipt-owner', False, lambda f: f['card'].update(owner_session_id='foreign'))
verify('wrong-session-slug', False, lambda f: f['metadata'].update(slug='wp58'))
PY
