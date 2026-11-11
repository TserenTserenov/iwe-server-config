"""Tests for scripts/lib/phase_status.py and its three consumers (WP-484 Ф299 п.1)."""
import importlib.util
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts" / "lib"
sys.path.insert(0, str(LIB))
import phase_status  # noqa: E402

CASES = {
    "pending": "open",
    "in_progress": "open",
    "blocked": "open",
    "implemented": "open",
    "implemented-partial": "open",
    "done": "closed",
    "closed": "closed",
    "archived": "closed",
    "completed": "closed",
    "merged": "closed",
    "superseded": "closed",
    "moved-to-wp-561": "closed",
    "  Completed ": "closed",
    "moved-to-": "unknown",
    "moved": "unknown",
    "deferred": "unknown",
    "": "unknown",
    None: "unknown",
    42: "unknown",
}


class ClassifyTable(unittest.TestCase):
    def test_every_status_gets_the_contract_class(self):
        for status, expected in CASES.items():
            with self.subTest(status=status):
                self.assertEqual(phase_status.classify(status), expected)

    def test_unknown_is_neither_open_nor_closed(self):
        self.assertFalse(phase_status.is_closed("deferred"))
        self.assertFalse(phase_status.is_open("deferred"))

    def test_cli_prints_class(self):
        out = subprocess.run(
            [sys.executable, str(LIB / "phase_status.py"), "classify", "implemented-partial"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        self.assertEqual(out, "open")


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CARD = textwrap.dedent(
    """\
    ---
    wp: 1
    phases:
      Ф1: completed
      Ф2: implemented
      Ф3: merged
      Ф4: pending
      Ф5: deferred
      Ф6: moved-to-wp-9
    ---
    body
    """
)
EXPECTED_NOT_CLOSED = ["Ф2", "Ф4", "Ф5"]


class Consumers(unittest.TestCase):
    def test_handoff_check_counts_everything_not_closed(self):
        path = ROOT / "DS-my-strategy" / "scripts" / "wp-handoff-check.py"
        if not path.is_file():
            self.skipTest("DS-my-strategy not present")
        mod = _load(path, "wp_handoff_check_under_test")
        self.assertEqual(mod.open_phases(CARD), EXPECTED_NOT_CLOSED)

    def test_archiver_treats_merged_and_moved_as_closed_not_implemented(self):
        mod = _load(ROOT / "scripts" / "wp-archive-closed-phases.py", "wp_archive_under_test")
        self.assertTrue(mod._phase_status.is_closed("merged"))
        self.assertFalse(mod._phase_status.is_closed("implemented"))
        self.assertFalse(mod._phase_status.is_closed("deferred"))

    def test_sync_bundle_lists_open_and_unknown_not_closed(self):
        card = ROOT / "scripts" / "tests" / "_phase_status_card.tmp.md"
        card.write_text(CARD, encoding="utf-8")
        try:
            script = ROOT / ".claude" / "scripts" / "wp-sync-bundle.sh"
            # Source only the extractor: run the function in a throwaway shell.
            body = subprocess.run(
                ["bash", "-c",
                 f'FIND_PYTHON3="{LIB}/find-python3.sh"; '
                 f'src=$(sed -n "/^extract_structured_open_phases() {{/,/^}}/p" "{script}"); '
                 f'eval "$src"; extract_structured_open_phases "{card}"'],
                capture_output=True, text=True,
            )
        finally:
            card.unlink()
        self.assertEqual(body.returncode, 0, body.stderr)
        listed = [line.split()[0] for line in body.stdout.splitlines()]
        self.assertEqual(listed, EXPECTED_NOT_CLOSED)
        self.assertIn("неизвестный статус: deferred", body.stdout)


if __name__ == "__main__":
    unittest.main()
