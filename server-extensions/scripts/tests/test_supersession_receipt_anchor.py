"""Real Git regressions for receipt-bound supersession candidates."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("publication_receipt", SCRIPTS / "lib/publication_receipt.py")
receipts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipts)


def extract_function(source, name):
    start = source.index(name + "() {")
    lines = []
    heredoc = False
    for line in source[start:].splitlines():
        lines.append(line)
        if "<<'PY'" in line:
            heredoc = True
        elif heredoc and line == "PY":
            heredoc = False
        elif not heredoc and line == "}":
            return "\n".join(lines) + "\n"
    raise AssertionError("unterminated function")


class ReceiptSupersessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-qb", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("remote", "add", "origin", str(self.root / "remote.git"))
        self.base_text = "heading\nunique before\nunique after\nfooter\n"
        self.own_text = "heading\nunique before\nowned one\nowned two\nunique after\nfooter\n"
        self.base = self.commit("a.txt", self.base_text)
        self.source = self.commit("a.txt", self.own_text)
        self.git("checkout", "-q", "--detach", self.base)
        self.concurrent = self.commit("b.txt", "concurrent work\n")
        self.sem = self.root / "codex-one.open"
        # Keep the helper's ordinary source-relative library location intact.
        fixture_scripts = self.root / "scripts"
        (fixture_scripts / "lib").mkdir(parents=True)
        (fixture_scripts / "lib/publication_receipt.py").write_bytes(
            (SCRIPTS / "lib/publication_receipt.py").read_bytes())
        self.helper = fixture_scripts / "helper.sh"
        self.helper.write_text(extract_function((SCRIPTS / "session-guard.sh").read_text(),
                                               "_commit_claim_supersession_has_publish_proof"))

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, name, text):
        (self.repo / name).write_text(text)
        self.git("add", "--", name)
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "change " + name)
        return self.git("rev-parse", "HEAD")

    def history(self, lose_line=False):
        # The rebased claim and published cherry-pick deliberately have distinct OIDs.
        text = self.own_text.replace("owned two\n", "") if lose_line else self.own_text
        self.rebased = self.commit("a.txt", text)
        self.git("checkout", "-q", "--detach", self.concurrent)
        self.publish_parent = self.commit("c.txt", "another writer\n")
        self.git("-c", "commit.gpgsign=false", "cherry-pick", self.rebased)
        self.anchor = self.git("rev-parse", "HEAD")
        self.remote = self.commit("a.txt", "later legitimate replacement\n")
        self.git("update-ref", "refs/remotes/origin/main", self.remote)
        self.raw = ("agent: codex\nsession_id: one\nwp: WP-484\n"
                    f"commit: repo {self.source}\ncommit: repo {self.rebased}\n").encode()
        self.saved = receipts.receipt(self.repo, self.raw, "repo", self.rebased, self.anchor)
        self.assertNotEqual(self.rebased, self.anchor)
        self.assertNotIn(self.anchor.encode(), self.raw)
        self.write_receipt()

    def write_receipt(self):
        self.sem.write_bytes(self.raw + (receipts.PREFIX + json.dumps(self.saved) + "\n").encode())

    def fingerprint(self):
        return {
            "refs": self.git("show-ref"), "head": self.git("rev-parse", "HEAD"),
            "semaphore": self.sem.read_bytes(),
            "files": {str(p.relative_to(self.repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in self.repo.rglob("*") if p.is_file()},
        }

    def proof(self, check_immutable=True):
        before = self.fingerprint()
        command = ("set -euo pipefail\nsource " + shlex.quote(str(self.helper)) + "\n"
                   "_commit_claim_supersession_has_publish_proof " + shlex.join([
                       str(self.repo), self.source, self.remote, str(self.sem), "repo"]))
        result = subprocess.run(["bash"], input=command, text=True, capture_output=True,
                                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=50)
        if check_immutable:
            self.assertEqual(before, self.fingerprint(), "proof mutated repository or semaphore")
        return result

    def test_rebased_claim_cherry_picked_and_later_replaced_passes(self):
        self.history()
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [self.anchor])
        result = self.proof()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.source + " -> " + self.anchor, result.stderr)

    def test_valid_receipt_does_not_mask_partial_loss_of_old_claim(self):
        self.history(lose_line=True)
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [self.anchor])
        result = self.proof()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no exact published successor", result.stderr)

    def test_forged_receipt_is_not_an_anchor(self):
        self.history()
        self.saved["source_tree"] = "0" * 40
        self.write_receipt()
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [])
        self.assertNotEqual(self.proof().returncode, 0)

    def test_foreign_session_receipt_is_not_an_anchor(self):
        self.history()
        self.saved["session_id"] = "another-session"
        self.write_receipt()
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [])
        self.assertNotEqual(self.proof().returncode, 0)

    def test_foreign_repo_receipt_is_not_an_anchor(self):
        self.history()
        self.saved["repo"] = "other-repo"
        self.write_receipt()
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [])
        self.assertNotEqual(self.proof().returncode, 0)

    def test_unpublished_anchor_is_refused(self):
        self.history()
        self.remote = self.publish_parent
        self.git("update-ref", "refs/remotes/origin/main", self.remote)
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [])
        self.assertNotEqual(self.proof().returncode, 0)

    def test_receipt_source_must_still_be_claimed(self):
        self.history()
        self.raw = self.raw.replace(f"commit: repo {self.rebased}\n".encode(), b"")
        self.write_receipt()
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [])
        self.assertNotEqual(self.proof().returncode, 0)

    def test_valid_receipt_does_not_validate_a_second_forged_anchor(self):
        self.history()
        forged = {**self.saved, "anchor_commit": self.remote}
        with self.sem.open("a") as stream:
            stream.write(receipts.PREFIX + json.dumps(forged) + "\n")
        self.assertEqual(receipts.verified_anchors(self.repo, self.sem, "repo", self.remote), [self.anchor])

    def test_session_change_during_anchor_verification_refuses(self):
        self.history()
        original = receipts.receipt

        def concurrent_change(*args):
            result = original(*args)
            with self.sem.open("a") as stream:
                stream.write("concurrent: change\n")
            return result

        with patch.object(receipts, "receipt", side_effect=concurrent_change):
            with self.assertRaisesRegex(receipts.ProofError, "session or remote changed"):
                receipts.verified_anchors(self.repo, self.sem, "repo", self.remote)

    def test_remote_change_after_anchor_verification_refuses(self):
        self.history()
        # A fixture-only writer moves the local fetched ref after verification,
        # reproducing another concurrent fetch before the old-source proof ends.
        library = self.helper.parent / "lib/publication_receipt.py"
        with library.open("a") as stream:
            stream.write("\n_original_verified_anchors = verified_anchors\n"
                         "def verified_anchors(repo, semaphore, name, remote):\n"
                         "    result = _original_verified_anchors(repo, semaphore, name, remote)\n"
                         f"    git(repo, 'update-ref', 'refs/remotes/origin/main', '{self.publish_parent}')\n"
                         "    return result\n")
        before_sem = self.sem.read_bytes()
        result = self.proof(check_immutable=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remote changed during receipt supersession proof", result.stderr)
        self.assertEqual(self.sem.read_bytes(), before_sem)


if __name__ == "__main__":
    unittest.main(verbosity=2)
