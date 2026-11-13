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

    def test_readers_are_fetched(self):
        """A reader copy without broker fetch rights would be 'current' against a stale ref forever."""
        import yaml

        registry, _ = repo_registry.load(SCRIPTS / "repo-convergence.registry.yaml")
        broker = yaml.safe_load((SCRIPTS / "refs-sync-broker.repos.yaml").read_text(encoding="utf-8"))
        fetched = {r["path"]: r for r in broker["repos"]}
        for host in repo_registry.HOSTS:
            for entry, checkout in repo_registry.checkouts_of_class(registry, "reader", host):
                rule = fetched.get(checkout["path"])
                self.assertIsNotNone(rule, checkout["path"])
                remote, _, _ = entry["upstream"].partition("/")
                self.assertEqual(rule["remote"], remote, checkout["path"])
                # the broker must fill exactly the ref the reader moves to (main vs master etc.)
                self.assertTrue(rule["refspec"].endswith(":refs/remotes/" + entry["upstream"]), checkout["path"])

    def test_json_copy_in_sync(self):
        """iwe-server-config builds the Tsekh git-ops lists from the JSON copy: it must equal the YAML."""
        registry, _ = repo_registry.load(SCRIPTS / "repo-convergence.registry.yaml")
        committed = (SCRIPTS / repo_registry.JSON_EXPORT).read_text(encoding="utf-8")
        self.assertEqual(committed, repo_registry.to_json(registry),
                         "regenerate: python3 scripts/repo_registry.py export-json")

    def test_written_paths(self):
        data = copy.deepcopy(VALID)
        data["repos"][0]["checkouts"][1]["written_here"] = True
        self.assertEqual(repo_registry.validate(data), [])
        self.assertEqual(repo_registry.written_paths(data, "tsekh-1"), ["canon"])
        self.assertEqual(repo_registry.written_paths(data, "mac"), [])
        data["repos"][0]["checkouts"][1]["written_here"] = "yes"
        self.assertTrue(any("written_here должен быть булевым" in e for e in repo_registry.validate(data)))

    def test_written_reader_rejected(self):
        """A reader copy marked written would be pushed from its host by the Tsekh git-ops list."""
        data = copy.deepcopy(VALID)
        data["repos"][0]["class"] = "reader"
        data["repos"][0]["checkouts"][1]["written_here"] = True
        errors = repo_registry.validate(data)
        self.assertEqual(len(errors), 1)
        self.assertIn("written_here несовместим", errors[0])
        data["repos"][0]["checkouts"][1]["class"] = "service"
        self.assertEqual(repo_registry.validate(data), [])

    def test_bad_types_report(self):
        """Wrong types in a decided entry are reported, never raised (load() must not crash its callers)."""
        errors = broken(lambda d: d["repos"][1].update(checkouts=5))
        self.assertTrue(any("checkouts — непустой список" in e for e in errors))
        errors = broken(lambda d: d["repos"][1]["checkouts"][0].update({"class": ["reader"]}))
        self.assertTrue(any("class должен быть одним из" in e for e in errors))


class CheckoutClassTest(unittest.TestCase):
    def with_tsekh_role(self, cls):
        data = copy.deepcopy(VALID)
        data["repos"][0]["class"] = "reader"
        data["repos"][0]["checkouts"][1]["class"] = cls
        return data

    def test_checkout_class_overrides_entry_class_per_host(self):
        data = self.with_tsekh_role("service")
        self.assertEqual(repo_registry.validate(data), [])
        self.assertEqual([c["path"] for _, c in repo_registry.checkouts_of_class(data, "reader", "mac")], ["canon"])
        self.assertEqual(repo_registry.checkouts_of_class(data, "reader", "tsekh-1"), [])
        self.assertEqual([c["host"] for _, c in repo_registry.checkouts_of_class(data, "service", "tsekh-1")],
                         ["tsekh-1"])

    def test_unknown_checkout_class_is_rejected(self):
        errors = repo_registry.validate(self.with_tsekh_role("mirror"))
        self.assertEqual(len(errors), 1)
        self.assertIn("class должен быть одним из", errors[0])

    def test_decided_checkout_class_needs_a_recorded_decision(self):
        data = copy.deepcopy(VALID)
        data["repos"][1]["checkouts"][0]["class"] = "service"  # entry 'root' is undecided, no owner
        errors = repo_registry.validate(data)
        self.assertEqual(len(errors), 1)
        self.assertIn("класс service без записанного решения", errors[0])


class SharedLockTest(unittest.TestCase):
    def root_reader(self, **extra):
        data = copy.deepcopy(VALID)
        data["repos"][1]["decision_owner"] = {"ref": "pilot 13.11", "scope": "checkout"}
        data["repos"][1]["checkouts"][0].update({"class": "reader", **extra})
        return data

    def test_reader_with_shared_lock_is_valid_and_selected(self):
        data = self.root_reader(shared_lock="ds-commit")
        self.assertEqual(repo_registry.validate(data), [])
        picked = repo_registry.checkouts_of_class(data, "reader", "mac")
        self.assertEqual([(c["path"], c["shared_lock"]) for _, c in picked], [(".", "ds-commit")])

    def test_unknown_shared_lock_is_rejected(self):
        errors = repo_registry.validate(self.root_reader(shared_lock="other"))
        self.assertEqual(len(errors), 1)
        self.assertIn("shared_lock должен быть одним из", errors[0])

    def test_shared_lock_outside_reader_is_rejected(self):
        data = self.root_reader(shared_lock="ds-commit")
        data["repos"][1]["checkouts"][0]["class"] = "working"
        errors = repo_registry.validate(data)
        self.assertEqual(len(errors), 1)
        self.assertIn("shared_lock допустим только у читательской копии", errors[0])

    def test_shipped_registry_moves_mac_root_under_shared_lock(self):
        registry, errors = repo_registry.load(SCRIPTS / "repo-convergence.registry.yaml")
        self.assertEqual(errors, [])
        roots = [c for _, c in repo_registry.checkouts_of_class(registry, "reader", "mac") if c["path"] == "."]
        self.assertEqual([c.get("shared_lock") for c in roots], ["ds-commit"])
        self.assertEqual([c for _, c in repo_registry.checkouts_of_class(registry, "reader", "tsekh-1")
                          if c["path"] == "."], [])


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
