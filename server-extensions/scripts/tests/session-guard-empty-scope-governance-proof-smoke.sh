#!/usr/bin/env bash
# WP-484: exercise the real governance decision and publication proofs against
# temporary repositories. A missing path/commit is never proof of empty scope.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$ROOT_DIR" <<'PY_TEST'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(sys.argv.pop()).resolve()
GUARD = (SOURCE / "scripts/session-guard.sh").read_text()


def extract_function(name):
    """Extract production code, skipping braces inside its here-documents."""
    lines = GUARD.splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "() {"))
    delimiter = None
    for end in range(start + 1, len(lines)):
        line = lines[end]
        if delimiter:
            if line.strip() == delimiter:
                delimiter = None
            continue
        match = re.search(r"(?<!<)<<-?\s*['\"]?([A-Za-z_][A-Za-z_0-9]*)", line)
        if match:
            delimiter = match[1]
        elif line == "}\n":
            return "".join(lines[start:end + 1])
    raise AssertionError("unterminated production function: " + name)


FUNCTIONS = "\n".join(extract_function(name) for name in (
    "normalize_remote_url", "_resolve_repo_checkout", "_publication_receipt_tool",
    "semaphore_governance_worktree", "is_append_safe_session_path",
    "_untracked_matches_published", "session_scope_dirty_paths", "resolve_orz_sessions_dir",
    "_receipt_checkout_has_publish_proof", "_repo_scope_has_publish_proof",
    "_repo_head_has_publish_proof", "_claimed_commits_have_publish_proof",
    "_code_branch_claim_has_publish_proof", "_commit_current_tree_has_publish_proof",
    "_commit_claim_supersession_has_publish_proof", "_peer_metadata_claim_has_publish_proof",
    "_claimed_source_chain_has_publish_proof", "_commit_automerge_has_publish_proof",
))
START = GUARD.index("  # Classify every claim by repository identity.")
END = GUARD.index('\n  if [ -n "$isolated_worktree" ]; then', START)
DECISION = GUARD[START:END]
DIRTY_START = GUARD.index('  SCOPE_DIRTY=$(session_scope_dirty_paths "$SEM_FILE")')
DIRTY_END = GUARD.index("\n  # Quick Close", DIRTY_START)
DIRTY_GATE = GUARD[DIRTY_START:DIRTY_END]
# The actual close caller executes this gate before invoking delivery.
assert GUARD.index("\n  _close_delivery_and_transition\n", DIRTY_START) > DIRTY_END
SESSIONS_START = GUARD.index('  if [ "${MACHINE_CLOSE_MODE:-0}" != "1" ]; then',
                            GUARD.index("_close_delivery_and_transition() {"))
SESSIONS_END = GUARD.index("\n  # Resume begins", SESSIONS_START)
SESSIONS_DELIVERY = GUARD[SESSIONS_START:SESSIONS_END]


class GovernanceDeliveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="governance-scope-proof-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0",
                        IWE_ROOT=str(self.root), IWE_GOVERNANCE_REPO="DS-strategy",
                        PYTHONDONTWRITEBYTECODE="1")
        scripts = self.root / "scripts"
        (scripts / "lib").mkdir(parents=True)
        for name in ("session_receipt_scope.py", "publication_receipt.py"):
            shutil.copyfile(SOURCE / "scripts/lib" / name, scripts / "lib" / name)
        (scripts / "proof-functions.sh").write_text(FUNCTIONS)
        self.runner = scripts / "decision.sh"
        self.runner.write_text(
            'set -euo pipefail\n. "$IWE_ROOT/scripts/proof-functions.sh"\n'
            'fail() { echo "$1" >&2; exit "$2"; }\n'
            'GOV_REPO=DS-strategy\ngovernance_repo="$IWE_ROOT/$GOV_REPO"\n'
            'SEM_FILE="$IWE_ROOT/session.open"\nisolated_worktree=""\n'
            'legacy_semaphore_canonical="$governance_repo"\n'
            'legacy_semaphore_sessions_dir="$IWE_ROOT/MC-sessions"\n'
            + DECISION + '\nprintf "DELIVERY_ACCEPTED\\n"\n'
        )
        self.scope_runner = scripts / "scope-then-decision.sh"
        self.scope_runner.write_text(self.runner.read_text().replace(
            DECISION,
            'ORZ_DIR="$IWE_ROOT/MC-sessions"\nORZ_SESSIONS_DIR="$ORZ_DIR"\n'
            + DIRTY_GATE + '\nprintf "SCOPE_CLEAN\\n"\n'
            + SESSIONS_DELIVERY + '\nprintf "SESSIONS_DELIVERY_ACCEPTED\\n"\n' + DECISION,
            1,
        ))
        self.gov, self.gov_remote = self.repo("DS-strategy")
        self.sessions, self.sessions_remote = self.repo("MC-sessions")
        for repo in (self.gov, self.sessions):
            (repo / "shared.md").write_text("published same-name file\n")
            (repo / "deleted.md").write_text("published original\n")
        self.orz = "2026-10/session.md"
        (self.sessions / "2026-10").mkdir()
        (self.sessions / self.orz).write_text("published session report\n")
        (self.gov / ".gitignore").write_text("inbox/open-sessions.log\n")
        self.commit(self.gov, ["shared.md", "deleted.md", ".gitignore"], "governance seed", publish=True)
        self.external = self.commit(self.sessions, ["shared.md", "deleted.md", self.orz],
                                    "session delivery", publish=True)
        # Foreign history is genuinely divergent: both the bare remote and
        # this shared checkout advance independently from the common base.
        publisher = self.root / "remote-writer"
        self.command("git", "clone", str(self.gov_remote), str(publisher))
        self.identity(publisher)
        (publisher / "remote-only.md").write_text("foreign remote history\n")
        self.commit(publisher, ["remote-only.md"], "remote advance", publish=True)
        (self.gov / "foreign-committed.md").write_text("foreign unpublished history\n")
        self.commit(self.gov, ["foreign-committed.md"], "foreign local advance")
        self.git(self.gov, "fetch", "origin", "main")
        (self.gov / "foreign-committed.md").write_text("foreign uncommitted edit\n")
        (self.gov / "foreign-untracked.md").write_text("foreign untracked output\n")
        (self.gov / "inbox").mkdir()
        (self.gov / "inbox/open-sessions.log").write_text("runtime projection\n")
        self.sem = self.root / "session.open"
        self.sem.write_text(
            "---\nagent: codex\nsession_id: fixture\nharness_session_id: native-fixture\n"
            "host: fixture-host\nwp: WP-484\nslug: fixture\nclose_path: unknown\n"
            f"governance_worktree: {self.gov}\norz_sessions_dir: {self.sessions}\n"
            f"orz_file: {self.orz}\n---\nfile: {self.orz}\nfile: inbox/open-sessions.log\n"
            + self.claim(self.sessions, "shared.md")
            + f"commit: MC-sessions {self.external}\n"
        )
        (self.root / "session.open.lease").write_text("lease must survive\n")
        (self.root / "current-codex.ptr").write_text(str(self.sem) + "\n")

    def command(self, *args):
        return subprocess.run(args, env=self.env, check=True, capture_output=True, text=True)

    def git(self, repo, *args):
        return self.command("git", "-C", str(repo), *args).stdout.strip()

    def identity(self, repo):
        self.git(repo, "config", "user.name", "Fixture")
        self.git(repo, "config", "user.email", "fixture@example.invalid")

    def repo(self, name):
        remote = self.root / (name + ".git")
        repo = self.root / name
        self.command("git", "init", "--bare", "--initial-branch=main", str(remote))
        self.command("git", "clone", str(remote), str(repo))
        self.identity(repo)
        return repo, remote

    def commit(self, repo, paths, message, publish=False):
        self.git(repo, "add", "--", *paths)
        self.git(repo, "commit", "-m", message)
        if publish:
            self.git(repo, "push", "origin", "HEAD:main")
            self.git(repo, "fetch", "origin", "main")
        return self.git(repo, "rev-parse", "HEAD")

    @staticmethod
    def claim(repo, path):
        return (f"file: {path}\nfile_v2: "
                + json.dumps({"repo": str(repo / ".git"), "path": path}) + "\n")

    def append(self, text):
        self.sem.write_text(self.sem.read_text() + text)

    def state(self):
        result = {}
        for repo in (self.gov, self.sessions):
            result[str(repo)] = (
                self.git(repo, "rev-parse", "HEAD"), self.git(repo, "show-ref"),
                (repo / ".git/index").read_bytes(),
                {str(path.relative_to(repo)): path.read_bytes()
                 for path in repo.rglob("*") if path.is_file()
                 and ".git" not in path.relative_to(repo).parts},
            )
        for remote in (self.gov_remote, self.sessions_remote):
            result[str(remote)] = self.git(remote, "show-ref")
        for name in ("session.open", "session.open.lease", "current-codex.ptr"):
            result[name] = (self.root / name).read_bytes()
        return result

    def verdict(self, accepted, runner=None):
        before = self.state()
        result = subprocess.run(["bash", str(runner or self.runner)], env=self.env,
                                capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        self.assertNotIn("command not found", output)
        self.assertNotIn("Traceback (most recent call last)", output)
        self.assertNotIn("No such file or directory", output)
        self.assertEqual(result.returncode, 0 if accepted else 7, output)
        self.assertEqual("DELIVERY_ACCEPTED" in result.stdout, accepted, output)
        self.assertEqual(self.state(), before, "proof changed refs, index, files, or session markers")
        return output

    def test_external_scope_ignores_foreign_history_and_dirty_files(self):
        output = self.verdict(True)
        self.assertIn("scope относятся к другим репозиториям", output)

    def test_own_deleted_file_still_blocks(self):
        (self.gov / "deleted.md").unlink()
        self.append(self.claim(self.gov, "deleted.md"))
        self.assertIn("governance delivery не подтверждена", self.verdict(False))

    def test_own_same_name_file_still_blocks(self):
        (self.gov / "shared.md").write_text("own unpublished change\n")
        self.append(self.claim(self.gov, "shared.md"))
        self.verdict(False)

    def test_unqualified_nonexistent_file_still_blocks(self):
        self.append("file: absent-everywhere.md\n")
        self.verdict(False)

    def test_unqualified_same_name_file_still_blocks(self):
        self.append("file: shared.md\n")
        self.verdict(False)

    def test_own_unpublished_commit_still_blocks(self):
        (self.gov / "own.md").write_text("own unpublished committed output\n")
        source = self.commit(self.gov, ["own.md"], "own change")
        self.append(self.claim(self.gov, "own.md") + f"commit: DS-strategy {source}\n")
        self.verdict(False)

    def test_empty_journal_still_blocks(self):
        self.sem.write_text("\n".join(line for line in self.sem.read_text().splitlines()
                                     if not line.startswith(("file:", "file_v2:", "commit:"))) + "\n")
        self.verdict(False)

    def published_payload(self):
        path = "export/payload.json"
        payload = self.sessions / path
        payload.parent.mkdir()
        payload.write_text('{"published": true}\n')
        source = self.commit(self.sessions, [path], "published payload", publish=True)
        self.append(self.claim(self.sessions, path) + f"commit: MC-sessions {source}\n")
        return payload

    def test_clean_sessions_payload_passes_actual_scope_and_sessions_gates(self):
        self.published_payload()
        output = self.verdict(True, self.scope_runner)
        self.assertIn("SCOPE_CLEAN", output)
        self.assertIn("SESSIONS_DELIVERY_ACCEPTED", output)
        self.assertIn("scope относятся к другим репозиториям", output)

    def test_dirty_sessions_payload_blocks_before_empty_governance_proof(self):
        payload = self.published_payload()
        payload.write_text('{"published": false, "own_new_work": true}\n')
        output = self.verdict(False, self.scope_runner)
        self.assertIn("export/payload.json", output)
        self.assertIn("Сначала зафиксируй и отправь", output)
        self.assertNotIn("SCOPE_CLEAN", output)
        self.assertNotIn("SESSIONS_DELIVERY_ACCEPTED", output)
        self.assertNotIn("scope относятся к другим репозиториям", output)

    def test_untracked_sessions_payload_blocks_with_published_session_commit(self):
        path = "export/payload.json"
        payload = self.sessions / path
        payload.parent.mkdir()
        payload.write_text('{"untracked_own_work": true}\n')
        self.append(self.claim(self.sessions, path))
        output = self.verdict(False, self.scope_runner)
        self.assertIn("?? export/payload.json", output)
        self.assertIn("Сначала зафиксируй и отправь", output)
        self.assertNotIn("SCOPE_CLEAN", output)
        self.assertNotIn("scope относятся к другим репозиториям", output)

    def test_external_unpublished_commit_is_not_excused(self):
        (self.sessions / "own-unpublished.md").write_text("session output not delivered\n")
        source = self.commit(self.sessions, ["own-unpublished.md"], "unpublished session output")
        self.append(self.claim(self.sessions, "own-unpublished.md") + f"commit: MC-sessions {source}\n")
        output = self.verdict(False)
        self.assertIn("session-owned commits", output)
        self.assertIn("scope относятся к другим репозиториям", output)


unittest.main(verbosity=2)
PY_TEST
