#!/usr/bin/env bash
# Regression for WP-484 "находка 1" (session
# 2026-09-16-18-wp484-fmt-orz-sessions-dir-patch §5-6; fixed 16.09,
# peer-session 2026-09-16-22-wp484-close-mechanism-hard-snapshot,
# Claude+Kimi): _repo_head_has_publish_proof("$sessions_repo", "sessions
# checkout") used to be called with no semaphore/field arguments at all, so
# its scoped fallback (_repo_scope_has_publish_proof) never engaged for
# MC-sessions -- only the bare `merge-base --is-ancestor HEAD origin/main`
# check ran. Every session writes its own ORZ scaffold file into MC-sessions
# at `open` time (a footprint-skip mirroring the governance-checkout gate
# would therefore never actually skip anything here, unlike governance where
# most sessions have zero footprint), so this is the common case, not an
# edge case: a shared MC-sessions checkout drifts constantly under real
# concurrency (15-20 sessions committing daily), and the bare ancestry check
# fails for any session whose own work was honestly delivered under a
# different SHA (isolate-push republish) once foreign history has advanced
# origin/main past the point this session's checkout knows about.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-sessions-scope.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q -b main "$ORIGIN"
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

SESSIONS="$TEST_ROOT/MC-sessions"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
mkdir -p "$SESSIONS"
git init --bare -q -b main "$SESSIONS_ORIGIN"
git -C "$SESSIONS" init -q
git -C "$SESSIONS" config user.email test@example.com
git -C "$SESSIONS" config user.name "Test"
git -C "$SESSIONS" remote add origin "$SESSIONS_ORIGIN"
echo seed > "$SESSIONS/README.md"
git -C "$SESSIONS" add README.md
git -C "$SESSIONS" commit -qm init
git -C "$SESSIONS" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

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

# --- Scenario F (находка 1, acceptance criterion): MC-sessions has genuinely
# diverged from origin (unrelated foreign history, the everyday shape of a
# shared checkout under 15-20 parallel sessions) while this is a fully
# MODERN, non-isolated semaphore (orz_sessions_dir: present, `open` writes it
# unconditionally -- no legacy-field stripping in this test, unlike the
# governance-side D/E scenarios). This session's own registered ORZ file must
# still close when it was honestly delivered, even under a different SHA
# (isolate-push republish shape, DRR-f102-isolated-push-cherry-pick.md).
CLAUDE_CODE_SESSION_ID="session-F" bash "$GUARD" open --wp WP-484 --task fixture --slug sessions-scope-f --agent fixture >/dev/null
SEM_F=$(grep -l '^slug: sessions-scope-f$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q '^orz_sessions_dir: ' "$SEM_F" \
  || { echo "FAIL: fixture setup -- modern open() did not write orz_sessions_dir" >&2; exit 1; }
ORZ_BASENAME_F=$(grep '^orz_file: ' "$SEM_F" | cut -d' ' -f2-)

FOREIGN="$TEST_ROOT/foreign-session-f"
git clone -q "$SESSIONS_ORIGIN" "$FOREIGN"
git -C "$FOREIGN" config user.email foreign@test
git -C "$FOREIGN" config user.name foreign
echo "unrelated foreign work" > "$FOREIGN/foreign-f.txt"
git -C "$FOREIGN" add foreign-f.txt
git -C "$FOREIGN" commit -qm "foreign session advances sessions origin"
git -C "$FOREIGN" push -q origin HEAD:main

# Our own ORZ content, committed on the OLD base (before the foreign push
# above) -- never fast-forwarded, so local HEAD is not an ancestor of the
# now-advanced sessions origin/main, and vice versa.
write_orz "$SESSIONS/$ORZ_BASENAME_F"
git -C "$SESSIONS" add "$ORZ_BASENAME_F"
git -C "$SESSIONS" commit -qm "own ORZ content, not yet fast-forwarded onto foreign history"
if git -C "$SESSIONS" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  echo "FAIL: fixture setup -- local HEAD is still an ancestor of origin/main, divergence not achieved" >&2
  exit 1
fi

# Republish the SAME content onto fresh sessions origin/main under a
# DIFFERENT SHA -- exactly what isolate-push.sh does from an isolated
# worktree while the shared checkout stays behind.
REPUBLISH="$TEST_ROOT/republish-sessions-f"
git clone -q "$SESSIONS_ORIGIN" "$REPUBLISH"
git -C "$REPUBLISH" config user.email republish@test
git -C "$REPUBLISH" config user.name republish
write_orz "$REPUBLISH/$ORZ_BASENAME_F"
git -C "$REPUBLISH" add "$ORZ_BASENAME_F"
git -C "$REPUBLISH" commit -qm "own ORZ content, republished onto fresh sessions origin/main"
git -C "$REPUBLISH" push -q origin HEAD:main

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-sessions-scope-f.md" <<EOF
---
process_id: quick-close
run_id: quick-close-sessions-scope-f
requested_slug: sessions-scope-f
status: completed
current_step: done
owner_session_id: session-F
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-sessions-scope-f.md"
  echo "file: $ORZ_BASENAME_F"
  echo "commit: $(basename "$SESSIONS") $(git -C "$SESSIONS" rev-parse HEAD)"
} >> "$SEM_F"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-F" bash "$GUARD" close --wp WP-484 --slug sessions-scope-f --agent fixture 2>&1); then
  echo "PASS: modern semaphore closes when MC-sessions diverged but this session's own registered scope was honestly delivered (republished SHA)"
else
  echo "FAIL: close still refuses an honestly-delivered session on a diverged MC-sessions checkout: $CLOSE_OUT" >&2
  exit 1
fi

# --- Scenario G (regression, must stay caught): same MC-sessions divergence
# as F, but this session's claimed ORZ content was NEVER actually delivered
# anywhere. The scoped fallback added for F must not turn into a blanket
# pass for every session on a diverged MC-sessions checkout -- undelivered
# work still has to block close.
CLAUDE_CODE_SESSION_ID="session-G" bash "$GUARD" open --wp WP-484 --task fixture --slug sessions-scope-g --agent fixture >/dev/null
SEM_G=$(grep -l '^slug: sessions-scope-g$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_G=$(grep '^orz_file: ' "$SEM_G" | cut -d' ' -f2-)

write_orz "$SESSIONS/$ORZ_BASENAME_G"
git -C "$SESSIONS" add "$ORZ_BASENAME_G"
git -C "$SESSIONS" commit -qm "own ORZ content, never delivered anywhere"
OWN_SHA_G=$(git -C "$SESSIONS" rev-parse HEAD)

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-sessions-scope-g.md" <<EOF
---
process_id: quick-close
run_id: quick-close-sessions-scope-g
requested_slug: sessions-scope-g
status: completed
current_step: done
owner_session_id: session-G
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-sessions-scope-g.md"
  echo "file: $ORZ_BASENAME_G"
  echo "commit: $(basename "$SESSIONS") $OWN_SHA_G"
} >> "$SEM_G"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-G" bash "$GUARD" close --wp WP-484 --slug sessions-scope-g --agent fixture 2>&1); then
  echo "FAIL: close accepted a session whose registered MC-sessions work was never actually delivered: $CLOSE_OUT" >&2
  exit 1
else
  echo "PASS: on a diverged MC-sessions checkout, genuinely undelivered work still blocks close"
fi

# A governance isolate must not disable proof for the separate shared ORZ
# checkout. Exercise the real proof function with both published and missing
# content, without making the fixture's governance checkout disposable.
PROOF_HELPER="$TEST_ROOT/scoped-proof.sh"
python3 - "$GUARD" "$PROOF_HELPER" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("_repo_scope_has_publish_proof() {")
end = source.index("\n_repo_head_has_publish_proof() {", start)
Path(sys.argv[2]).write_text(source[start:end] + '\n_repo_scope_has_publish_proof "$@"\n')
PY
cp "$SEM_F.closed" "$TEST_ROOT/isolated-f.open"
cp "$SEM_G" "$TEST_ROOT/isolated-g.open"
for fixture in "$TEST_ROOT/isolated-f.open" "$TEST_ROOT/isolated-g.open"; do
  printf '\nisolated_worktree: %s\n' "$REPO" >> "$fixture"
done
SESSIONS_REMOTE=$(git -C "$SESSIONS" rev-parse origin/main)
scoped_sessions_proof() {
  bash "$PROOF_HELPER" "$SESSIONS" "sessions checkout" "$1" "$SESSIONS_REMOTE" \
    orz_sessions_dir governance_worktree "" ""
}
scoped_sessions_proof "$TEST_ROOT/isolated-f.open" \
  || { echo "FAIL: governance isolation blocked delivered shared ORZ" >&2; exit 1; }
if scoped_sessions_proof "$TEST_ROOT/isolated-g.open"; then
  echo "FAIL: governance isolation accepted unpublished ORZ" >&2
  exit 1
fi
# An isolated checkout itself, ambiguous isolation, or a mismatched declared
# governance path must retain the original refusal.
for invalid in sessions duplicate foreign empty; do
  python3 - "$TEST_ROOT/isolated-f.open" "$TEST_ROOT/invalid.open" "$invalid" "$SESSIONS" <<'PY'
from pathlib import Path
import sys
source, target, case, sessions = sys.argv[1:]
lines = Path(source).read_text().splitlines()
if case == "duplicate":
    lines += [next(line for line in lines if line.startswith("isolated_worktree:"))]
else:
    replacement = "" if case == "empty" else sessions if case == "sessions" else sessions + "-foreign"
    lines = ["isolated_worktree: " + replacement if line.startswith("isolated_worktree:") else line for line in lines]
    if case == "sessions":
        lines = ["governance_worktree: " + sessions if line.startswith("governance_worktree:") else line for line in lines]
Path(target).write_text("\n".join(lines) + "\n")
PY
  if scoped_sessions_proof "$TEST_ROOT/invalid.open"; then
    echo "FAIL: accepted invalid isolation: $invalid" >&2
    exit 1
  fi
done
echo "PASS: shared ORZ proof survives governance isolation; unpublished and ambiguous scopes remain blocked"

echo "PASS: sessions-checkout scope fallback (находка 1) closes honestly-delivered diverged sessions, still blocks undelivered ones"

# Files published from another clone are untracked on a foreign shared branch.
# Proof must check their raw content and index again, not only their ?? status.
python3 - "$GUARD" "$TEST_ROOT/remote-only" <<'PY'
import os
import shutil
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2]).resolve()
root.mkdir()
start = source.index('_repo_scope_has_publish_proof() {')
end = source.index('\n_repo_head_has_publish_proof() {', start)
proof = root / 'proof.sh'
proof.write_text(source[start:end] + '\n_repo_scope_has_publish_proof "$@"\n')
real_git = shutil.which('git')
sessions, governance, origin, publisher = [root / name for name in ('MC-sessions', 'governance', 'origin.git', 'publisher')]


def git(repo, *args):
    return subprocess.check_output([real_git, '-c', 'core.hooksPath=/dev/null', '-C', str(repo), *args], text=True, stderr=subprocess.PIPE).strip()


def init(repo):
    repo.mkdir()
    git(repo, 'init', '-q', '-b', 'main')
    git(repo, 'config', 'user.name', 'Fixture')
    git(repo, 'config', 'user.email', 'fixture@example.invalid')


init(governance)
(governance / 'context.md').write_text('context\n')
git(governance, 'add', 'context.md')
git(governance, 'commit', '-qm', 'context')
init(sessions)
(sessions / 'seed.md').write_text('seed\n')
git(sessions, 'add', 'seed.md')
git(sessions, 'commit', '-qm', 'seed')
subprocess.run([real_git, 'init', '--bare', '-q', str(origin)], check=True)
git(sessions, 'remote', 'add', 'origin', str(origin))
git(sessions, 'push', '-q', 'origin', 'HEAD:main')
subprocess.run([real_git, 'clone', '-q', '-b', 'main', str(origin), str(publisher)], check=True)
git(publisher, 'config', 'user.name', 'Fixture')
git(publisher, 'config', 'user.email', 'fixture@example.invalid')
relative = 'notes/session.md'
(publisher / 'notes').mkdir()
(publisher / relative).write_text('published result\n')
git(publisher, 'add', relative)
git(publisher, 'commit', '-qm', 'publish session')
git(publisher, 'push', '-q', 'origin', 'main')
published = git(publisher, 'rev-parse', 'HEAD')
(sessions / 'foreign.md').write_text('foreign unpublished work\n')
git(sessions, 'add', 'foreign.md')
git(sessions, 'commit', '-qm', 'foreign work')
git(sessions, 'fetch', '-q', 'origin', 'main')
(sessions / 'notes').mkdir()
note = sessions / relative
original = (publisher / relative).read_bytes()
note.write_bytes(original)
sem = root / 'fixture.open'
base = f'orz_sessions_dir: {sessions}\ngovernance_worktree: {governance}\nfile: {relative}\nfile: seed.md\ncommit: MC-sessions {published}\n'
sem.write_text(base)
args = ['bash', str(proof), str(sessions), 'sessions checkout', str(sem), published, 'orz_sessions_dir', 'governance_worktree', '', '']
env = dict(os.environ, IWE_ROOT=str(root))


def check(label, expected, extra_env=None):
    result = subprocess.run(args, text=True, capture_output=True, env={**env, **(extra_env or {})})
    assert (result.returncode == 0) == expected, (label, result.stdout, result.stderr)
    print('PASS: ' + label)


check('published untracked file accepted on foreign branch', True)
sem.write_text(base + f'isolated_worktree: {governance}\n')
check('separate shared sessions accepted with isolated governance', True)
sem.write_text(base)
sem.write_text(base.replace(f'governance_worktree: {governance}', f'governance_worktree: {sessions}'))
check('combined governance and sessions checkout rejected', False)
sem.write_text(base)
note.write_bytes(original + b'unpublished\n')
check('different bytes rejected', False)
note.write_bytes(original)
note.chmod(0o755)
check('different executable mode rejected', False)
note.chmod(0o644)
git(sessions, 'add', relative)
check('staged file rejected', False)
git(sessions, 'restore', '--staged', '--', relative)
note.unlink()
note.symlink_to(publisher / relative)
check('file symlink rejected', False)
note.unlink()
note.write_bytes(original)
(sessions / 'notes').rename(sessions / 'real-notes')
(sessions / 'notes').symlink_to(sessions / 'real-notes', target_is_directory=True)
check('parent symlink rejected', False)
(sessions / 'notes').unlink()
(sessions / 'real-notes').rename(sessions / 'notes')
(sessions / 'extra.md').write_text('not delivered\n')
sem.write_text(base + 'file: extra.md\n')
check('additional unpublished own file rejected', False)
sem.write_text(base)
for flag in ('assume-unchanged', 'skip-worktree'):
    git(sessions, 'update-index', '--' + flag, 'seed.md')
    check('hidden index flag rejected: ' + flag, False)
    git(sessions, 'update-index', '--no-' + flag, 'seed.md')
(governance / relative).parent.mkdir()
(governance / relative).write_bytes(original)
check('ambiguous ownership rejected', False)
(governance / relative).unlink()
# Intercept the last status check to mutate content/index DURING the second pass.
# The wrapper never changes production tools or processes.
bin_dir = root / 'bin'
bin_dir.mkdir()
wrapper = bin_dir / 'git'
wrapper.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
arguments = sys.argv[1:]
if os.environ['PROOF_MUTATION'] == 'parent-symlink' and 'hash-object' in arguments:
    directory = Path(os.environ['PROOF_NOTE']).parent
    saved = directory.with_name('saved-notes')
    directory.rename(saved)
    directory.symlink_to(os.environ['PROOF_PUBLISHED_NOTES'], target_is_directory=True)
    try:
        result = subprocess.run([os.environ['REAL_GIT'], *arguments], capture_output=True)
    finally:
        directory.unlink()
        saved.rename(directory)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)
if (os.environ['PROOF_MUTATION'] in ('content', 'index') and 'status' in arguments
        and os.environ['PROOF_RELATIVE'] in arguments):
    counter = Path(os.environ['PROOF_COUNTER'])
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if count == 4:
        if os.environ['PROOF_MUTATION'] == 'content':
            with open(os.environ['PROOF_NOTE'], 'ab') as stream:
                stream.write(b'raced change\\n')
        else:
            subprocess.run([os.environ['REAL_GIT'], '-C', os.environ['PROOF_REPO'], 'add', '--', os.environ['PROOF_RELATIVE']], check=True)
os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT'], *arguments])
''')
wrapper.chmod(0o755)
for mutation in ('content', 'index'):
    counter = root / ('counter-' + mutation)
    check('second-pass ' + mutation + ' race rejected', False, {
        'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
        'REAL_GIT': real_git, 'PROOF_COUNTER': str(counter), 'PROOF_NOTE': str(note),
        'PROOF_REPO': str(sessions), 'PROOF_RELATIVE': relative, 'PROOF_MUTATION': mutation,
    })
    assert counter.read_text() == '4', 'fixture did not reach second proof pass'
    if git(sessions, 'ls-files', '--stage', '--', relative):
        git(sessions, 'restore', '--staged', '--', relative)
    note.write_bytes(original)
# This attack made the old pathname-based hash accept unpublished content:
# swap in a symlink only during Git's reopen, then restore the original inode.
note.write_bytes(original + b'unpublished result\n')
check('transient parent symlink cannot substitute the hashed inode', False, {
    'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
    'REAL_GIT': real_git, 'PROOF_COUNTER': str(root / 'counter-symlink'),
    'PROOF_NOTE': str(note), 'PROOF_REPO': str(sessions), 'PROOF_RELATIVE': relative,
    'PROOF_MUTATION': 'parent-symlink', 'PROOF_PUBLISHED_NOTES': str(publisher / 'notes'),
})
assert note.read_bytes() == original + b'unpublished result\n'
note.write_bytes(original)
check('unchanged published result still accepted after negative cases', True)
PY

# Third-repository fallback is attribution, not ownership or delivery proof.
# Only paths with no owner in the existing scope consult genuine repo-qualified
# claims. Their exact trees can identify files absent from canonical HEAD or
# since deleted; an undeclared ancestor never supplies evidence. Current MC
# delivery checks and the original ambiguity rule must remain unchanged.
# These fixtures use only disposable local Git repositories and extracted
# functions. They do not run the installed guard CLI or contact a remote.
python3 - "$GUARD" "$TEST_ROOT" <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import sys

GUARD_SOURCE = Path(sys.argv[1]).read_text()
FIXTURES_ROOT = Path(sys.argv[2]).resolve()
REAL_GIT = shutil.which("git")


def function(source, name, end_name=None):
    start = source.index(name + "() {")
    end = (source.index("\n" + end_name + "() {", start) if end_name
           else source.index("\n}\n", start) + 3)
    return source[start:end]


def git(repo, *args):
    return subprocess.check_output(
        [REAL_GIT, "-C", str(repo), *args], text=True, stderr=subprocess.PIPE,
    ).strip()


def init(repo, origin):
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "Fixture")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "core.hooksPath", "/dev/null")
    git(repo, "remote", "add", "origin", origin)


def commit(repo, files):
    for path, data in files.items():
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(data)
    git(repo, "add", "--", *files)
    git(repo, "commit", "-qm", "fixture")
    return git(repo, "rev-parse", "HEAD")


class ClaimedRepositoryFallback(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="scope-proof-fixture-", dir=FIXTURES_ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.mc = self.root / "MC-sessions"
        self.gov = self.root / "governance"
        self.code = self.root / "DS-MCP" / "knowledge-mcp"
        init(self.mc, "https://example.invalid/MC-sessions.git")
        init(self.gov, "https://example.invalid/governance.git")
        init(self.code, "https://example.invalid/knowledge-mcp.git")
        commit(self.mc, {"seed.md": "seed\n"})
        self.mc_sha = commit(self.mc, {"session.md": "published session\n"})
        commit(self.gov, {"README.md": "governance README\n"})
        self.code_seed = commit(self.code, {"seed.md": "seed\n"})
        self.code_sha = commit(self.code, {
            "src/layers/reindex.ts": "export const ready = true;\n",
            "README.md": "code README\n",
        })
        self.claim_name = "knowledge-mcp"
        self.claim_sha = self.code_sha
        self.extra_paths = []
        self.extra_claims = []
        self.extra_headers = []
        self.semaphore = self.root / "fixture.open"

    def write_semaphore(self):
        self.semaphore.write_text("\n".join([
            "---", f"orz_sessions_dir: {self.mc}",
            f"governance_worktree: {self.gov}", *self.extra_headers, "---",
            "file: session.md", "file: README.md", "file: src/layers/reindex.ts",
            *["file: " + path for path in self.extra_paths],
            "commit: MC-sessions " + self.mc_sha,
            *(["commit: " + self.claim_name + " " + self.claim_sha] if self.claim_name else []),
            *self.extra_claims,
        ]) + "\n")

    def run_proof(self, *, mutate_during_resolution=False):
        self.write_semaphore()
        source = GUARD_SOURCE
        helpers = "\n".join([
            function(source, "normalize_remote_url"),
            function(source, "_resolve_repo_checkout"),
            function(source, "_repo_scope_has_publish_proof", "_repo_head_has_publish_proof"),
        ])
        helper = self.root / "proof.sh"
        helper.write_text(helpers + '\n_repo_scope_has_publish_proof "$@"\n')
        environment = {**os.environ, "IWE_ROOT": str(self.root),
                       "IWE_GOVERNANCE_REPO": "governance"}
        environment.pop("IWE_SESSION_GUARD_ANCHORED_FALLBACK", None)
        if mutate_during_resolution:
            # Intercept only the resolver's command for the third repo. The
            # production resolver stays unchanged and runs real Git afterward.
            commands = self.root / "commands"
            commands.mkdir()
            wrapper = commands / "git"
            wrapper.write_text("#!/usr/bin/env python3\n"
                "import os, sys\n"
                "from pathlib import Path\n"
                "if sys.argv[1:] == ['-C', os.environ['FIXTURE_CODE'], 'rev-parse', '--show-toplevel']:\n"
                "    with Path(os.environ['FIXTURE_SEM']).open('a') as stream:\n"
                "        stream.write('file: raced.txt\\n')\n"
                "os.execv(os.environ['FIXTURE_REAL_GIT'], [os.environ['FIXTURE_REAL_GIT'], *sys.argv[1:]])\n")
            wrapper.chmod(0o755)
            environment.update(PATH=str(commands) + os.pathsep + os.environ["PATH"],
                               FIXTURE_CODE=str(self.code), FIXTURE_SEM=str(self.semaphore),
                               FIXTURE_REAL_GIT=REAL_GIT)
        before = self.semaphore.read_bytes()
        result = subprocess.run([
            "bash", str(helper), str(self.mc), "sessions checkout", str(self.semaphore),
            self.mc_sha, "orz_sessions_dir", "governance_worktree", "", "",
        ], env=environment, capture_output=True, text=True, timeout=30)
        if not mutate_during_resolution:
            self.assertEqual(self.semaphore.read_bytes(), before)
        return result

    def assert_refused(self, result, reason):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(reason, result.stderr, result.stdout + result.stderr)

    def test_real_third_repo_claim_is_attributed(self):
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_readme_owner_is_not_made_ambiguous(self):
        # Both repos have README.md, but only the previously unknown code path
        # should consult code claims. The baseline README ownership is retained.
        self.assertTrue((self.gov / "README.md").is_file())
        self.assertTrue((self.code / "README.md").is_file())
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def prepare_governance_isolate(self):
        canonical = self.gov
        self.gov = self.root / "governance-isolate"
        git(canonical, "worktree", "add", "-q", "--detach", str(self.gov), "HEAD")
        self.extra_headers = [f"isolated_worktree: {self.gov}", "harness_session_id: own-session",
                              "session_id: own-guard-session"]
        path = "inbox/agent/tasks/RUN-quick-close-other-session.md"
        target = canonical / path
        target.parent.mkdir(parents=True)
        target.write_text("---\nid: RUN-quick-close-other-session\nkind: process-run\n"
                          "process_id: quick-close\nrun_id: quick-close-other-session\n"
                          "owner_session_id: foreign-session\nstatus: completed\ncurrent_step: done\n---\n")
        self.extra_paths.append(path)
        self.assertFalse((self.gov / path).exists())
        return canonical, path

    def test_canonical_same_repository_attributes_path_absent_from_isolate(self):
        canonical, path = self.prepare_governance_isolate()
        before = (canonical / path).read_bytes()
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((canonical / path).read_bytes(), before)

    def test_canonical_same_origin_but_different_repository_does_not_attribute(self):
        canonical, path = self.prepare_governance_isolate()
        unrelated = self.root / "unrelated-governance"
        init(unrelated, "https://example.invalid/governance.git")
        commit(unrelated, {"README.md": "unrelated governance\n"})
        self.gov = unrelated
        self.extra_headers = [f"isolated_worktree: {self.gov}", "harness_session_id: own-session",
                              "session_id: own-guard-session"]
        self.assertTrue((canonical / path).is_file())
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_canonical_attribution_does_not_accept_unpublished_own_result(self):
        self.prepare_governance_isolate()
        commit(self.mc, {"session.md": "committed but unpublished session\n"})
        self.assert_refused(self.run_proof(), "текущий результат не совпадает")

    def test_canonical_presence_does_not_change_an_existing_mc_owner(self):
        canonical, _ = self.prepare_governance_isolate()
        (canonical / "session.md").write_text("unrelated canonical governance file\n")
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_canonical_only_unpublished_deliverable_is_refused(self):
        canonical, _ = self.prepare_governance_isolate()
        path = "unpublished-deliverable.md"
        (canonical / path).write_text("own unpublished deliverable\n")
        self.extra_paths.append(path)
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_canonical_runner_requires_foreign_completed_identity(self):
        canonical, path = self.prepare_governance_isolate()
        card = canonical / path
        original = card.read_text()
        cases = [
            ("kind: process-run", "kind: deliverable"),
            ("process_id: quick-close", "process_id: other-process"),
            ("run_id: quick-close-other-session", "run_id: quick-close-different-session"),
            ("id: RUN-quick-close-other-session", "id: wrong-card"),
            ("owner_session_id: foreign-session", "owner_session_id: own-session"),
            ("owner_session_id: foreign-session", "owner_session_id: own-guard-session"),
            ("owner_session_id: foreign-session", "owner_session_id: ''"),
            ("status: completed", "status: waiting"),
            ("current_step: done", "current_step: session-guard-release"),
            ("status: completed", "status: waiting\nstatus: completed"),
        ]
        for expected, invalid in cases:
            with self.subTest(invalid=invalid):
                card.write_text(original.replace(expected, invalid))
                self.assert_refused(self.run_proof(), "путь не найден")
        card.write_text(original)

    def test_canonical_runner_symlink_is_refused(self):
        canonical, path = self.prepare_governance_isolate()
        card = canonical / path
        moved = canonical / "actual-card.md"
        card.rename(moved)
        card.symlink_to(moved)
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_missing_repo_claim_does_not_attribute_unknown_path(self):
        self.claim_name = None
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_unknown_claimed_repo_is_refused(self):
        self.claim_name = "missing-repository"
        self.assert_refused(self.run_proof(), "репозиторий отсутствует или неоднозначен")

    def test_same_name_different_origins_is_refused(self):
        duplicate = self.root / "knowledge-mcp"
        init(duplicate, "https://example.invalid/another-project.git")
        commit(duplicate, {"other.md": "other\n"})
        self.assert_refused(self.run_proof(), "репозиторий отсутствует или неоднозначен")

    def test_unknown_path_is_refused_even_with_valid_repo(self):
        self.extra_paths.append("src/does-not-exist.ts")
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_existing_path_is_attributed_without_fabricating_file_ownership(self):
        # Claim binds the repo identity; known_path attributes the relative
        # path. No requirement to claim someone else's commit for that path.
        commit(self.code, {"src/unclaimed.ts": "unclaimed\n"})
        self.extra_paths.append("src/unclaimed.ts")
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_readme_only_claim_can_identify_existing_code_repository(self):
        self.claim_sha = commit(self.code, {"README.md": "own doc change\n"})
        self.assertEqual(git(self.code, "diff-tree", "--no-commit-id", "--name-only",
                             "-r", self.claim_sha), "README.md")
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_claim_tree_attributes_code_on_a_different_branch(self):
        git(self.code, "checkout", "-q", "--detach", self.code_seed)
        self.assertFalse((self.code / "src/layers/reindex.ts").exists())
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def prepare_historical_path(self):
        path = "migrations/023-observations.sql"
        historical = commit(self.code, {path: "CREATE TABLE observations();\n"})
        git(self.code, "rm", "--", path)
        git(self.code, "commit", "-qm", "remove historical migration")
        self.claim_sha = git(self.code, "rev-parse", "HEAD")
        self.extra_paths.append(path)
        return historical

    def test_historical_deleted_path_requires_its_exact_declared_tree(self):
        historical = self.prepare_historical_path()
        self.extra_claims.append("commit: knowledge-mcp " + historical)
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_undeclared_history_does_not_attribute_deleted_path(self):
        self.prepare_historical_path()
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_multiple_claim_trees_of_same_repo_do_not_count_twice(self):
        self.extra_claims.append("commit: knowledge-mcp " + self.code_sha)
        self.claim_sha = commit(self.code, {"README.md": "second own doc commit\n"})
        git(self.code, "checkout", "-q", "--detach", self.code_seed)
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_claim_commit_is_refused(self):
        self.claim_sha = "1" * 40
        self.assert_refused(self.run_proof(), "проверка Git не выполнена")

    def test_dirty_owned_mc_is_still_refused(self):
        (self.mc / "session.md").write_text("unpublished edit\n")
        self.assert_refused(self.run_proof(), "собственные файлы не закоммичены")

    def test_existing_ambiguous_owners_still_refuse(self):
        commit(self.gov, {"session.md": "ambiguous local session\n"})
        self.assert_refused(self.run_proof(), "принадлежность неоднозначна")

    def test_two_third_repo_claims_for_unknown_path_refuse(self):
        second = self.root / "DS-IT-systems" / "second-code"
        init(second, "https://example.invalid/second-code.git")
        sha = commit(second, {"src/layers/reindex.ts": "second owner\n"})
        self.extra_claims.append("commit: second-code " + sha)
        self.assert_refused(self.run_proof(), "принадлежность неоднозначна")

    def test_two_third_repo_claims_narrow_to_the_one_that_touched_the_path(self):
        # WP-7 Ф173 (2026-09-24): two claimed repos can each carry their own, unrelated
        # file at the same relative path -- second's file predates its claimed commit
        # (an unrelated later change), so only self.code's claim actually touched
        # src/layers/reindex.ts. Unlike the refusal case above (both claims genuinely
        # touch the path), this must resolve unambiguously to self.code.
        second = self.root / "DS-IT-systems" / "second-code"
        init(second, "https://example.invalid/second-code.git")
        commit(second, {"src/layers/reindex.ts": "second repo's own unrelated file\n"})
        unrelated_claim = commit(second, {"README.md": "second repo's own later change\n"})
        self.extra_claims.append("commit: second-code " + unrelated_claim)
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def prepare_coarse_gitignore_collision(self):
        # A bare file claim cannot distinguish independent files with the same
        # common name. Only the code claim actually changed this one.
        commit(self.mc, {".gitignore": "local-session-cache/\n"})
        commit(self.gov, {".gitignore": "local-governance-cache/\n"})
        self.init_root_checkout()
        commit(self.root, {".gitignore": "local-root-cache/\n"})
        self.claim_sha = commit(self.code, {".gitignore": "code-cache/\n"})
        self.extra_paths.append(".gitignore")

    def test_coarse_collision_attributes_only_the_declared_external_owner(self):
        self.prepare_coarse_gitignore_collision()
        # Prove the selected identity matters: the local namesake differs from
        # the published tree and is dirty, but was never a session commit claim.
        (self.mc / ".gitignore").write_text("another-session-unpublished-edit/\n")
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_coarse_collision_does_not_hide_owned_dirty_result(self):
        self.prepare_coarse_gitignore_collision()
        (self.mc / "session.md").write_text("unpublished session edit\n")
        self.assert_refused(self.run_proof(), "собственные файлы не закоммичены")

    def test_coarse_collision_does_not_hide_owned_unpublished_result(self):
        self.prepare_coarse_gitignore_collision()
        commit(self.mc, {"session.md": "unpublished session commit\n"})
        self.assert_refused(self.run_proof(), "текущий результат не совпадает с origin/main")

    def test_coarse_collision_without_a_touched_claim_still_refuses(self):
        self.prepare_coarse_gitignore_collision()
        self.claim_sha = commit(self.code, {"README.md": "unrelated code change\n"})
        self.assert_refused(self.run_proof(), "принадлежность неоднозначна")

    def test_coarse_collision_with_two_touched_external_repos_still_refuses(self):
        self.prepare_coarse_gitignore_collision()
        sha = commit(self.gov, {".gitignore": "claimed-governance-change/\n"})
        self.extra_claims.append("commit: governance " + sha)
        self.assert_refused(self.run_proof(), "принадлежность неоднозначна")

    def test_coarse_collision_with_owned_and_external_claims_still_refuses(self):
        self.prepare_coarse_gitignore_collision()
        sha = commit(self.mc, {".gitignore": "claimed-session-change/\n"})
        self.extra_claims.append("commit: MC-sessions " + sha)
        self.assert_refused(self.run_proof(), "принадлежность неоднозначна")

    def test_snapshot_changed_by_resolver_is_refused(self):
        self.assert_refused(self.run_proof(mutate_during_resolution=True),
                            "scope изменился во время разрешения репозиториев")

    def test_duplicate_same_repository_claims_are_one_owner(self):
        self.extra_claims.append("commit: knowledge-mcp " + self.code_sha)
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def init_root_checkout(self):
        # The fixture root already exists (it holds the other checkouts), so `init` cannot mkdir it.
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.name", "Fixture")
        git(self.root, "config", "user.email", "fixture@example.invalid")
        git(self.root, "config", "core.hooksPath", "/dev/null")
        git(self.root, "remote", "add", "origin", "https://example.invalid/iwe-root.git")

    def prepare_new_path_in_root_checkout(self):
        # WP-484 (21.09): a NEW file published into the root repository from an
        # isolated copy is absent from its lagging canonical checkout (detached
        # here on the seed), so only the declared commit's tree can own it.
        self.init_root_checkout()
        seed = commit(self.root, {"seed-root.md": "seed\n"})
        published = commit(self.root, {"scripts/tests/new-smoke.sh": "echo ok\n"})
        git(self.root, "checkout", "-q", "--detach", seed)
        self.assertFalse((self.root / "scripts/tests/new-smoke.sh").exists())
        self.extra_paths.append("scripts/tests/new-smoke.sh")
        return published

    def test_declared_commit_of_the_root_checkout_attributes_a_new_path(self):
        published = self.prepare_new_path_in_root_checkout()
        self.extra_claims.append("commit: iwe-root " + published)
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_path_of_the_root_checkout_without_declared_commit_is_refused(self):
        self.prepare_new_path_in_root_checkout()
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_root_claim_that_did_not_touch_the_path_does_not_own_it(self):
        # A later commit whose tree merely INHERITS the path is not evidence of delivery
        # (stale or historical commit): the declared commit must add or change it.
        self.init_root_checkout()
        seed = commit(self.root, {"seed-root.md": "seed\n"})
        commit(self.root, {"scripts/tests/new-smoke.sh": "echo ok\n"})
        unrelated = commit(self.root, {"other-root.md": "other\n"})
        git(self.root, "checkout", "-q", "--detach", seed)
        self.extra_paths.append("scripts/tests/new-smoke.sh")
        self.extra_claims.append("commit: iwe-root " + unrelated)
        self.assertIn("scripts/tests/new-smoke.sh", git(self.root, "ls-tree", "-r", "--name-only", unrelated))
        self.assert_refused(self.run_proof(), "путь не найден")

    def test_root_checkout_claim_does_not_add_an_owner_to_an_owned_path(self):
        # README.md is owned by governance; the root claim's tree also holds a
        # README.md, and that must not make the path ambiguous.
        self.init_root_checkout()
        seed = commit(self.root, {"seed-root.md": "seed\n"})
        published = commit(self.root, {"README.md": "root README\n"})
        git(self.root, "checkout", "-q", "--detach", seed)
        self.extra_claims.append("commit: iwe-root " + published)
        self.assertTrue((self.gov / "README.md").is_file())
        self.assertFalse((self.root / "README.md").exists())
        result = self.run_proof()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
