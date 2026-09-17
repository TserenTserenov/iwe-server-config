#!/usr/bin/env python3
"""Exercise shipped close selection and unchanged proof gates in temporary fixtures."""

import hashlib
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import unittest


GUARD = Path(os.environ.get(
    "SESSION_GUARD_UNDER_TEST",
    str(Path(__file__).resolve().parents[1] / "session-guard.sh"),
))
SOURCE = GUARD.read_text()


def function_source(name):
    start = SOURCE.index(name + "() {")
    end = SOURCE.index("\n}\n", start) + 3
    return SOURCE[start:end]


SELECTION_START = SOURCE.index("  HARNESS_SESSION_ID=$(grep", SOURCE.index("  RUNNER_CARD_DIRS=("))
SELECTION_END = SOURCE.index("  # WP-520 Ф4", SELECTION_START)
SELECTION = SOURCE[SELECTION_START:SELECTION_END]


class DeclaredTerminalProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wp484-proof-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(("IWE_", "CLAUDE_", "GIT_")):
                del self.env[key]
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/dev/null",
            "GIT_CONFIG_KEY_1": "init.defaultBranch",
            "GIT_CONFIG_VALUE_1": "main",
        })

    def shell(self, source):
        return subprocess.run(
            ["/bin/bash"], input="set -euo pipefail\n" + source,
            text=True, capture_output=True, cwd=self.root, env=self.env,
        )

    def invoke(self, name, *args):
        return self.shell(function_source(name) + "\n" + name + " " + shlex.join(args))

    def card(self, owner="owner-A", slug="fixture"):
        path = self.root / ("RUN-quick-close-" + slug + ".md")
        path.write_text(
            "---\nprocess_id: quick-close\nrun_id: quick-close-" + slug
            + "\nrequested_slug: " + slug
            + "\nstatus: completed\ncurrent_step: done\nowner_session_id: " + owner
            + "\nresults:\n  gather-session-facts:\n    wp: WP-484\n---\n"
        )
        return path

    def select(self, close_path, cards=(), harness=""):
        sem = self.root / "fixture.open"
        sem.write_text("close_path: " + close_path + "\n" + (
            "harness_session_id: " + harness + "\n" if harness else ""
        ))
        setup = (
            "SEM_FILE=" + shlex.quote(str(sem)) + "\nSLUG=fixture\n"
            + "RUNNER_CARDS=(" + shlex.join(map(str, cards)) + ")\n"
        )
        result = self.shell(function_source("_card_field") + "\n" + setup + SELECTION
                            + '\nprintf "%s\\n" "$RUNNER_OK" "$TERMINAL_PROOF_MODE"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def snapshot(self, card, owner="owner-A", wp="WP-484", slug="fixture"):
        return self.invoke("_terminal_card_snapshot_sha", str(card), "completed", owner, wp, slug)

    def assert_sentinel(self, close_path, cards=(), harness=""):
        reference = "declared-" + close_path + ":fixture"
        self.assertEqual(self.select(close_path, cards, harness), [reference, "sentinel"])
        proof = self.invoke("_terminal_proof_snapshot_sha", "sentinel", reference)
        self.assertEqual(proof.returncode, 0, proof.stderr)
        self.assertRegex(proof.stdout.strip(), r"^[0-9a-f]{64}$")

    def test_peer_without_run(self):
        self.assert_sentinel("peer-session")

    def test_peer_with_foreign_owner_and_suffix(self):
        self.assert_sentinel("peer-session", [self.card("owner-B", "fixture-1")])

    def test_peer_with_matching_run(self):
        self.assert_sentinel("peer-session", [self.card()], "owner-A")

    def test_peer_with_known_harness_and_foreign_run(self):
        self.assert_sentinel("peer-session", [self.card("owner-B")], "owner-A")

    def test_publish_only_with_foreign_run(self):
        self.assert_sentinel("publish-only", [self.card("owner-B", "fixture-1")])

    def test_ordinary_exact_owner(self):
        card = self.card()
        self.assertEqual(self.select("quick-close", [card], "owner-A"), [str(card), "completed"])
        self.assertEqual(self.snapshot(card).returncode, 0)

    def test_ordinary_foreign_owner_filtered(self):
        self.assertEqual(self.select("quick-close", [self.card("owner-B")], "owner-A"), ["", ""])

    def test_ordinary_missing_harness_still_requires_exact_owner(self):
        card = self.card("owner-B")
        self.assertEqual(self.select("quick-close", [card]), [str(card), "completed"])
        self.assertNotEqual(self.snapshot(card).returncode, 0)

    def test_strict_wp_and_slug(self):
        card = self.card()
        self.assertNotEqual(self.snapshot(card, wp="WP-250").returncode, 0)
        self.assertNotEqual(self.snapshot(card, slug="fixture-1").returncode, 0)

    def test_unsafe_snapshot_rejected(self):
        card = self.card()
        link = self.root / "link.md"
        link.symlink_to(card)
        self.assertNotEqual(self.snapshot(link).returncode, 0)
        hardlink = self.root / "hardlink.md"
        hardlink.hardlink_to(card)
        self.assertNotEqual(self.snapshot(card).returncode, 0)

    def test_changed_snapshot_produces_different_digest(self):
        card = self.card()
        before = self.snapshot(card)
        card.write_text(card.read_text() + "Changed after initial proof.\n")
        after = self.snapshot(card)
        self.assertEqual((before.returncode, after.returncode), (0, 0))
        self.assertNotEqual(before.stdout, after.stdout)

    def test_unpublished_head_is_rejected(self):
        origin = self.root / "origin.git"
        repo = self.root / "repo"
        self.git("init", "--bare", "-q", str(origin))
        self.git("init", "-q", str(repo))
        self.git("-C", str(repo), "config", "user.name", "Fixture")
        self.git("-C", str(repo), "config", "user.email", "fixture@example.com")
        self.git("-C", str(repo), "remote", "add", "origin", str(origin))
        artifact = repo / "artifact.txt"
        artifact.write_text("published\n")
        self.git("-C", str(repo), "add", "artifact.txt")
        self.git("-C", str(repo), "commit", "-qm", "published")
        self.git("-C", str(repo), "push", "-q", "origin", "main")
        proof = self.invoke("_repo_head_has_publish_proof", str(repo), "fixture")
        self.assertEqual(proof.returncode, 0, proof.stderr)
        artifact.write_text("not delivered\n")
        self.git("-C", str(repo), "add", "artifact.txt")
        self.git("-C", str(repo), "commit", "-qm", "unpublished")
        proof = self.invoke("_repo_head_has_publish_proof", str(repo), "fixture")
        self.assertNotEqual(proof.returncode, 0)
        self.assertIn("неподтверждённая доставка", proof.stderr)

    def git(self, *args):
        return subprocess.run(
            ["/usr/bin/git", *args], cwd=self.root, env=self.env,
            text=True, capture_output=True, check=True,
        )


TARGET = "_repo_scope_has_publish_proof"


def extract_function(source, name):
    """Let bash distinguish a function end from braces inside a heredoc."""
    start = re.search(r"(?m)^" + re.escape(name) + r"\(\)\s*\{", source)
    if start is None:
        raise AssertionError("Missing candidate function: " + name)
    for end in re.finditer(r"(?m)^\}[ \t]*(?:#.*)?$", source[start.start():]):
        candidate = source[start.start():start.start() + end.end()] + "\n"
        parsed = subprocess.run(
            ["/bin/bash", "-n"], input=candidate, text=True, capture_output=True,
        )
        if parsed.returncode == 0:
            return candidate
    raise AssertionError("Cannot parse candidate function: " + name)


class ScopePublicationProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = GUARD.read_text()
        # Production helpers only. No decision logic is replaced with a stub.
        names = [
            "_unique_record_field", "_owned_semaphore_snapshot_sha",
            "_locked_open_identity", "normalize_remote_url",
            "semaphore_governance_worktree", TARGET,
        ]
        cls.functions = "\n".join(
            extract_function(source, name) for name in names
            if name == TARGET or re.search(r"(?m)^" + re.escape(name) + r"\(\)", source)
        )

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="wp484-scope-case-", dir="/private/tmp")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / "DS-my-strategy"
        self.origin = self.root / "origin.git"
        self.sessions = self.root / "MC-sessions"
        self.sessions.mkdir()
        self.sem = self.root / "codex-fixture-session.open"
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("IWE_", "CLAUDE_", "GIT_"))
        }
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/dev/null",
            "GIT_CONFIG_KEY_1": "init.defaultBranch",
            "GIT_CONFIG_VALUE_1": "main",
            "IWE_ROOT": str(self.root),
            "IWE_GOVERNANCE_REPO": self.repo.name,
            "IWE_SESSIONS_ROOT": str(self.sessions),
        })
        self.git("init", "--bare", "-q", str(self.origin))
        self.git("init", "-q", str(self.repo))
        self.git("-C", str(self.repo), "config", "user.name", "Scope fixture")
        self.git("-C", str(self.repo), "config", "user.email", "fixture@example.com")
        self.git("-C", str(self.repo), "config", "core.filemode", "true")
        self.git("-C", str(self.repo), "remote", "add", "origin", str(self.origin))
        self.write(".gitignore", "owned/ignored.txt\ninbox/open-sessions.log\n")
        self.write("foreign/notes.txt", "foreign baseline\n")
        self.commit("baseline", ".gitignore", "foreign/notes.txt")
        self.write("owned/result.txt", "A published result\n")
        self.own_commit = self.commit("own result", "owned/result.txt")
        self.publish()
        self.files = ["owned/result.txt"]
        self.commits = [self.repo.name + " " + self.own_commit]

    def git(self, *args, check=True):
        return subprocess.run(
            ["/usr/bin/git", *args], cwd=self.root, env=self.env,
            text=True, capture_output=True, check=check, timeout=20,
        )

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def commit(self, message, *paths):
        self.git("-C", str(self.repo), "add", "--", *paths)
        self.git("-C", str(self.repo), "commit", "-qm", message)
        return self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()

    def publish(self):
        self.git("-C", str(self.repo), "push", "-q", "origin", "main")
        self.git("-C", str(self.repo), "fetch", "-q", "origin")
        self.remote = self.git(
            "-C", str(self.repo), "rev-parse", "refs/remotes/origin/main",
        ).stdout.strip()

    def semaphore(self):
        self.sem.write_text(
            "---\nagent: codex\nwp: WP-484\nslug: scope-fixture\n"
            "session_id: fixture-session\nclose_path: peer-session\n"
            "governance_worktree: " + str(self.repo) + "\n"
            "orz_sessions_dir: " + str(self.sessions) + "\n---\n"
            + "".join("file: " + path + "\n" for path in self.files)
            + "".join("commit: " + claim + "\n" for claim in self.commits)
        )

    def state(self):
        return (
            self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout,
            self.git("-C", str(self.repo), "status", "--porcelain=v2", "-z",
                     "--untracked-files=all").stdout,
            self.sem.read_bytes(),
        )

    def proof(self):
        self.semaphore()
        before = self.state()
        setup = {
            "IWE_ROOT": str(self.root), "GOV_REPO": self.repo.name,
            "ORZ_DIR": str(self.sessions), "ORZ_SESSIONS_DIR": str(self.sessions),
            "SEM_FILE": str(self.sem), "SESSION_ID": "fixture-session",
            "AGENT": "codex", "WP": "WP-484", "SLUG": "scope-fixture",
        }
        command = "set -euo pipefail\n" + "\n".join(
            key + "=" + shlex.quote(value) for key, value in setup.items()
        ) + "\n" + self.functions + "\n" + TARGET + " " + shlex.join(
            # own field/other field (WP-484, 16.09, peer-session
            # 2026-09-16-22-wp484-close-mechanism-hard-snapshot): the function
            # was parameterized to serve both the governance and the sessions
            # checkout; this test class exercises the governance role only
            # (every fixture writes a modern semaphore with
            # governance_worktree: set, see semaphore() above), so own field
            # is governance_worktree and other field is orz_sessions_dir.
            # 7th/8th positional: legacy-own / legacy-other repo (WP-484,
            # peer-session 2026-09-14-13). Both empty here -- a modern
            # semaphore never takes the legacy branch, must not be exercised
            # by omission. Cold-review (subagent, same phase) caught this
            # argument count going stale once already when a second
            # positional was added after the first fix -- if another
            # positional is added later, update this call too, not just the
            # bash-side callers.
            [str(self.repo), "governance checkout", str(self.sem), self.remote,
             "governance_worktree", "orz_sessions_dir", "", ""]
        ) + "\n"
        result = subprocess.run(
            ["/bin/bash"], input=command, text=True, capture_output=True,
            cwd=self.root, env=self.env, timeout=30,
        )
        self.assertEqual(self.state(), before, "Proof mutated HEAD/index/worktree/semaphore")
        self.assertNotIn("command not found", result.stderr, result.stderr)
        self.assertNotIn("unbound variable", result.stderr, result.stderr)
        return result

    def assert_accepts(self):
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def assert_refuses(self):
        result = self.proof()
        self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_published_scope_accepts_foreign_unpublished_and_dirty_paths(self):
        self.write("foreign/committed.txt", "not published, other session\n")
        self.commit("foreign unpublished", "foreign/committed.txt")
        self.write("foreign/notes.txt", "dirty other session\n")
        self.write("foreign/untracked.txt", "new other session\n")
        self.write("foreign/staged.txt", "staged other session\n")
        self.git("-C", str(self.repo), "add", "--", "foreign/staged.txt")
        self.assert_accepts()

    def test_own_unpublished_commit_refused(self):
        self.write("owned/result.txt", "unpublished new result\n")
        self.commits.append(self.repo.name + " " + self.commit("own new", "owned/result.txt"))
        self.assert_refuses()

    def test_unpublished_revert_to_historical_remote_blob_refused(self):
        self.write("owned/result.txt", "B published result\n")
        self.commits.append(self.repo.name + " " + self.commit("published B", "owned/result.txt"))
        self.publish()
        self.write("owned/result.txt", "A published result\n")
        self.commits.append(self.repo.name + " " + self.commit("unpublished revert", "owned/result.txt"))
        self.assert_refuses()

    def test_executable_bit_mismatch_refused(self):
        (self.repo / "owned/result.txt").chmod(0o755)
        self.commits.append(self.repo.name + " " + self.commit("unpublished mode", "owned/result.txt"))
        self.assert_refuses()

    def test_symlink_substitution_refused(self):
        path = self.repo / "owned/result.txt"
        path.unlink()
        path.symlink_to("../foreign/notes.txt")
        self.commits.append(self.repo.name + " " + self.commit("unpublished symlink", "owned/result.txt"))
        self.assert_refuses()

    def test_empty_file_claims_refused(self):
        self.files = []
        self.assert_refuses()

    def test_missing_governance_commit_claim_refused(self):
        for claims in ([], ["iwe-root " + self.own_commit]):
            with self.subTest(claims=claims):
                self.commits = claims
                self.assert_refuses()

    def test_malformed_file_claims_refused(self):
        for path in ("../escape", "/absolute", ":(glob)**", "owned/*", "owned/../owned/result.txt"):
            with self.subTest(path=path):
                self.files = ["owned/result.txt", path]
                self.assert_refuses()

    def test_malformed_or_missing_commit_objects_refused(self):
        for claim in ("DS-my-strategy not-a-sha", "DS-my-strategy " + "0" * 40,
                      "DS-my-strategy", "../DS-my-strategy " + self.own_commit):
            with self.subTest(claim=claim):
                self.commits = [claim]
                self.assert_refuses()

    def test_own_unstaged_and_staged_changes_refused(self):
        self.write("owned/result.txt", "not committed\n")
        self.assert_refuses()
        self.git("-C", str(self.repo), "add", "--", "owned/result.txt")
        self.assert_refuses()

    def test_ignored_registered_artifact_refused(self):
        self.write("owned/ignored.txt", "must not silently disappear\n")
        self.files.append("owned/ignored.txt")
        self.assert_refuses()

    def test_claimed_commit_changes_outside_file_registry_refused(self):
        self.write("owned/unregistered.txt", "published but missing from file claims\n")
        self.commits.append(self.repo.name + " " + self.commit("missing file declaration", "owned/unregistered.txt"))
        self.publish()
        self.assert_refuses()

    def test_runtime_log_cannot_supply_the_only_tracked_scope(self):
        self.write("inbox/open-sessions.log", "replaceable runtime projection\n")
        self.files = ["inbox/open-sessions.log"]
        self.assert_refuses()

    def test_exact_runtime_log_with_real_scope_is_allowed(self):
        self.write("inbox/open-sessions.log", "replaceable runtime projection\n")
        self.files.append("inbox/open-sessions.log")
        self.assert_accepts()

    def test_invalid_remote_object_refused(self):
        self.remote = "0" * 40
        self.assert_refuses()

    def test_unknown_registered_result_is_not_silently_another_repo(self):
        self.files.append("owned/missing-result.txt")
        self.assert_refuses()

    def test_assume_unchanged_cannot_hide_unpublished_own_content(self):
        self.git("-C", str(self.repo), "update-index", "--assume-unchanged", "owned/result.txt")
        self.write("owned/result.txt", "unpublished bytes hidden from git status\n")
        self.assert_refuses()

    def test_skip_worktree_cannot_hide_unpublished_own_content(self):
        self.git("-C", str(self.repo), "update-index", "--skip-worktree", "owned/result.txt")
        self.write("owned/result.txt", "unpublished bytes hidden by skip-worktree\n")
        self.assert_refuses()

    def external_artifact(self, repo, relative):
        self.git("init", "-q", str(repo))
        self.git("-C", str(repo), "config", "user.name", "Scope fixture")
        self.git("-C", str(repo), "config", "user.email", "fixture@example.com")
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("belongs to another declared repository\n")
        self.git("-C", str(repo), "add", "--", relative)
        self.git("-C", str(repo), "commit", "-qm", "external artifact")

    def test_known_mixed_repo_file_claims_are_allowed(self):
        self.external_artifact(self.root, "scripts/only-root.sh")
        self.external_artifact(self.sessions, "2026/report.md")
        self.files.extend(["scripts/only-root.sh", "2026/report.md"])
        self.assert_accepts()

    def test_same_bare_path_in_two_repos_is_ambiguous(self):
        self.external_artifact(self.root, "owned/result.txt")
        self.assert_refuses()


COMMIT_TARGET = "_commit_current_tree_has_publish_proof"


class CommitCurrentTreeTests(unittest.TestCase):
    setUp = ScopePublicationProofTests.setUp
    git = ScopePublicationProofTests.git
    write = ScopePublicationProofTests.write
    commit = ScopePublicationProofTests.commit
    publish = ScopePublicationProofTests.publish
    semaphore = ScopePublicationProofTests.semaphore
    state = ScopePublicationProofTests.state

    @classmethod
    def setUpClass(cls):
        cls.functions = extract_function(GUARD.read_text(), COMMIT_TARGET)

    def current_proof(self, commit):
        self.semaphore()
        before = self.state()
        command = "set -euo pipefail\n" + self.functions + "\n" + COMMIT_TARGET + " " + shlex.join(
            [str(self.repo), commit, self.remote]
        ) + "\n"
        result = subprocess.run(
            ["/bin/bash"], input=command, text=True, capture_output=True,
            cwd=self.root, env=self.env, timeout=30,
        )
        self.assertEqual(self.state(), before, "Proof changed repository or semaphore")
        self.assertNotIn("command not found", result.stderr, result.stderr)
        self.assertNotIn("unbound variable", result.stderr, result.stderr)
        return result

    def accepted(self, commit):
        result = self.current_proof(commit)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def refused(self, commit):
        result = self.current_proof(commit)
        self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)

    def publish_current_branch(self):
        self.git("-C", str(self.repo), "push", "-q", "origin", "HEAD:refs/heads/main")
        self.git("-C", str(self.repo), "fetch", "-q", "origin")
        self.remote = self.git(
            "-C", str(self.repo), "rev-parse", "refs/remotes/origin/main",
        ).stdout.strip()

    def test_imported_already_published_content_accepts_exact_current_tree(self):
        base = self.own_commit
        self.write("owned/result.txt", "A published result\nPreviously published addition\n")
        imported = self.commit("remote addition", "owned/result.txt")
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "-b", "source", base)
        final = "A published result\nPreviously published addition\nOur new addition\n"
        self.write("owned/result.txt", final)
        source = self.commit("import plus our new addition", "owned/result.txt")
        self.git("-C", str(self.repo), "checkout", "-q", "-b", "publisher", imported)
        self.write("owned/result.txt", final)
        self.commit("publisher applies remaining addition", "owned/result.txt")
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "source")
        cherry = self.git("-C", str(self.repo), "cherry", self.remote, source, source + "^1")
        self.assertEqual(cherry.stdout.strip(), "+ " + source)
        self.accepted(source)

    def test_unpublished_content_refused(self):
        self.write("owned/result.txt", "not published\n")
        source = self.commit("not published", "owned/result.txt")
        self.refused(source)

    def test_historical_match_does_not_prove_current_delivery(self):
        self.write("owned/result.txt", "B published result\n")
        self.commit("published B", "owned/result.txt")
        self.publish_current_branch()
        self.write("owned/result.txt", "A published result\n")
        source = self.commit("unpublished return to A", "owned/result.txt")
        self.refused(source)

    def test_mode_and_object_type_mismatch_refused(self):
        path = self.repo / "owned/result.txt"
        path.chmod(0o755)
        executable = self.commit("unpublished executable mode", "owned/result.txt")
        with self.subTest(change="mode"):
            self.refused(executable)
        path.unlink()
        path.symlink_to("../foreign/notes.txt")
        linked = self.commit("unpublished link", "owned/result.txt")
        with self.subTest(change="type"):
            self.refused(linked)

    def test_partial_delivery_across_multiple_paths_refused(self):
        base = self.own_commit
        self.write("owned/result.txt", "updated result\n")
        self.write("owned/second.txt", "must also be published\n")
        source = self.commit("two outputs", "owned/result.txt", "owned/second.txt")
        self.git("-C", str(self.repo), "checkout", "-q", "-b", "publisher", base)
        self.write("owned/result.txt", "updated result\n")
        self.commit("only one output delivered", "owned/result.txt")
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", source)
        self.refused(source)

    def test_empty_merge_and_invalid_commit_refused(self):
        self.git("-C", str(self.repo), "commit", "--allow-empty", "-qm", "empty")
        empty = self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()
        with self.subTest(change="empty"):
            self.refused(empty)
        with self.subTest(change="invalid"):
            self.refused("0" * 40)
        self.git("-C", str(self.repo), "checkout", "-q", "-b", "side", self.own_commit)
        self.write("foreign/side.txt", "side\n")
        self.commit("side", "foreign/side.txt")
        self.git("-C", str(self.repo), "checkout", "-q", "main")
        self.write("foreign/main.txt", "main\n")
        self.commit("main", "foreign/main.txt")
        self.git("-C", str(self.repo), "merge", "--no-ff", "-qm", "merge", "side")
        merge = self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()
        self.publish_current_branch()
        with self.subTest(change="merge"):
            self.refused(merge)


SUPERSESSION_TARGET = "_commit_claim_supersession_has_publish_proof"
CLAIMS_TARGET = "_claimed_commits_have_publish_proof"


class ClaimedSupersessionTests(unittest.TestCase):
    """Use real local Git histories and the shipped proof/caller, never gate state."""

    git = ScopePublicationProofTests.git
    write = ScopePublicationProofTests.write
    commit = ScopePublicationProofTests.commit
    publish = ScopePublicationProofTests.publish
    semaphore = ScopePublicationProofTests.semaphore
    publish_current_branch = CommitCurrentTreeTests.publish_current_branch

    old_path = "current/plan.md"
    archive_path = "archive/plan.md"
    own_line = "| owned-result | exact bytes |\n"
    header = "| Work | Result |\n| --- | --- |\n"

    @classmethod
    def setUpClass(cls):
        source = GUARD.read_text()
        cls.functions = "\n".join(extract_function(source, name) for name in (
            COMMIT_TARGET, SUPERSESSION_TARGET, CLAIMS_TARGET,
        ))

    def setUp(self):
        ScopePublicationProofTests.setUp(self)
        self.env.update(GIT_ALLOW_PROTOCOL="file", GIT_OPTIONAL_LOCKS="0",
                        GIT_NO_REPLACE_OBJECTS="1")
        self.prefix = "# Fixture plan\n\nUnique insertion boundary\n\n"
        self.suffix = "Existing unique row\n" + "".join(
            "Unchanged context line %02d\n" % number for number in range(24)
        )
        self.base_text = self.prefix + self.suffix
        self.seed_base(self.base_text)

    def seed_base(self, text, *extra_paths):
        self.base_text = text
        self.write(self.old_path, text)
        self.base = self.commit("base before either claim", self.old_path, *extra_paths)
        self.publish()

    def make_source(self, text=None, extra_files=None):
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        self.write(self.old_path, text if text is not None else self.prefix + self.own_line + self.suffix)
        for path, content in (extra_files or {}).items():
            self.write(path, content)
        self.source = self.commit("old private claim", self.old_path, *(extra_files or {}))
        self.files = [self.old_path, self.archive_path, *(extra_files or {})]

    def stage_candidate(self, text=None, destination=None):
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        destination = destination or self.archive_path
        self.write(destination, text if text is not None else self.prefix + self.header + self.own_line + self.suffix)
        if destination != self.old_path:
            (self.repo / self.old_path).unlink()
        self.candidate_paths = list(dict.fromkeys([self.old_path, destination]))

    def finish_candidate(self, *extra_paths):
        self.candidate = self.commit("already published successor", *self.candidate_paths, *extra_paths)
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.source)
        self.commits = [self.repo.name + " " + sha for sha in (self.source, self.candidate)]

    def pair(self, source_text=None, published_text=None, destination=None):
        self.make_source(source_text)
        self.stage_candidate(published_text, destination)
        self.finish_candidate()

    def immutable_state(self):
        git_dir = Path(self.git("-C", str(self.repo), "rev-parse", "--absolute-git-dir").stdout.strip())
        worktree = {}
        for path in self.repo.rglob("*"):
            relative = path.relative_to(self.repo)
            if relative.parts[0] == ".git":
                continue
            if path.is_symlink():
                worktree[str(relative)] = ("link", os.readlink(path))
            elif path.is_file():
                worktree[str(relative)] = ("file", stat.S_IMODE(path.stat().st_mode), path.read_bytes())
        objects = {
            str(path.relative_to(git_dir / "objects")): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (git_dir / "objects").rglob("*") if path.is_file()
        }
        return {
            "head": self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout,
            "refs": self.git("-C", str(self.repo), "show-ref").stdout,
            "index": (git_dir / "index").read_bytes(),
            "worktree": worktree, "objects": objects, "semaphore": self.sem.read_bytes(),
            "remote": self.git("--git-dir=" + str(self.origin), "rev-parse", "refs/heads/main").stdout,
        }

    def proof(self, *, caller=False):
        self.semaphore()
        before = self.immutable_state()
        arguments = [str(self.sem)] if caller else [
            str(self.repo), self.source, self.remote, str(self.sem), self.repo.name,
        ]
        target = CLAIMS_TARGET if caller else SUPERSESSION_TARGET
        result = subprocess.run(
            ["/bin/bash"], input="set -euo pipefail\n" + self.functions + "\n" + target + " " + shlex.join(arguments),
            text=True, capture_output=True, cwd=self.root, env=self.env, timeout=30,
        )
        self.assertEqual(self.immutable_state(), before, "Proof mutated source, index, objects, refs or claims")
        for unexpected in ("command not found", "unbound variable", "Traceback (most recent call last)"):
            self.assertNotIn(unexpected, result.stderr, result.stderr)
        return result

    def accepts(self, *, caller=False):
        result = self.proof(caller=caller)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("claimed changes preserved", result.stderr)

    def refuses(self, *, caller=False):
        result = self.proof(caller=caller)
        self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_clean_absorption_accepts_exact_contained_renamed_result(self):
        final = self.prefix + self.own_line + self.suffix + "Unrelated later addition\n"
        self.pair(published_text=final)
        self.accepts()

    def test_archived_header_insertion_passes_direct_and_full_claim_caller(self):
        self.pair()
        self.accepts()
        self.accepts(caller=True)

    def test_missing_owned_line_refused_by_helper_and_full_caller(self):
        self.pair(published_text=self.prefix + self.header + self.suffix)
        self.refuses()
        self.refuses(caller=True)

    def test_conflicting_mode_change_refused(self):
        self.make_source()
        self.stage_candidate()
        (self.repo / self.archive_path).chmod(0o755)
        self.finish_candidate()
        self.refuses()

    def test_symlink_substitution_refused(self):
        self.make_source()
        self.stage_candidate()
        target = self.repo / self.archive_path
        target.unlink()
        target.symlink_to("../foreign/notes.txt")
        self.finish_candidate()
        self.refuses()

    def test_copy_without_removing_old_path_is_not_accepted_as_rename(self):
        self.make_source()
        self.stage_candidate()
        self.write(self.old_path, self.base_text)
        self.finish_candidate()
        self.refuses()

    def test_loss_in_nonconflicting_owned_path_cannot_hide_behind_plan_fallback(self):
        self.make_source(extra_files={"owned/second.txt": "must also survive\n"})
        self.stage_candidate()
        self.finish_candidate()
        self.refuses()

    def test_successor_must_already_be_claimed_in_the_same_exact_repository(self):
        self.pair()
        for claims in ([self.repo.name + " " + self.source],
                       [self.repo.name + " " + self.source, "MC-sessions " + self.candidate],
                       [self.repo.name + " " + self.candidate]):
            with self.subTest(claims=claims):
                self.commits = claims
                self.refuses()

    def test_patch_equivalent_but_oid_unpublished_successor_refused(self):
        self.pair()
        tree = self.git("-C", str(self.repo), "rev-parse", self.candidate + "^{tree}").stdout.strip()
        unpublished = self.git("-C", str(self.repo), "commit-tree", tree, "-p", self.base,
                               "-m", "different unpublished successor identity").stdout.strip()
        patch = self.git("-C", str(self.repo), "cherry", self.remote, unpublished, unpublished + "^1")
        self.assertEqual(patch.stdout.strip(), "- " + unpublished)
        self.commits = [self.repo.name + " " + sha for sha in (self.source, unpublished)]
        self.refuses()
        self.refuses(caller=True)

    def test_unrelated_successor_base_refused(self):
        self.pair()
        tree = self.git("-C", str(self.repo), "rev-parse", self.base + "^{tree}").stdout.strip()
        unrelated = self.git("-C", str(self.repo), "commit-tree", tree, "-m", "unrelated root").stdout.strip()
        tree = self.git("-C", str(self.repo), "rev-parse", self.candidate + "^{tree}").stdout.strip()
        candidate = self.git("-C", str(self.repo), "commit-tree", tree, "-p", unrelated,
                             "-m", "same result with unrelated base").stdout.strip()
        self.remote = candidate  # A synthetic pinned remote graph; no fixture refs are rewritten.
        self.commits = [self.repo.name + " " + sha for sha in (self.source, candidate)]
        self.refuses()

    def test_reverted_descendant_does_not_use_source_itself_as_merge_base(self):
        self.make_source()
        self.write(self.old_path, self.base_text)
        reverted = self.commit("revert the claimed insertion", self.old_path)
        self.publish_current_branch()
        self.commits = [self.repo.name + " " + sha for sha in (self.source, reverted)]
        self.refuses()

    def test_custom_merge_driver_cannot_approve_loss_or_run_side_effects(self):
        self.write(".gitattributes", "*.md merge=fixture-eat-change\n")
        self.seed_base(self.base_text, ".gitattributes")
        marker = self.root / "unexpected-driver-call"
        driver = "printf called > " + shlex.quote(str(marker)) + "; cp %B %A"
        self.git("-C", str(self.repo), "config", "merge.fixture-eat-change.driver", driver)
        self.pair(published_text=self.prefix + self.header + "| foreign-result | different bytes |\n" + self.suffix)
        self.refuses()
        self.assertFalse(marker.exists(), "Read-only proof invoked the repository's merge driver")

    def test_tracked_union_attribute_cannot_approve_non_insertion_source_change(self):
        self.write(".gitattributes", "*.md merge=union\n")
        self.seed_base(self.base_text, ".gitattributes")
        remainder = self.suffix.split("\n", 1)[1]
        self.pair(self.prefix + self.own_line + remainder,
                  self.prefix + self.header + self.own_line + remainder)
        # Fixture sanity: selecting the tracked union driver changes this merge
        # from a content conflict into clean absorption, despite the source
        # replacing a base line. Local policy must not widen the insertion rule.
        control = subprocess.run(
            ["/usr/bin/git", "-C", str(self.repo), "merge-tree", "--write-tree",
             "--merge-base=" + self.base, self.source, self.candidate],
            env={**self.env, "GIT_ATTR_SOURCE": self.base}, cwd=self.root,
            text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(control.returncode, 0, control.stderr + control.stdout)
        expected = self.git("-C", str(self.repo), "rev-parse", self.candidate + "^{tree}").stdout.strip()
        self.assertEqual(control.stdout.splitlines()[0], expected)
        self.refuses()

    def test_duplicate_anchors_reject_sequence_matcher_false_position(self):
        self.seed_base("A\nA\nA\nA\n")
        self.pair("A\nA\nOWN\nA\nA\n", "A\nB\nA\nA\nOWN\nA\n", self.old_path)
        self.refuses()

    def test_replacement_of_source_content_is_not_insertion_only(self):
        self.pair(self.prefix + "Replaced base row\n" + self.suffix.split("\n", 1)[1],
                  self.prefix + self.header + "Another replacement\n" + self.suffix.split("\n", 1)[1])
        self.refuses()

    def test_preexisting_duplicate_does_not_prove_the_claimed_insertion_position(self):
        self.seed_base(self.base_text + self.own_line)
        self.pair(self.prefix + self.own_line + self.suffix + self.own_line,
                  self.prefix + self.header + self.suffix + self.own_line)
        self.refuses()

    def test_wrong_position_does_not_prove_the_claimed_insertion(self):
        final = self.prefix + self.header + self.suffix + self.own_line
        self.pair(published_text=final)
        self.refuses()

    def test_insertion_at_file_boundary_has_no_two_sided_proof(self):
        self.pair(self.own_line + self.base_text, self.header + self.own_line + self.base_text)
        self.refuses()

    def test_repeated_owned_block_inside_target_insertion_is_ambiguous(self):
        self.pair(published_text=self.prefix + self.header + self.own_line * 2 + self.suffix)
        self.refuses()

    def test_empty_merge_and_root_successors_are_not_linear_nonempty_proof(self):
        self.pair()
        tree = self.git("-C", str(self.repo), "rev-parse", self.candidate + "^{tree}").stdout.strip()
        variants = {
            "root": [], "empty": ["-p", self.candidate],
            "merge": ["-p", self.candidate, "-p", self.source],
        }
        for name, parents in variants.items():
            with self.subTest(topology=name):
                candidate = self.git("-C", str(self.repo), "commit-tree", tree, *parents,
                                     "-m", "invalid " + name).stdout.strip()
                self.remote = candidate
                self.commits = [self.repo.name + " " + sha for sha in (self.source, candidate)]
                self.refuses()

    def test_excessive_frozen_claim_count_refused(self):
        self.pair()
        self.commits = [self.repo.name + " " + self.source] + [self.repo.name + " " + self.candidate] * 32
        self.refuses()

    def test_excessive_changed_source_path_count_refused(self):
        extra = {"owned/file-%02d.txt" % number: "required material\n" for number in range(64)}
        self.make_source(extra_files=extra)
        self.stage_candidate()
        for path, content in extra.items():
            self.write(path, content)
        self.finish_candidate(*extra)
        self.refuses()

    def test_oversized_conflict_blob_refused(self):
        self.seed_base(self.prefix + "Z" * 262145 + "\n" + self.suffix)
        old = self.prefix + self.own_line + "Z" * 262145 + "\n" + self.suffix
        published = self.prefix + self.header + self.own_line + "Z" * 262145 + "\n" + self.suffix
        self.pair(old, published)
        self.refuses()


if __name__ == "__main__":
    unittest.main(verbosity=2)
