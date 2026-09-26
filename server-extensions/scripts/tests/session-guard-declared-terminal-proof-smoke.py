#!/usr/bin/env python3
"""Exercise shipped close selection and unchanged proof gates in temporary fixtures."""

import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import unittest

import yaml


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
SELECTION_END = SOURCE.index(
    '  if [ -z "$RUNNER_OK" ]; then\n    # WP-537 (19.08', SELECTION_START,
)
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

    def owner_status(self, owner, files):
        sessions = self.root / ".iwe-runtime/sessions"
        sessions.mkdir(parents=True, mode=0o700)
        for name, content in files.items():
            (sessions / name).write_text(content)
        env = dict(self.env)
        env.update(IWE_ROOT=str(self.root), IWE_GOVERNANCE_REPO="DS-strategy",
                   IWE_SCHEDULED_ADMISSION_WAIT_SEC="2")
        result = subprocess.run(
            ["/bin/bash", str(GUARD), "owner-status", "--owner-session-id", owner],
            text=True, capture_output=True, cwd=self.root, env=env, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_owner_status_present_outranks_unrelated_unknown_sibling(self):
        active = ("---\nagent: fixture\nsession_id: guard-A\n"
                  "harness_session_id: owner-A\n---\n")
        status = self.owner_status("owner-A", {
            "fixture-guard-A.open": active,
            "foreign.open.lease.orphaned-peer-audit": "unclassified projection\n",
        })
        self.assertEqual(status["state"], "present")
        self.assertEqual(status["proof"], "admission-locked-snapshot/v1")

    def test_owner_status_unknown_sibling_still_blocks_absence(self):
        status = self.owner_status("owner-A", {
            "foreign.open.lease.orphaned-peer-audit": "unclassified projection\n",
        })
        self.assertEqual(status["state"], "unknown")
        self.assertIn("unknown semaphore sibling state", status["reason"])

    def test_heartbeat_preserves_declared_close_path(self):
        semaphore = self.root / "fixture-session-A.open"
        for route in ("peer-session", "publish-only", "machine-publish-only", "pipeline",
                      "unknown", "quick-close", "day-close", "none", "custom-route"):
            with self.subTest(route=route):
                before = ("---\nagent: fixture\nsession_id: session-A\n"
                          f"close_path: {route}\n---\nfile: result.md\n")
                semaphore.write_text(before)
                result = self.invoke("_append_heartbeat_atomic", str(semaphore), "fixture",
                                     "session-A", "1234", "2026-09-25T19:00:00Z")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(semaphore.read_text(), before +
                                 "heartbeat_at: 2026-09-25T19:00:00Z\nheartbeat_pid: 1234\n")

    def test_heartbeat_refuses_close_transition_or_ambiguous_route(self):
        semaphore = self.root / "fixture-session-A.open"
        for fields in ("close_delivery_state: PREPARED\n", "recovery_state: pending\n",
                       "close_path: peer-session\nclose_path: pipeline\n",
                       "close_path: \n", "close_path: bad route\n"):
            with self.subTest(fields=fields):
                before = "---\nagent: fixture\nsession_id: session-A\n" + fields + "---\n"
                semaphore.write_text(before)
                result = self.invoke("_append_heartbeat_atomic", str(semaphore), "fixture",
                                     "session-A", "1234", "2026-09-25T19:00:00Z")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(semaphore.read_text(), before)

    def card(self, owner="owner-A", slug="fixture", *, run_suffix="", wp="WP-484",
             status="completed", step="done", results=None):
        run_id = "quick-close-" + slug + run_suffix
        path = self.root / ("RUN-" + run_id + ".md")
        card_results = {"gather-session-facts": {"wp": wp}}
        card_results.update(results or {})
        doc = dict(process_id="quick-close", run_id=run_id, requested_slug=slug,
                   status=status, current_step=step, owner_session_id=owner,
                   results=card_results)
        path.write_text("---\n" + yaml.safe_dump(doc, sort_keys=False) + "---\n")
        return path

    def select(self, close_path, cards=(), harness="", *, force_no_reflection="", card_dirs=None):
        sem = self.root / "fixture.open"
        sem.write_text("close_path: " + close_path + "\nsession_id: owner-A\n" + (
            "harness_session_id: " + harness + "\n" if harness else ""
        ))
        setup = (
            "SEM_FILE=" + shlex.quote(str(sem)) + "\nSLUG=fixture\nWP=WP-484\n"
            + "AGENT=fixture\nSESSION_ID=owner-A\nGOV_REPO=absent-governance\n"
            + "IWE_ROOT=" + shlex.quote(str(self.root)) + "\n"
            + "FORCE_NO_REFLECTION=" + shlex.quote(force_no_reflection) + "\n"
            + "RUNNER_CARDS=(" + shlex.join(map(str, cards)) + ")\n"
            + "RUNNER_CARD_DIRS=(" + shlex.join(map(str, card_dirs or [self.root])) + ")\n"
        )
        helpers = ["_card_field", "_quick_close_card_wp", "_unique_record_field",
                   "_terminal_card_snapshot_sha"]
        script = "\n".join(function_source(name) for name in helpers)
        script += '\nfail() { printf "%s\\n" "$1" >&2; exit "$2"; }\n'
        result = self.shell(script + setup + SELECTION
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
        self.assertEqual(self.select("quick-close", [card]), ["", ""])
        self.assertNotEqual(self.snapshot(card).returncode, 0)

    def test_invalid_completed_candidate_does_not_hide_exact_release(self):
        valid = self.card(status="running", step="session-guard-release",
                          results={"verify-r23": {"verdict": "pass"}})
        invalid = [
            self.card(slug="fixture-earlier"),
            self.card(run_suffix="-wrong-wp", wp="WP-7"),
            self.card(run_suffix="-wrong-step", step="commit-push"),
        ]
        for candidate in invalid:
            with self.subTest(candidate=candidate.name):
                self.assertEqual(self.select("quick-close", [candidate, valid], "owner-A"),
                                 [str(valid), "release-step"])

    def test_invalid_completed_candidate_does_not_hide_exact_completed(self):
        valid = self.card()
        invalid = self.card(run_suffix="-wrong-wp", wp="WP-7")
        self.assertEqual(self.select("quick-close", [invalid, valid], "owner-A"),
                         [str(valid), "completed"])

    def test_release_requires_its_own_positive_verdict_before_selection(self):
        valid = self.card(status="running", step="session-guard-release",
                          results={"verify-r23": {"verdict": "pass"}})
        for verdict in (None, "fail", ""):
            with self.subTest(verdict=verdict):
                invalid = self.card(run_suffix="-invalid", status="running",
                                    step="session-guard-release",
                                    results={"unrelated": {"verdict": "pass"},
                                             "verify-r23": {"verdict": verdict}})
                self.assertEqual(self.select("quick-close", [invalid, valid], "owner-A"),
                                 [str(valid), "release-step"])
                self.assertEqual(self.select("quick-close", [invalid], "owner-A"), ["", ""])

    def test_blocked_release_remains_nonterminal(self):
        card = self.card(status="waiting", step="blocked-session-release",
                         results={"verify-r23": {"verdict": "pass"},
                                  "session-guard-release": {"status": "skipped"}})
        self.assertEqual(self.select("quick-close", [card], "owner-A"), ["", ""])

    def test_cancelled_archive_selection_skips_foreign_wp(self):
        results = {"commit-push": {"all_pushed": True}}
        valid = self.card(status="cancelled", step="wp-archive-run", results=results)
        invalid = self.card(run_suffix="-wrong-wp", wp="WP-7", status="cancelled",
                            step="wp-archive-run", results=results)
        self.assertEqual(self.select("quick-close", [invalid, valid], "owner-A"),
                         [str(valid), "archive-cancelled"])

    def test_explicit_witness_selection_skips_foreign_wp(self):
        results = {"commit-push": {"all_pushed": True}}
        valid = self.card(status="waiting", step="blocked-witness-unavailable", results=results)
        invalid = self.card(run_suffix="-wrong-wp", wp="WP-7", status="waiting",
                            step="blocked-witness-unavailable", results=results)
        self.assertEqual(self.select("quick-close", [invalid, valid], "owner-A",
                                     force_no_reflection="fixture approval"),
                         [str(valid), "blocked-witness"])

    def test_marker_selection_skips_invalid_checkout_copy(self):
        earlier = self.root / "earlier"
        later = self.root / "later"
        earlier.mkdir()
        later.mkdir()
        card = self.card(slug="other")
        valid = later / card.name
        card.rename(valid)
        invalid = earlier / valid.name
        invalid.write_text(valid.read_text().replace("current_step: done", "current_step: commit-push"))
        marker = self.root / ".iwe-runtime/quick-close-slug-satisfied/quick-close-fixture.satisfied_by"
        marker.parent.mkdir(parents=True)
        marker.write_text("quick-close-other")
        self.assertEqual(self.select("quick-close", harness="owner-A", card_dirs=[earlier, later]),
                         [str(valid), "marker-completed"])

    def test_owner_selection_skips_invalid_completed_card(self):
        self.card(slug="another-a", step="commit-push")
        valid = self.card(slug="another-b")
        self.assertEqual(self.select("quick-close", harness="owner-A"),
                         [str(valid), "owner-completed"])

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

    def test_running_release_card_is_not_unsaved_work(self):
        repo = self.root / "repo"
        self.git("init", "-q", str(repo))
        cards = repo / "inbox/agent/tasks"
        cards.mkdir(parents=True)
        card = cards / "RUN-quick-close-fixture.md"
        relative = str(card.relative_to(repo))
        semaphore = self.root / "fixture.open"
        semaphore.write_text(
            "---\nagent: fixture\nsession_id: owner-A\nwp: WP-484\nslug: fixture\n---\n"
            + "file: " + relative + "\nfile: artifact.txt\n"
        )
        source = self.card().read_text().replace(
            "status: completed\ncurrent_step: done",
            "status: running\ncurrent_step: session-guard-release",
        ).replace("\n---\n", "\n  verify-r23:\n    verdict: pass\n---\n")
        helpers = ["_unique_record_field", "_terminal_card_snapshot_sha",
                   "is_append_safe_session_path", "_untracked_matches_published",
                   "session_scope_dirty_paths"]
        script = "\n".join(function_source(name) for name in helpers)
        script += "\nsemaphore_governance_worktree() { printf '%s\\n' " + shlex.quote(str(repo)) + "; }\n"
        script += "ORZ_DIR=" + shlex.quote(str(repo)) + "\n"
        script += "session_scope_dirty_paths " + shlex.quote(str(semaphore))
        card.write_text(source)
        result = self.shell(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "", "own validated release card must not deadlock close")
        (repo / "artifact.txt").write_text("unsaved work\n")
        result = self.shell(script)
        self.assertIn("artifact.txt", result.stdout)
        self.assertNotIn(relative, result.stdout)
        for original, replacement in (
            ("owner-A", "owner-B"), ("verdict: pass", "verdict: fail"),
            ("wp: WP-484", "wp: WP-583"), ("requested_slug: fixture", "requested_slug: other"),
            ("status: running", "status: waiting"),
            ("current_step: session-guard-release", "current_step: commit-push"),
        ):
            with self.subTest(replacement=replacement):
                card.write_text(source.replace(original, replacement))
                self.assertIn(relative, self.shell(script).stdout)

    def test_release_retry_requires_current_owned_audited_runner_card(self):
        import yaml

        card = self.root / "RUN-quick-close-fixture.md"
        semaphore = self.root / "fixture.open"
        semaphore.write_text("harness_session_id: owner-A\nwp: WP-484\nslug: fixture\n")
        audit_root = self.root / ".iwe-runtime/run-card-audit"
        audit_root.mkdir(parents=True)
        audit = audit_root / "quick-close-fixture.jsonl"
        body = ("\n# Карточка запуска: quick-close\n\n"
                "Автоматически обновляется `process-runner.py`. Не редактировать руками -- "
                "карточка производная, source-of-truth = `~/.iwe/gate-decisions.jsonl` "
                "и сам раннер (DP.SC.054 инвариант 3).\n")
        helpers = ["_unique_record_field", "_terminal_card_snapshot_sha", "_runner_release_retry_snapshot_sha"]
        script = "\n".join(function_source(name) for name in helpers)
        script += "\nIWE_ROOT=" + shlex.quote(str(self.root))
        script += "\n_runner_release_retry_snapshot_sha " + shlex.join([str(semaphore), str(card)])
        for variant in ("valid", "owner", "wp", "slug", "waiting", "failed_verdict",
                        "unpublished", "no_previous_release", "body", "missing_audit",
                        "wrong_audit_hash", "wrong_audit_path", "symlink_audit"):
            with self.subTest(variant=variant):
                doc = dict(kind="process-run", process_id="quick-close", run_id="quick-close-fixture",
                           requested_slug="fixture", owner_session_id="owner-A", status="running",
                           current_step="session-guard-release",
                           results={"gather-session-facts": {"wp": "WP-484"},
                                    "verify-r23": {"verdict": "pass"}, "commit-push": {"all_pushed": True}},
                           history=[{"step": "session-guard-release", "type": "reflex"}])
                if variant in ("owner", "slug", "waiting"):
                    key = {"owner": "owner_session_id", "slug": "requested_slug", "waiting": "status"}[variant]
                    doc[key] = "different"
                if variant == "wp":
                    doc["results"]["gather-session-facts"]["wp"] = "WP-1"
                if variant == "failed_verdict":
                    doc["results"]["verify-r23"]["verdict"] = "fail"
                if variant == "unpublished":
                    doc["results"]["commit-push"]["all_pushed"] = False
                if variant == "no_previous_release":
                    doc["history"] = []
                card.write_text("---\n" + yaml.safe_dump(doc, allow_unicode=True) + "---\n"
                                + ("changed\n" if variant == "body" else body))
                if audit.is_symlink() or audit.exists():
                    audit.unlink()
                event = dict(actor="process-runner", event="written", process_id="quick-close",
                             run_id="quick-close-fixture", status="running", card_path=str(card),
                             sha256=hashlib.sha256(card.read_bytes()).hexdigest())
                if variant == "wrong_audit_hash":
                    event["sha256"] = "0" * 64
                if variant == "wrong_audit_path":
                    event["card_path"] = str(self.root / "other.md")
                if variant != "missing_audit":
                    audit.write_text(json.dumps(event) + "\n")
                if variant == "symlink_audit":
                    moved = audit.with_suffix(".saved")
                    audit.rename(moved)
                    audit.symlink_to(moved)
                before = semaphore.read_bytes()
                result = self.shell(script)
                self.assertEqual(result.returncode == 0, variant == "valid", result.stderr)
                self.assertEqual(semaphore.read_bytes(), before)
                if variant == "valid":
                    expected = hashlib.sha256(b"file\0" + str(card).encode() + b"\0" + card.read_bytes()).hexdigest()
                    self.assertEqual(result.stdout.strip(), expected)

    def test_audited_retry_cannot_mask_changed_prepared_source(self):
        import yaml

        repo = self.root / "repo"
        self.git("init", "-q", str(repo))
        self.git("-C", str(repo), "config", "user.name", "Fixture")
        self.git("-C", str(repo), "config", "user.email", "fixture@example.com")
        self.git("-C", str(repo), "remote", "add", "origin", "https://example.com/fixture.git")
        artifact = repo / "artifact.txt"
        artifact.write_text("base\n")
        self.git("-C", str(repo), "add", "artifact.txt")
        self.git("-C", str(repo), "commit", "-qm", "base")
        base = self.git("-C", str(repo), "rev-parse", "HEAD").stdout.strip()
        artifact.write_text("own result\n")
        self.git("-C", str(repo), "commit", "-qam", "own result")
        head = self.git("-C", str(repo), "rev-parse", "HEAD").stdout.strip()
        card = self.root / "RUN-quick-close-fixture.md"
        doc = dict(kind="process-run", process_id="quick-close", run_id="quick-close-fixture",
                   requested_slug="fixture", owner_session_id="owner-A", status="running",
                   current_step="session-guard-release",
                   results={"gather-session-facts": {"wp": "WP-484"},
                            "verify-r23": {"verdict": "pass"}, "commit-push": {"all_pushed": True}},
                   history=[])
        body = ("\n# Карточка запуска: quick-close\n\n"
                "Автоматически обновляется `process-runner.py`. Не редактировать руками -- "
                "карточка производная, source-of-truth = `~/.iwe/gate-decisions.jsonl` "
                "и сам раннер (DP.SC.054 инвариант 3).\n")
        def write_card():
            card.write_text("---\n" + yaml.safe_dump(doc, allow_unicode=True) + "---\n" + body)
        write_card()
        original_terminal = hashlib.sha256(b"file\0" + str(card).encode() + b"\0" + card.read_bytes()).hexdigest()
        semaphore = self.root / "fixture.open"
        fields = dict(harness_session_id="owner-A", wp="WP-484", slug="fixture",
                      close_delivery_source_head=head, close_delivery_common_dir=str(repo / ".git"),
                      close_delivery_source_status_sha256=hashlib.sha256(b"status-v2\0ignored\0").hexdigest(),
                      close_delivery_source_base=base, close_delivery_source_commits=json.dumps([head], separators=(",", ":")),
                      close_delivery_claimed_commits="[]", close_delivery_terminal_kind="file",
                      close_delivery_terminal_reference=str(card), close_delivery_terminal_sha256=original_terminal,
                      close_delivery_origin="example.com/fixture", close_delivery_target_ref="refs/heads/main")
        semaphore.write_text("".join(key + ": " + value + "\n" for key, value in fields.items()))
        before = semaphore.read_bytes()
        helpers = ["_unique_record_field", "normalize_remote_url", "_worktree_clean_status_sha",
                   "_isolated_source_commits_json", "_session_commit_claims_json", "_terminal_proof_snapshot_sha",
                   "_terminal_card_snapshot_sha", "_runner_release_retry_snapshot_sha", "_prepared_source_snapshot_matches"]
        script = "\n".join(function_source(name) for name in helpers)
        script += "\nIWE_ROOT=" + shlex.quote(str(self.root))
        script += "\n_prepared_source_snapshot_matches " + shlex.join([str(semaphore), str(repo)])
        self.assertEqual(self.shell(script).returncode, 0)
        doc["history"].append({"step": "session-guard-release", "type": "reflex"})
        write_card()
        self.assertNotEqual(self.shell(script).returncode, 0, "unaudited change must fail")
        audit_root = self.root / ".iwe-runtime/run-card-audit"
        audit_root.mkdir(parents=True)
        event = dict(actor="process-runner", event="written", process_id="quick-close",
                     run_id="quick-close-fixture", status="running", card_path=str(card),
                     sha256=hashlib.sha256(card.read_bytes()).hexdigest())
        (audit_root / "quick-close-fixture.jsonl").write_text(json.dumps(event) + "\n")
        result = self.shell(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact.write_text("unsaved change\n")
        self.assertNotEqual(self.shell(script).returncode, 0, "dirty product must fail")
        self.git("-C", str(repo), "commit", "-qam", "different source")
        self.assertNotEqual(self.shell(script).returncode, 0, "changed HEAD must fail")
        self.assertEqual(semaphore.read_bytes(), before)

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

    def test_two_worktrees_of_one_external_repo_are_one_owner(self):
        self.external_artifact(self.root, "scripts/only-root.sh")
        self.sessions = self.root / "root-worktree"
        self.git("-C", str(self.root), "worktree", "add", "--detach", str(self.sessions))
        self.files.append("scripts/only-root.sh")
        self.assert_accepts()


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
            COMMIT_TARGET, SUPERSESSION_TARGET, "_commit_automerge_has_publish_proof", "_peer_metadata_claim_has_publish_proof",
            "_claimed_source_chain_has_publish_proof", "_code_branch_claim_has_publish_proof",
            "normalize_remote_url", "_resolve_repo_checkout", CLAIMS_TARGET,
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


class PeerMetadataPublicationTests(unittest.TestCase):
    git = ScopePublicationProofTests.git
    write = ScopePublicationProofTests.write
    commit = ScopePublicationProofTests.commit
    publish = ScopePublicationProofTests.publish
    publish_current_branch = CommitCurrentTreeTests.publish_current_branch
    immutable_state = ClaimedSupersessionTests.immutable_state
    target = "_peer_metadata_claim_has_publish_proof"

    def setUp(self):
        self.make_pair()

    def make_pair(self, transform=None, final_peer="Real peer reply\n"):
        ScopePublicationProofTests.setUp(self)
        self.env.update(GIT_ALLOW_PROTOCOL="file", GIT_OPTIONAL_LOCKS="0")
        self.base = self.remote
        self.slug = "2026-09-20-02-session"
        self.folder = "2026-09/20/" + self.slug + "/"
        self.meta = self.folder + "meta.yaml"
        self.report = self.folder + "report.md"
        self.draft = self.folder + "report-draft.md"
        self.transcript = self.folder + "01-peer.md"
        self.original = (
            "session_id: " + self.slug + "\ndate: '2026-09-20'\n"
            "start_time: '2026-09-20T11:00:30Z'\nend_time: ''\nwp: WP-484\n"
            "status: agreed\nresult_path: report-draft.md\n"
            "publication_status: awaiting_explicit_main_approval\n"
            "writer_agent: codex\npeer: [claude]\nturns_count: 4\n"
        )
        self.final = self.original.replace("end_time: ''", "end_time: '2026-09-20T11:39:58Z'")
        self.final = self.final.replace("status: agreed", "status: completed")
        self.final = self.final.replace("result_path: report-draft.md", "result_path: report.md")
        self.final = self.final.replace("awaiting_explicit_main_approval", "runner-managed")
        self.final += (
            "closure_run_id: quick-close-" + self.slug + "\n"
            "closure_guard_session_id: fixture-session\npublication_target: main\n"
            "publication_method: runner-publication-recovery\n"
            "pilot_reflection: рефлексии нет\nmain_publication_approved: true\n"
        )
        if transform:
            self.final = transform(self.final)
        self.write(self.meta, self.original)
        self.write(self.draft, "Original framing retained\n")
        self.write(self.transcript, "Real peer reply\n")
        self.source = self.commit("peer session", self.meta, self.draft, self.transcript)
        self.write(self.meta, self.final)
        self.write(self.report, "Final report\n")
        self.write(self.transcript, final_peer)
        self.successor = self.commit("finalize peer metadata", self.meta, self.report, self.transcript)
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        for path, content in ((self.meta, self.final), (self.draft, "Original framing retained\n"),
                              (self.transcript, final_peer), (self.report, "Final report\n")):
            self.write(path, content)
        self.published = self.commit("publish complete final packet", self.meta, self.draft,
                                     self.transcript, self.report)
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.successor)
        self.files = [self.meta, self.draft, self.transcript, self.report]
        self.claims = [self.source, self.successor, self.published]

    def proof(self, caller=False):
        self.sem.write_text(
            "---\nagent: codex\nwp: WP-484\nslug: " + self.slug
            + "\nsession_id: fixture-session\norz_sessions_dir: " + str(self.repo)
            + "\n---\n" + "".join("file: " + path + "\n" for path in self.files)
            + "".join("commit: " + self.repo.name + " " + sha + "\n" for sha in self.claims)
        )
        before = self.immutable_state()
        function_names = [self.target]
        if caller:
            function_names += [COMMIT_TARGET, SUPERSESSION_TARGET, "_commit_automerge_has_publish_proof",
                               "_claimed_source_chain_has_publish_proof", "_code_branch_claim_has_publish_proof",
                               "normalize_remote_url",
                               "_resolve_repo_checkout", CLAIMS_TARGET]
        source = "\n".join(extract_function(GUARD.read_text(), name) for name in function_names)
        target = CLAIMS_TARGET if caller else self.target
        arguments = ([str(self.sem)] if caller else
                     [str(self.repo), self.source, self.remote, str(self.sem), self.repo.name])
        result = subprocess.run(
            ["/bin/bash"], input=source + "\n" + target + " " + shlex.join(arguments),
            text=True, capture_output=True, cwd=self.root, env=self.env, timeout=30,
        )
        self.assertEqual(self.immutable_state(), before)
        return result

    def test_exact_claimed_lifecycle_update_is_published(self):
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_lifecycle_update_passes_full_claim_gate(self):
        result = self.proof(caller=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unclaimed_local_successor_is_refused(self):
        self.claims.remove(self.successor)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_unclaimed_published_snapshot_is_refused(self):
        self.claims.remove(self.published)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_dirty_registered_file_is_refused(self):
        self.write(self.transcript, "Changed peer reply\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_unregistered_report_is_refused(self):
        self.files.remove(self.report)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_immutable_metadata_change_is_refused(self):
        self.make_pair(lambda text: text.replace("turns_count: 4", "turns_count: 99"))
        self.assertNotEqual(self.proof().returncode, 0)

    def test_published_peer_reply_replacement_is_refused(self):
        self.make_pair(final_peer="Invented peer reply\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_unknown_lifecycle_key_is_refused(self):
        self.make_pair(lambda text: text + "trust_me: true\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_duplicate_key_is_refused(self):
        self.make_pair(lambda text: text + "turns_count: 99\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_wrong_guard_binding_is_refused(self):
        self.make_pair(lambda text: text.replace("fixture-session", "other-session"))
        self.assertNotEqual(self.proof().returncode, 0)

    def test_invalid_completion_time_is_refused(self):
        self.make_pair(lambda text: text.replace("11:39:58", "10:39:58"))
        self.assertNotEqual(self.proof().returncode, 0)

    def test_index_flags_cannot_hide_peer_file_change(self):
        self.git("-C", str(self.repo), "update-index", "--assume-unchanged", self.transcript)
        self.write(self.transcript, "Hidden replacement\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_changed_current_main_does_not_use_historical_packet(self):
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.published)
        self.write(self.transcript, "New remote content\n")
        self.commit("remote changed after packet", self.transcript)
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.successor)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_core_filemode_cannot_hide_mode_change(self):
        self.git("-C", str(self.repo), "config", "core.filemode", "false")
        (self.repo / self.transcript).chmod(0o755)
        self.assertNotEqual(self.proof().returncode, 0)


class PreparedDeliveryRetryTests(unittest.TestCase):
    git = ScopePublicationProofTests.git
    write = ScopePublicationProofTests.write
    commit = ScopePublicationProofTests.commit
    publish = ScopePublicationProofTests.publish
    publish_current_branch = CommitCurrentTreeTests.publish_current_branch

    def setUp(self):
        self.make_fixture()

    def make_fixture(self, include_second=True, first_content="Final first result\n", shared_variant=None):
        ScopePublicationProofTests.setUp(self)
        self.env.update(GIT_ALLOW_PROTOCOL="file", GIT_OPTIONAL_LOCKS="0")
        self.env.pop("IWE_SESSION_GUARD_ANCHORED_FALLBACK", None)
        self.base = self.remote
        shared_base = "first: old\nkeep1\nkeep2\nkeep3\nother: old\n"
        if shared_variant:
            self.write("shared.txt", shared_base)
            self.base = self.commit("shared base", "shared.txt")
            self.publish_current_branch()
        self.write("owned/result.txt", "Final first result\n")
        first_paths = ["owned/result.txt"]
        if shared_variant:
            self.write("shared.txt", shared_base.replace("first: old", "first: ours"))
            first_paths.append("shared.txt")
        first = self.commit("first prepared change", *first_paths)
        self.write("owned/second.txt", "Final second result\n")
        second = self.commit("second prepared change", "owned/second.txt")
        self.source_head = second
        self.source_commits = [first, second]
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        self.write("owned/result.txt", first_content)
        changed = ["owned/result.txt"]
        if shared_variant:
            shared = shared_base.replace("first: old", "first: ours").replace("other: old", "other: theirs")
            if shared_variant == "concurrent_lost_own":
                shared = shared.replace("first: ours", "first: old")
            if shared_variant == "concurrent_conflict":
                shared = shared.replace("first: ours", "first: conflict")
            if shared_variant == "concurrent_binary":
                shared += "\0"
            self.write("shared.txt", shared)
            if shared_variant == "concurrent_mode":
                (self.repo / "shared.txt").chmod(0o755)
            changed.append("shared.txt")
        if include_second:
            self.write("owned/second.txt", "Final second result\n")
            changed.append("owned/second.txt")
        self.published = self.commit("publish final prepared packet", *changed)
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.source_head)
        self.sem.write_text(
            "close_delivery_source_base: " + self.base
            + "\nclose_delivery_source_head: " + self.source_head
            + "\nclose_delivery_source_commits: " + json.dumps(self.source_commits) + "\n"
        )
        self.replay_log = self.root / "replay.log"
        self.replay = self.root / "isolate-push-fixture.sh"
        self.replay.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "$REPLAY_LOG"\nexit 73\n')
        self.replay.chmod(0o755)
        self.env["REPLAY_LOG"] = str(self.replay_log)
        source = GUARD.read_text()
        self.functions = "\n".join(extract_function(source, name) for name in (
            "_unique_record_field", "_prepared_source_set_has_publish_proof", "_publish_prepared_source",
        ))

    def deliver(self):
        before = self.sem.read_bytes()
        head = self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout
        status = self.git("-C", str(self.repo), "status", "--porcelain").stdout
        result = subprocess.run(
            ["/bin/bash"], input="set -euo pipefail\n" + self.functions
            + "\n_publish_prepared_source " + shlex.join([str(self.sem), str(self.repo), str(self.replay)]),
            text=True, capture_output=True, cwd=self.root, env=self.env, timeout=30,
        )
        self.assertEqual(self.sem.read_bytes(), before)
        self.assertEqual(self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git("-C", str(self.repo), "status", "--porcelain").stdout, status)
        return result

    def test_already_published_whole_snapshot_skips_replay_twice(self):
        self.git("-C", str(self.repo), "update-ref", "refs/remotes/origin/main", self.base)
        for _ in range(2):
            result = self.deliver()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.replay_log.exists())
        self.assertEqual(self.git("-C", str(self.repo), "rev-parse", "origin/main").stdout.strip(), self.published)

    def test_missing_second_commit_result_does_not_skip_replay(self):
        self.make_fixture(include_second=False)
        self.assertEqual(self.deliver().returncode, 73)
        self.assertTrue(self.replay_log.exists())

    def test_modified_prepared_path_does_not_skip_replay(self):
        self.make_fixture(first_content="A different remote result\n")
        self.assertEqual(self.deliver().returncode, 73)
        self.assertTrue(self.replay_log.exists())

    def test_fetch_failure_neither_trusts_cache_nor_replays(self):
        self.git("-C", str(self.repo), "remote", "set-url", "origin", str(self.root / "absent.git"))
        self.assertNotEqual(self.deliver().returncode, 0)
        self.assertFalse(self.replay_log.exists())

    def publish_rewritten_commits(self, count):
        self.git("-C", str(self.origin), "update-ref", "refs/heads/main", self.base)
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        self.write("other-session.txt", "Independent publication\n")
        self.commit("independent publication", "other-session.txt")
        for commit in self.source_commits[:count]:
            self.git("-C", str(self.repo), "cherry-pick", commit)
        self.write("owned/result.txt", "A later legitimate revision\n")
        self.published = self.commit("later revision", "owned/result.txt")
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.source_head)

    def test_rewritten_published_sequence_survives_later_remote_edit(self):
        self.publish_rewritten_commits(2)
        for _ in range(2):
            result = self.deliver()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.replay_log.exists())

    def test_partial_rewritten_publication_replays_only_missing_commit(self):
        self.publish_rewritten_commits(1)
        result = self.deliver()
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.replay_log.read_text().splitlines(),
                         [str(self.repo), "main", "--exact-commit", self.source_commits[1]])

    def test_unpublished_empty_commit_is_not_patch_delivery(self):
        self.git("-C", str(self.repo), "commit", "--allow-empty", "-m", "metadata only")
        empty = self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()
        self.sem.write_text(
            "close_delivery_source_base: " + self.source_head
            + "\nclose_delivery_source_head: " + empty
            + "\nclose_delivery_source_commits: " + json.dumps([empty]) + "\n"
        )
        self.assertEqual(self.deliver().returncode, 73)
        self.assertIn(empty, self.replay_log.read_text())

    def test_only_superseded_foreign_reaper_snapshots_skip_replay(self):
        import copy
        import yaml

        for variant in ("completed", "cancelled", "concurrent", "concurrent_lost_own",
                        "concurrent_conflict", "concurrent_mode", "concurrent_binary", "own", "wrong_slug", "lost_history",
                        "lost_results", "changed_body", "product_path", "running",
                        "manual_cancel", "duplicate_key"):
            with self.subTest(variant=variant):
                self.make_fixture(shared_variant=variant if variant.startswith("concurrent") else None)
                path = "inbox/agent/tasks/RUN-quick-close-foreign.md"
                if variant == "product_path":
                    path = "owned/runtime-looking.md"
                source = dict(id="RUN-quick-close-foreign", kind="process-run", process_id="quick-close",
                              run_id="quick-close-foreign", requested_slug="foreign",
                              owner_session_id="foreign-owner", status="cancelled",
                              current_step="commit-push", cancel_reason="auto_reaped_orphan",
                              history=[{"step": "gather", "at": "2026-09-20T10:00:00Z"}],
                              results={"gather": {"wp": "WP-1"}})
                if variant == "own":
                    source["owner_session_id"] = "own-owner"
                if variant == "manual_cancel":
                    source["cancel_reason"] = "pilot_cancelled"
                target = copy.deepcopy(source)
                target.pop("cancel_reason")
                target.update(status="completed", current_step="done")
                target["history"].append({"step": "release", "at": "2026-09-20T11:00:00Z"})
                target["results"]["release"] = {"status": "released"}
                if variant in ("cancelled", "running"):
                    target["status"] = variant
                if variant == "wrong_slug":
                    target["requested_slug"] = "different"
                if variant == "lost_history":
                    target["history"] = target["history"][1:]
                if variant == "lost_results":
                    del target["results"]["gather"]
                body = "\n# Derived runtime card\n"
                source_text = "---\n" + yaml.safe_dump(source) + "---\n" + body
                self.write(path, source_text)
                self.source_head = self.commit("stale reaper cancellation", path)
                self.source_commits.append(self.source_head)
                self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.published)
                target_text = "---\n" + yaml.safe_dump(target)
                if variant == "duplicate_key":
                    target_text += "status: completed\n"
                self.write(path, target_text + "---\n" + ("Different authored body\n" if variant == "changed_body" else body))
                self.published = self.commit("authoritative completed lifecycle", path)
                self.publish_current_branch()
                self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.source_head)
                self.sem.write_text(
                    "slug: own\nsession_id: guard-own\nharness_session_id: own-owner\n"
                    + "close_delivery_source_base: " + self.base
                    + "\nclose_delivery_source_head: " + self.source_head
                    + "\nclose_delivery_source_commits: " + json.dumps(self.source_commits) + "\n")
                result = self.deliver()
                accepted = variant in ("completed", "cancelled", "concurrent")
                self.assertEqual(result.returncode, 0 if accepted else 73, result.stderr)
                self.assertEqual(self.replay_log.exists(), not accepted)


class ClaimedSourceChainPublicationTests(unittest.TestCase):
    git = ScopePublicationProofTests.git
    write = ScopePublicationProofTests.write
    commit = ScopePublicationProofTests.commit
    publish = ScopePublicationProofTests.publish
    publish_current_branch = CommitCurrentTreeTests.publish_current_branch
    immutable_state = ClaimedSupersessionTests.immutable_state
    target = "_claimed_source_chain_has_publish_proof"

    def setUp(self):
        ScopePublicationProofTests.setUp(self)
        self.env.update(GIT_ALLOW_PROTOCOL="file", GIT_OPTIONAL_LOCKS="0")
        self.base = self.remote
        self.report = "2026-09/19/2026-09-19-06-wp579/report.md"
        self.meta = "2026-09/19/2026-09-19-06-wp579/meta.yaml"
        self.transcript = "2026-09/19/2026-09-19-06-wp579/01-peer.md"
        self.files = [self.report, self.meta, self.transcript]
        self.write(self.report, "Session closed.\n")
        self.write(self.meta, "guard_close_status: closed\n")
        self.write(self.transcript, "Actual unchanged reply\n")
        self.source = self.commit("initial packet", *self.files)
        self.write(self.meta, "guard_close_status: pending\n")
        self.middle = self.commit("correct own metadata", self.meta)
        self.write(self.report, "Session not yet closed.\nExplanation appended.\n")
        self.final = self.commit("correct own report", self.report)
        packet = {path: (self.repo / path).read_text() for path in self.files}
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        for path, content in packet.items():
            self.write(path, content)
        self.published = self.commit("publish final packet", *self.files)
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.final)
        self.claims = [self.source, self.middle, self.final, self.published]
        self.frozen_override = None
        self.omit_freeze = False

    def proof(self, caller=False):
        rows = [self.repo.name + " " + sha for sha in self.claims]
        self.sem.write_text(
            "---\nagent: codex\nwp: WP-579\nslug: wp579\nsession_id: fixture-session\n"
            "close_path: peer-session\norz_sessions_dir: " + str(self.repo) + "\n---\n"
            + "".join("file: " + path + "\n" for path in self.files)
            + "".join("commit: " + row + "\n" for row in rows)
            + ("" if self.omit_freeze else "close_delivery_claimed_commits: "
               + json.dumps(self.frozen_override if self.frozen_override is not None else sorted(rows)) + "\n")
        )
        before = self.immutable_state()
        names = [self.target]
        if caller:
            names += [COMMIT_TARGET, SUPERSESSION_TARGET, "_commit_automerge_has_publish_proof", "_peer_metadata_claim_has_publish_proof",
                      "_code_branch_claim_has_publish_proof",
                      "normalize_remote_url", "_resolve_repo_checkout", CLAIMS_TARGET]
        functions = "\n".join(extract_function(GUARD.read_text(), name) for name in names)
        target = CLAIMS_TARGET if caller else self.target
        args = [str(self.sem)] if caller else [
            str(self.repo), self.source, self.remote, str(self.sem), self.repo.name,
        ]
        result = subprocess.run(["/bin/bash"], input=functions + "\n" + target + " " + shlex.join(args),
                                text=True, capture_output=True, cwd=self.root, env=self.env, timeout=30)
        self.assertEqual(self.immutable_state(), before, "Proof modified repository or frozen claims")
        for error in ("command not found", "Traceback (most recent call last)"):
            self.assertNotIn(error, result.stderr)
        return result

    def test_explicit_report_corrections_pass_helper_and_full_caller(self):
        for caller in (False, True):
            result = self.proof(caller)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("frozen source chain published exactly", result.stderr)

    def test_foreign_head_with_exact_untracked_published_packet(self):
        packet = {path: (self.repo / path).read_bytes() for path in self.files}
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        for path, content in packet.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr)
        exclude = self.repo / ".git/info/exclude"
        original_exclude = exclude.read_text()
        exclude.write_text(original_exclude + "\n" + self.report + "\n")
        self.assertNotEqual(self.proof().returncode, 0, "Ignored packet must not count as untracked")
        exclude.write_text(original_exclude)
        self.write(self.report, "Unpublished correction\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_every_intermediate_commit_must_be_frozen(self):
        self.claims.remove(self.middle)
        self.assertNotEqual(self.proof().returncode, 0)
        self.assertNotEqual(self.proof(caller=True).returncode, 0)

    def test_final_revision_must_be_frozen(self):
        self.claims.remove(self.final)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_main_publication_must_be_frozen(self):
        self.claims.remove(self.published)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_missing_or_changed_frozen_claim_set_refused(self):
        self.omit_freeze = True
        self.assertNotEqual(self.proof().returncode, 0)
        self.omit_freeze = False
        self.frozen_override = [self.repo.name + " " + self.source]
        self.assertNotEqual(self.proof().returncode, 0)

    def test_changed_path_must_be_literal_registered_scope(self):
        self.files.remove(self.meta)
        self.assertNotEqual(self.proof().returncode, 0)
        self.files.append("2026-09/**")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_current_main_change_refused_even_when_older_packet_is_claimed(self):
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.published)
        self.write(self.report, "Remote changed afterwards\n")
        self.commit("remote changed", self.report)
        self.publish_current_branch()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.final)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_hidden_worktree_change_refused(self):
        self.git("-C", str(self.repo), "update-index", "--assume-unchanged", self.report)
        self.write(self.report, "Hidden local edit\n")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_mode_change_refused_even_when_git_ignores_it(self):
        self.git("-C", str(self.repo), "config", "core.filemode", "false")
        (self.repo / self.report).chmod(0o755)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_staged_deletion_is_not_exact_untracked_packet(self):
        self.git("-C", str(self.repo), "rm", "--cached", self.report)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_symlink_substitution_refused(self):
        path = self.repo / self.report
        copy = self.root / "report-copy"
        copy.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(copy)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_unrelated_foreign_dirt_does_not_block_exact_packet(self):
        self.write("foreign/notes.txt", "Other session work\n")
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_merge_final_revision_is_not_linear_chain(self):
        tree = self.git("-C", str(self.repo), "rev-parse", self.final + "^{tree}").stdout.strip()
        merge = self.git("-C", str(self.repo), "commit-tree", tree, "-p", self.middle,
                         "-p", self.published, "-m", "merge final").stdout.strip()
        self.claims.remove(self.final)
        self.claims.append(merge)
        self.assertNotEqual(self.proof().returncode, 0)


AUTOMERGE_TARGET = "_commit_automerge_has_publish_proof"


class HistoricalAutomergePublicationTests(unittest.TestCase):
    git = ScopePublicationProofTests.git
    write = ScopePublicationProofTests.write
    commit = ScopePublicationProofTests.commit
    publish = ScopePublicationProofTests.publish
    semaphore = ScopePublicationProofTests.semaphore
    publish_current_branch = CommitCurrentTreeTests.publish_current_branch
    immutable_state = ClaimedSupersessionTests.immutable_state
    path = "current/shared.md"

    def setUp(self):
        ScopePublicationProofTests.setUp(self)
        self.env.update(GIT_ALLOW_PROTOCOL="file", GIT_OPTIONAL_LOCKS="0",
                        GIT_NO_REPLACE_OBJECTS="1")
        self.make_publication()

    def make_publication(self, variant="clean"):
        # Start each variant from the original published baseline.
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.own_commit)
        self.base_text = ("import: old\n" + "".join("left %02d\n" % n for n in range(12))
                          + "owned: old\n" + "".join("right %02d\n" % n for n in range(12))
                          + "context: old\n")
        self.write(self.path, self.base_text)
        paths = [self.path]
        if variant == "tracked-union":
            self.write(".gitattributes", "current/*.md merge=union\n")
            paths.append(".gitattributes")
        self.base = self.commit("common base", *paths)
        self.write("parent-context.txt", "same context under distinct OIDs\n")
        self.source_base = self.commit("private source parent", "parent-context.txt")
        own = self.base_text.replace("import: old", "import: ours").replace("owned: old", "owned: ours")
        self.write(self.path, own)
        self.write("owned/second.txt", "second result must survive\n")
        self.source = self.commit("private claimed change", self.path, "owned/second.txt")
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.base)
        self.write("parent-context.txt", "same context under distinct OIDs\n")
        target = self.base_text.replace("import: old", "import: ours").replace("context: old", "context: theirs")
        if variant in ("conflict", "tracked-union"):
            target = target.replace("owned: old", "owned: conflict")
        self.write(self.path, target)
        self.target = self.commit("concurrent published context", self.path, "parent-context.txt")
        if variant == "conflict":
            self.write(self.path, target.replace("owned: conflict", "owned: ours"))
            self.write("owned/second.txt", "second result must survive\n")
            self.published = self.commit("manual conflicting resolution", self.path, "owned/second.txt")
        else:
            result = self.git("-C", str(self.repo), "cherry-pick", self.source)
            self.assertIn("Auto-merging", result.stdout)
            if variant == "wrong-location":
                self.write(self.path, target + "owned: ours\n")
                self.git("-C", str(self.repo), "add", self.path)
                self.git("-C", str(self.repo), "commit", "--amend", "-qm", "wrong insertion location")
            elif variant == "lost-change":
                self.git("-C", str(self.repo), "rm", "owned/second.txt")
                self.git("-C", str(self.repo), "commit", "--amend", "-qm", "lost second result")
            elif variant == "extra-change":
                self.write("unrelated-extra.txt", "not part of the exact replay\n")
                self.git("-C", str(self.repo), "add", "unrelated-extra.txt")
                self.git("-C", str(self.repo), "commit", "--amend", "-qm", "extra unpublished provenance")
            self.published = self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()
        if variant == "publication-merge":
            tree = self.git("-C", str(self.repo), "rev-parse", self.published + "^{tree}").stdout.strip()
            self.published = self.git("-C", str(self.repo), "commit-tree", tree,
                                      "-p", self.target, "-p", self.base, "-m", "merge publication").stdout.strip()
            self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.published)
        self.write(self.path, (self.repo / self.path).read_text().replace("owned: ours", "owned: later"))
        self.commit("later legitimate edit", self.path)
        self.git("-C", str(self.repo), "push", "-q", "--force", "origin", "HEAD:refs/heads/main")
        self.git("-C", str(self.repo), "fetch", "-q", "origin")
        self.remote = self.git("-C", str(self.repo), "rev-parse", "origin/main").stdout.strip()
        self.git("-C", str(self.repo), "checkout", "-q", "--detach", self.source)
        self.files = [self.path, "owned/second.txt"]
        self.commits = [self.repo.name + " " + self.source]
        names = [COMMIT_TARGET, SUPERSESSION_TARGET, "_peer_metadata_claim_has_publish_proof",
                 "_claimed_source_chain_has_publish_proof", "_code_branch_claim_has_publish_proof",
                 "normalize_remote_url", "_resolve_repo_checkout", CLAIMS_TARGET]
        source = GUARD.read_text()
        if AUTOMERGE_TARGET + "() {" in source:
            names.append(AUTOMERGE_TARGET)
        self.functions = "\n".join(extract_function(source, name) for name in names)

    def invoke(self, caller=False):
        target = CLAIMS_TARGET if caller else AUTOMERGE_TARGET
        args = [str(self.sem)] if caller else [str(self.repo), self.source, self.remote,
                                             str(self.sem), self.repo.name]
        return subprocess.run(["/bin/bash"], input="set -euo pipefail\n" + self.functions
                              + "\n" + target + " " + shlex.join(args),
                              env=self.env, text=True, capture_output=True, timeout=30)

    def proof(self, caller=False):
        self.semaphore()
        before = self.immutable_state()
        result = self.invoke(caller)
        self.assertEqual(self.immutable_state(), before, "Proof changed source, objects, refs or claims")
        self.assertNotIn("command not found", result.stderr)
        return result

    def test_automerge_survives_later_edit_full_claim_gate(self):
        cherry = self.git("-C", str(self.repo), "cherry", self.remote, self.source, self.source + "^")
        self.assertEqual(cherry.stdout.strip(), "+ " + self.source)
        base = self.git("-C", str(self.repo), "merge-base", self.source, self.target).stdout.strip()
        self.assertNotEqual(base, self.source_base)
        result = self.proof(caller=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exact historical replay", result.stderr)

    def test_exact_historical_replay_needs_no_claim_on_publisher_oid(self):
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.published, result.stderr)

    def test_same_text_at_wrong_location_is_not_delivery(self):
        self.make_publication("wrong-location")
        self.assertNotEqual(self.proof().returncode, 0)
        self.assertNotEqual(self.proof(caller=True).returncode, 0)

    def test_lost_second_file_is_not_delivery(self):
        self.make_publication("lost-change")
        self.assertNotEqual(self.proof().returncode, 0)
        self.assertNotEqual(self.proof(caller=True).returncode, 0)

    def test_extra_changes_are_not_exact_whole_tree_replay(self):
        self.make_publication("extra-change")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_manual_conflict_resolution_is_not_clean_replay(self):
        self.make_publication("conflict")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_merge_publication_is_not_linear_replay(self):
        self.make_publication("publication-merge")
        self.assertNotEqual(self.proof().returncode, 0)

    def test_source_merge_is_refused(self):
        tree = self.git("-C", str(self.repo), "rev-parse", self.source + "^{tree}").stdout.strip()
        self.source = self.git("-C", str(self.repo), "commit-tree", tree, "-p", self.source,
                               "-p", self.base, "-m", "source merge").stdout.strip()
        self.commits = [self.repo.name + " " + self.source]
        self.assertNotEqual(self.proof().returncode, 0)

    def test_empty_source_is_refused(self):
        self.git("-C", str(self.repo), "commit", "--allow-empty", "-qm", "empty source")
        self.source = self.git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()
        self.commits = [self.repo.name + " " + self.source]
        self.assertNotEqual(self.proof().returncode, 0)

    def test_source_must_be_frozen_in_exact_repository(self):
        self.commits = ["other-repository " + self.source]
        self.assertNotEqual(self.proof().returncode, 0)

    def test_stale_remote_argument_is_refused(self):
        self.remote = self.published
        self.assertNotEqual(self.proof().returncode, 0)

    def test_repository_merge_driver_cannot_run(self):
        self.make_publication("conflict")
        marker = self.root / "untrusted-driver-called"
        attributes = self.root / "attributes"
        attributes.write_text("*.md merge=untrusted\n")
        self.git("-C", str(self.repo), "config", "core.attributesFile", str(attributes))
        self.git("-C", str(self.repo), "config", "merge.untrusted.driver", "touch " + shlex.quote(str(marker)))
        self.assertNotEqual(self.proof().returncode, 0)
        self.assertFalse(marker.exists())

    def test_tracked_union_attribute_is_ignored(self):
        self.make_publication("tracked-union")
        # Real tracked attributes resolve this conflict to the exact historical
        # tree. The proof must require the clean default merge instead.
        empty_tree = subprocess.run(
            ["/usr/bin/git", "-C", str(self.repo), "mktree"], input="",
            env=self.env, text=True, capture_output=True, check=True,
        ).stdout.strip()
        wanted = self.git("-C", str(self.repo), "rev-parse", self.published + "^{tree}").stdout.strip()
        for attribute_source, expected in ((self.base, 0), (empty_tree, 1)):
            with self.subTest(attributes=attribute_source):
                control = subprocess.run(
                    ["/usr/bin/git", "-C", str(self.repo), "merge-tree", "--write-tree",
                     "--merge-base=" + self.source_base, self.target, self.source],
                    env={**self.env, "GIT_ATTR_SOURCE": attribute_source},
                    text=True, capture_output=True, timeout=20,
                )
                self.assertEqual(control.returncode, expected, control.stderr)
                if expected == 0:
                    self.assertEqual(control.stdout.strip(), wanted)
        self.assertNotEqual(self.proof().returncode, 0)

    def test_checkout_beneath_unicode_parent_has_exact_replay_proof(self):
        parent = self.root / "проверка"
        parent.mkdir()
        self.repo = self.repo.rename(parent / self.repo.name)
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.published, result.stderr)

    def test_no_published_commit_touches_the_claimed_path(self):
        path = "never-published/result.txt"
        self.write(path, "undelivered result\n")
        self.source = self.commit("unpublished new path", path)
        self.commits = [self.repo.name + " " + self.source]
        self.files = [path]
        candidates = self.git("-C", str(self.repo), "rev-list", self.remote, "--", path)
        self.assertEqual(candidates.stdout, "")
        self.assertNotEqual(self.proof().returncode, 0)
        self.assertNotEqual(self.proof(caller=True).returncode, 0)

    def test_remote_head_and_claim_races_cannot_authorize_delivery(self):
        import shutil

        real_git = shutil.which("git", path=self.env["PATH"])
        commands = self.root / "commands"
        commands.mkdir()
        marker = self.root / "race-fired"
        wrapper = commands / "git"
        wrapper.write_text(
            "#!/usr/bin/env python3\nimport os, subprocess, sys\nfrom pathlib import Path\n"
            "marker = Path(os.environ['FIXTURE_RACE_MARKER'])\n"
            "if 'merge-tree' in sys.argv[1:] and not marker.exists():\n"
            "    marker.write_text('fired')\n"
            "    mode = os.environ['FIXTURE_RACE_MODE']\n"
            "    if mode == 'claims':\n"
            "        with Path(os.environ['FIXTURE_SEMAPHORE']).open('a') as handle:\n"
            "            handle.write('file: changed-during-proof.txt\\n')\n"
            "    else:\n"
            "        ref = 'HEAD' if mode == 'head' else 'refs/remotes/origin/main'\n"
            "        subprocess.run([os.environ['FIXTURE_REAL_GIT'], '-C', os.environ['FIXTURE_REPO'],\n"
            "                        'update-ref', ref, os.environ['FIXTURE_RACE_OID']], check=True)\n"
            "os.execv(os.environ['FIXTURE_REAL_GIT'], [os.environ['FIXTURE_REAL_GIT'], *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o755)
        original_path = self.env["PATH"]
        self.env.update(FIXTURE_REAL_GIT=real_git, FIXTURE_RACE_MARKER=str(marker),
                        FIXTURE_REPO=str(self.repo), FIXTURE_RACE_OID=self.base,
                        FIXTURE_SEMAPHORE=str(self.sem))
        for mode in ("remote", "head", "claims"):
            with self.subTest(changed=mode):
                self.semaphore()
                before = self.immutable_state()
                marker.unlink(missing_ok=True)
                self.env.update(PATH=str(commands) + os.pathsep + original_path,
                                FIXTURE_RACE_MODE=mode)
                try:
                    result = self.invoke()
                finally:
                    self.env["PATH"] = original_path
                    self.git("-C", str(self.repo), "update-ref", "HEAD", self.source)
                    self.git("-C", str(self.repo), "update-ref", "refs/remotes/origin/main", self.remote)
                    self.sem.write_bytes(before["semaphore"])
                self.assertTrue(marker.exists(), "The fixture must change inputs during a real merge proof")
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("snapshot changed", result.stderr)
                self.assertEqual(self.immutable_state(), before)



if __name__ == "__main__":
    unittest.main(verbosity=2)
