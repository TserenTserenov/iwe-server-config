"""Tests for scripts/repo_registry.py (WP-539 F21 B1): schema validation and discovery comparison."""

import copy
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import repo_registry  # noqa: E402

VALID = {
    "version": 1,
    "repos": [
        {
            "repo_id": "canon",
            "class": "canon",
            "checkouts": [{"host": "mac", "path": "canon"}, {"host": "tsekh-1", "path": "canon"}],
            "decision_owner": {"ref": "WP-539", "scope": "repo"},
            "thresholds": {"fetch_max_age_min": 120, "behind_max_commits": None},
        },
        {
            "repo_id": "root",
            "class": "undecided",
            "checkouts": [{"host": "mac", "path": "."}, {"host": "tsekh-1", "path": ".", "optional": True}],
        },
    ],
}


def broken(mutate):
    data = copy.deepcopy(VALID)
    mutate(data)
    return repo_registry.validate(data)


class ValidateTest(unittest.TestCase):
    def test_valid_registry_has_no_errors(self):
        self.assertEqual(repo_registry.validate(VALID), [])

    def test_fetch_permission_is_forbidden_here(self):
        errors = broken(lambda d: d["repos"][0].update(fetch_allowed=True))
        self.assertEqual(len(errors), 1)
        self.assertIn("fetch_allowed здесь запрещён", errors[0])

    def test_class_without_decision_is_rejected_but_undecided_is_fine(self):
        errors = broken(lambda d: d["repos"][0].update(decision_owner=None))
        self.assertEqual(len(errors), 1)
        self.assertIn("без записанного решения", errors[0])
        self.assertEqual(broken(lambda d: None), [])  # undecided without owner is the valid default

    def test_duplicate_repo_id_and_duplicate_checkout_are_rejected(self):
        errors = broken(lambda d: d["repos"].append(copy.deepcopy(d["repos"][0])))
        self.assertTrue(any("repo_id повторяется" in e for e in errors))
        self.assertTrue(any("уже занята записью 'canon'" in e for e in errors))

    def test_unsafe_paths_and_unknown_fields_are_rejected(self):
        errors = broken(lambda d: d["repos"][0]["checkouts"].append({"host": "mac", "path": "../x"}))
        self.assertTrue(any("без '..'" in e for e in errors))
        errors = broken(lambda d: d["repos"][0].update(frozen=True))
        self.assertIn("repos[0] (canon): неизвестное поле 'frozen'", errors)
        errors = broken(lambda d: d["repos"][0]["checkouts"][0].update(host="mars"))
        self.assertTrue(any("host должен быть" in e for e in errors))

    def test_thresholds_null_is_not_set_and_zero_is_a_number(self):
        self.assertEqual(broken(lambda d: d["repos"][0]["thresholds"].update(fetch_max_age_min=0)), [])
        for bad in (-1, True, "10"):
            errors = broken(lambda d, b=bad: d["repos"][0]["thresholds"].update(fetch_max_age_min=b))
            self.assertEqual(len(errors), 1, bad)
        errors = broken(lambda d: d["repos"][0]["thresholds"].update(unknown_limit=1))
        self.assertIn("неизвестный порог 'unknown_limit'", errors[0])

    def test_wrong_types_are_reported_not_raised(self):
        """Regression (cold review): an unhashable host/path used to raise TypeError out of validate()."""
        for bad in ({"host": "mac", "path": ["x"]}, {"host": ["mac"], "path": "x"}, {"host": {"a": 1}, "path": "x"}):
            errors = broken(lambda d, b=bad: d["repos"][0]["checkouts"].append(b))
            self.assertTrue(errors, bad)

    def test_version_must_be_the_integer_one(self):
        for bad in (True, 1.0, "1"):
            errors = repo_registry.validate({**VALID, "version": bad})
            self.assertEqual(len(errors), 1, bad)

    def test_paths_must_be_in_normal_form(self):
        for path in ("a/", "./a", "a//b"):
            errors = broken(lambda d, p=path: d["repos"][0]["checkouts"].append({"host": "mac", "path": p}))
            self.assertTrue(any("нормальной форме" in e for e in errors), path)
        self.assertEqual(broken(lambda d: d["repos"][0]["checkouts"].append({"host": "mac", "path": "a/b"})), [])

    def test_empty_and_non_mapping_roots_are_rejected(self):
        self.assertTrue(repo_registry.validate(None))
        self.assertTrue(repo_registry.validate({"version": 1, "repos": []}))
        self.assertTrue(repo_registry.validate({"version": 2, "repos": VALID["repos"]}))


class LoadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_file_is_an_error_not_an_empty_registry(self):
        registry, errors = repo_registry.load(self.dir / "absent.yaml")
        self.assertIsNone(registry)
        self.assertEqual(errors, ["нет файла реестра: absent.yaml"])

    def test_broken_yaml_is_reported(self):
        path = self.dir / "r.yaml"
        path.write_text("version: 1\nrepos: [unclosed\n")
        registry, errors = repo_registry.load(path)
        self.assertIsNone(registry)
        self.assertIn("реестр не читается (", errors[0])

    def test_schema_errors_make_the_whole_registry_unusable(self):
        path = self.dir / "r.yaml"
        path.write_text("version: 1\nrepos:\n  - repo_id: x\n    class: nope\n    checkouts: []\n")
        registry, errors = repo_registry.load(path)
        self.assertIsNone(registry)
        self.assertGreaterEqual(len(errors), 2)

    def test_the_shipped_registry_is_valid(self):
        """Live-file check: the registry committed next to the scripts must pass the validator."""
        registry, errors = repo_registry.load(SCRIPTS / "repo-convergence.registry.yaml")
        self.assertEqual(errors, [])
        self.assertEqual([e["repo_id"] for e in registry["repos"]][0], "DS-my-strategy")


class CompareTest(unittest.TestCase):
    def test_four_separate_answers_on_mac(self):
        result = repo_registry.compare(VALID, ["canon", "stray", "."], "mac")
        self.assertEqual(result["registered"], [".", "canon"])
        self.assertEqual(result["outside"], ["stray"])
        self.assertEqual(result["absent"], [])
        self.assertEqual(result["not_expected"], [])

    def test_registered_but_missing_is_absent_unless_optional(self):
        # On tsekh-1 the root checkout is optional (Nix mirror): its absence is not a finding.
        result = repo_registry.compare(VALID, [], "tsekh-1")
        self.assertEqual(result["absent"], ["canon"])

    def test_repo_registered_only_for_other_host_is_not_expected_not_outside(self):
        data = copy.deepcopy(VALID)
        data["repos"].append({"repo_id": "cech-only", "class": "undecided",
                              "checkouts": [{"host": "tsekh-1", "path": "cech-only"}]})
        result = repo_registry.compare(data, ["canon", "cech-only"], "mac")
        self.assertEqual(result["not_expected"], ["cech-only"])
        self.assertEqual(result["outside"], [])


if __name__ == "__main__":
    unittest.main()
