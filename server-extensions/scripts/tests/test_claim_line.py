"""Claim lines of a session semaphore (WP-484 Ф275): the parser, its bash twin, and the readers moved onto it."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / "lib"
GUARD = Path(__file__).resolve().parents[1] / "session-guard.sh"
CASES = json.loads((Path(__file__).parent / "fixtures" / "claim-line-cases.json").read_text())
REPO, SHA = CASES["repo"], CASES["sha"]

sys.path.insert(0, str(LIB))
import claim_line  # noqa: E402

_SPEC = importlib.util.spec_from_file_location("publication_receipt", LIB / "publication_receipt.py")
receipt = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(receipt)


def guard_heredoc(function_name: str) -> str:
    """The python body of a heredoc inside a session-guard.sh function, so the test runs the shipped code."""
    text = GUARD.read_text()
    start = text.index(function_name + "() {")
    body = text.index("<<'PY'\n", start) + len("<<'PY'\n")
    return text[body:text.index("\nPY\n", body)]


class FixtureTable(unittest.TestCase):
    def test_python_matches_the_table(self):
        for case in CASES["cases"]:
            with self.subTest(case["name"]):
                self.assertEqual(claim_line.matches(case["line"], REPO, SHA), case["matches"])

    def test_bash_twin_matches_the_table(self):
        for case in CASES["cases"]:
            with self.subTest(case["name"]):
                run = subprocess.run(
                    ["bash", "-c", '. "$1"; _claim_line_matches "$2" "$3" "$4"',
                     "bash", str(LIB / "claim-line.sh"), case["line"], REPO, SHA])
                self.assertEqual(run.returncode == 0, case["matches"])

    def test_bash_claim_present_finds_a_four_field_claim_in_a_file(self):
        four = next(c["line"] for c in CASES["cases"] if c["name"].startswith("four-field claim in the incident"))
        with tempfile.TemporaryDirectory() as tmp:
            sem = Path(tmp) / "s.open"
            sem.write_text("---\nslug: x\n---\nfile: a\n" + four + "\n")
            present = subprocess.run(["bash", "-c", '. "$1"; _claim_present "$2" "$3" "$4"',
                                      "bash", str(LIB / "claim-line.sh"), str(sem), REPO, SHA])
            other = subprocess.run(["bash", "-c", '. "$1"; _claim_present "$2" "$3" "$4"',
                                    "bash", str(LIB / "claim-line.sh"), str(sem), REPO, "b" * 40])
        self.assertEqual((present.returncode, other.returncode), (0, 1))

    def test_checkout_and_branch_do_not_take_part_in_the_identity(self):
        two = "commit: R " + "a" * 40
        for suffix in ("", " /elsewhere branch-x", " /other-host main", " - -"):
            with self.subTest(suffix=suffix):
                self.assertTrue(claim_line.matches(two + suffix, "R", "a" * 40))
                self.assertFalse(claim_line.matches(two + suffix, "R", "b" * 40))
                self.assertFalse(claim_line.matches(two + suffix, "Q", "a" * 40))

    def test_parse_returns_the_four_fields_of_a_four_field_claim(self):
        self.assertEqual(claim_line.parse("commit: R " + "a" * 40 + " /co br"),
                         claim_line.Claim("R", "a" * 40, "/co", "br"))
        self.assertEqual(claim_line.parse("commit: R " + "a" * 40), claim_line.Claim("R", "a" * 40, None, None))

    def test_parse_distinguishes_not_a_claim_from_a_broken_claim(self):
        self.assertIsNone(claim_line.parse("file: x"))
        with self.assertRaises(claim_line.ClaimError):
            claim_line.parse("commit: R " + "a" * 40 + " only-checkout")
        with self.assertRaises(claim_line.ClaimError):
            claim_line.parse("commit: R abc")

    def test_parse_keeps_the_superset_of_sha_spellings_readers_accept_today(self):
        for sha in ("A" * 40, "a" * 41, "a" * 63, "a" * 64):
            with self.subTest(sha=sha):
                self.assertEqual(claim_line.parse("commit: R " + sha).sha, sha)
        self.assertTrue(claim_line.is_canonical_sha("a" * 40))
        self.assertTrue(claim_line.is_canonical_sha("a" * 64))
        for sha in ("A" * 40, "a" * 41, "a" * 63):
            with self.subTest(noncanonical=sha):
                self.assertFalse(claim_line.is_canonical_sha(sha))


class ReceiptClaims(unittest.TestCase):
    """publication_receipt.claims(): the reader that refused the 4-field line on 01.11."""

    def claims(self, *lines):
        raw = ("---\nslug: x\n---\n" + "\n".join(lines) + "\n").encode()
        return receipt.claims(raw, REPO, Path("/nonexistent"))

    def test_two_field_claim(self):
        self.assertEqual(self.claims("commit: %s %s" % (REPO, SHA)), [SHA])

    def test_four_field_claim_of_the_incident_is_found(self):
        line = next(c["line"] for c in CASES["cases"] if c["name"].startswith("four-field claim in the incident"))
        self.assertEqual(self.claims(line), [SHA])

    def test_both_forms_of_one_pair_give_one_source(self):
        self.assertEqual(self.claims("commit: %s %s" % (REPO, SHA), "commit: %s %s - -" % (REPO, SHA)), [SHA])

    def test_other_repository_lines_are_not_this_readers_business(self):
        self.assertEqual(self.claims("commit: iwe-root nonsense", "commit: %s %s - -" % (REPO, SHA)), [SHA])

    def test_a_broken_claim_of_this_repository_still_refuses(self):
        for line in ("commit: %s %s only-checkout" % (REPO, SHA), "commit: %s abc" % REPO,
                     "commit: %s %s" % (REPO, SHA.upper()),
                     "commit: %s  %s" % (REPO, SHA), "commit: %s %s " % (REPO, SHA),
                     "commit: %s %s\t/co\tbr" % (REPO, SHA)):
            with self.subTest(line=line), self.assertRaisesRegex(receipt.ProofError, "malformed source claim"):
                self.claims(line)


class ClaimRewrite(unittest.TestCase):
    """_rewrite_commit_claims_atomic: a rebuilt commit replaces the sha and keeps the claim's context."""

    def rewrite(self, semaphore_text, old, new):
        with tempfile.TemporaryDirectory() as tmp:
            sem = Path(tmp) / "s.open"
            sem.write_text(semaphore_text)
            script = Path(tmp) / "rewrite.py"
            script.write_text(guard_heredoc("_rewrite_commit_claims_atomic"))
            run = subprocess.run([sys.executable, str(script), str(sem), REPO, old, new], capture_output=True,
                                 text=True, env={**os.environ, "GUARD_LIB_DIR": str(LIB)})
            self.assertEqual(run.returncode, 0, run.stderr)
            return sem.read_text(), int(run.stdout.strip())

    def test_two_field_claim_is_rewritten(self):
        text, count = self.rewrite("---\nslug: x\n---\ncommit: %s %s\n" % (REPO, "a" * 40), "a" * 40, "b" * 40)
        self.assertEqual((text, count), ("---\nslug: x\n---\ncommit: %s %s\n" % (REPO, "b" * 40), 1))

    def test_four_field_claim_is_rewritten_and_keeps_checkout_and_branch(self):
        before = "---\nslug: x\n---\ncommit: %s %s /co br\nfile: f\n" % (REPO, "a" * 40)
        after = "---\nslug: x\n---\ncommit: %s %s /co br\nfile: f\n" % (REPO, "b" * 40)
        self.assertEqual(self.rewrite(before, "a" * 40, "b" * 40), (after, 1))

    def test_whitespace_variants_are_left_alone_instead_of_being_normalized(self):
        text = "---\nslug: x\n---\ncommit: %s  %s\ncommit: %s %s \n" % (REPO, "a" * 40, REPO, "a" * 40)
        self.assertEqual(self.rewrite(text, "a" * 40, "b" * 40), (text, 0))

    def test_other_repository_and_other_sha_are_left_alone(self):
        text = ("---\nslug: x\n---\ncommit: other %s\ncommit: %s %s\n" % ("a" * 40, REPO, "c" * 40))
        self.assertEqual(self.rewrite(text, "a" * 40, "b" * 40), (text, 0))


class NoRawClaimComparisonsLeftInMigratedReaders(unittest.TestCase):
    """Ratchet: the sites moved onto the shared parser must not grow a raw 'commit: <repo> <sha>' comparison again."""

    def test_migrated_sites_do_not_build_the_two_field_line_for_comparison(self):
        guard = GUARD.read_text()
        self.assertNotIn('require(f"commit: {repo_name} {claimed}"', guard)
        self.assertNotIn('grep -qxF "$entry"', guard)
        self.assertNotIn('replacement[("commit: %s %s"', guard)
        self.assertIsNone(re.search(r'sha = line\[len\("commit: " \+ repo_name', (LIB / "publication_receipt.py").read_text()))


if __name__ == "__main__":
    unittest.main()
