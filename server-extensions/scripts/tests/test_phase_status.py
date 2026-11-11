"""Tests for scripts/lib/phase_status.py and its three consumers (WP-484 Ф299 п.1)."""
import importlib.util
import json
import subprocess
import sys
import tempfile
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
    "deferred": "parked",
    "defer": "parked",
    "  Deferred ": "parked",
    "cancelled": "closed",
    "waiting": "unknown",
    "queued": "unknown",
    "frozen-off-path": "unknown",
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
        self.assertFalse(phase_status.is_closed("waiting"))
        self.assertFalse(phase_status.is_open("waiting"))

    def test_parked_is_neither_open_nor_closed_nor_unknown(self):
        self.assertFalse(phase_status.is_open("deferred"))
        self.assertFalse(phase_status.is_closed("deferred"))
        self.assertTrue(phase_status.is_parked("defer"))
        got = {"Ф1": "deferred", "Ф2": "defer", "Ф3": "waiting", "Ф4": "pending"}
        self.assertEqual(phase_status.parked_ids(got), ["Ф1", "Ф2"])
        self.assertEqual(phase_status.unknown_ids(got), ["Ф3"])
        self.assertEqual(phase_status.open_ids(got), ["Ф4"])

    def test_cli_prints_class(self):
        out = subprocess.run(
            [sys.executable, str(LIB / "phase_status.py"), "classify", "implemented-partial"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        self.assertEqual(out, "open")


def _fm(text: str) -> list[str]:
    return textwrap.dedent(text).strip("\n").splitlines()


class ParsePhases(unittest.TestCase):
    def test_map_form(self):
        got = phase_status.parse_phases(_fm("""
            wp: 1
            phases:
              Ф1: completed
              Ф2: "implemented-partial"   # waits for acceptance
              Ф3: moved-to-wp-9
            next: x
        """))
        self.assertEqual(got, {"Ф1": "completed", "Ф2": "implemented-partial", "Ф3": "moved-to-wp-9"})

    def test_list_form_keeps_hyphenated_status_and_reads_bare_numbers(self):
        got = phase_status.parse_phases(_fm("""
            phases:
              - id: Ф7
                status: implemented-partial
              - id: 8
                status: "pending"
              - id: not-a-phase
                status: done
        """))
        self.assertEqual(got, {"Ф7": "implemented-partial", "Ф8": "pending"})

    def test_sub_phase_and_letter_suffix_ids_are_kept_whole(self):
        got = phase_status.parse_phases(_fm("""
            phases:
              Ф16: done
              Ф16.2: pending
              Ф5а: blocked
        """))
        self.assertEqual(got, {"Ф16": "done", "Ф16.2": "pending", "Ф5а": "blocked"})
        self.assertEqual(phase_status.open_ids(got), ["Ф5а", "Ф16.2"])

    def test_flow_mapping_entry_ignores_status_text_inside_a_quoted_title(self):
        got = phase_status.parse_phases(_fm("""
            phases:
              - {id: Ф1, title: "a, b: status: x", status: done}
              - {id: "2", status: pending}
              - {title: 'q, id: Ф9', id: Ф3, status: "implemented-partial"}
              - {id: Ф4, status: }
        """))
        self.assertEqual(got, {"Ф1": "done", "Ф2": "pending", "Ф3": "implemented-partial"})

    def test_nested_form_reads_the_status_on_the_next_line(self):
        got = phase_status.parse_phases(_fm("""
            phases:
              Ф7:
                status: in_progress
                note: x
              Ф8: pending
        """))
        self.assertEqual(got, {"Ф7": "in_progress", "Ф8": "pending"})

    def test_latin_ids_and_free_form_give_empty_not_none(self):
        # present but unreadable: callers must not read this as "no open phases"
        self.assertEqual(phase_status.parse_phases(_fm("phases:\n  f1: done\n  F2: pending\n")), {})
        self.assertEqual(phase_status.parse_phases(_fm('phases:\n  - Ф1-Ф3: "done - x"\n')), {})

    def test_statuses_seen_on_live_cards_are_unknown_not_open(self):
        got = {pid: status for pid, status in zip(
            ("Ф1", "Ф2", "Ф3", "Ф4"), ("frozen-off-path", "diagnosed", "queued", "proposal"))}
        self.assertEqual(phase_status.open_ids(got), [])
        self.assertEqual(phase_status.unknown_ids(got), ["Ф1", "Ф2", "Ф3", "Ф4"])

    def test_card_without_phases_key_is_none_not_empty(self):
        self.assertIsNone(phase_status.parse_phases(_fm("""
            wp: 1
            status: in_progress
        """)))
        self.assertEqual(phase_status.parse_phases(_fm("""
            phases:
            wp: 1
        """)), {})

    def test_block_stops_at_next_top_level_key(self):
        got = phase_status.parse_phases(_fm("""
            phases:
              Ф1: pending

              Ф2: done
            handoff_snapshot:
              - ref: WP-1
                observed_status: Ф9
        """))
        self.assertEqual(got, {"Ф1": "pending", "Ф2": "done"})

    def test_unknown_is_reported_apart_and_is_not_open(self):
        got = {"Ф1": "pending", "Ф2": "waiting", "Ф3": "done", "Ф4": ""}
        self.assertEqual(phase_status.open_ids(got), ["Ф1"])
        self.assertEqual(phase_status.unknown_ids(got), ["Ф2", "Ф4"])

    def test_frontmatter_lines_between_the_two_fences(self):
        self.assertEqual(phase_status.frontmatter_lines("---\na: 1\n---\nbody\n---\n"), ["a: 1"])
        self.assertEqual(phase_status.frontmatter_lines("no fence\n"), [])
        self.assertEqual(phase_status.frontmatter_lines("---\nunclosed\n"), [])

    def test_id_grammar_equals_the_heading_scanner_grammar(self):
        sections = _load(LIB / "phase_sections.py", "phase_sections_under_test")
        self.assertEqual(phase_status.PHASE_ID, sections.PHASE_ID)


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
      Ф5: waiting
      Ф6: moved-to-wp-9
    ---
    body
    """
)
EXPECTED_NOT_CLOSED = ["Ф2", "Ф4", "Ф5"]   # open + unknown: what the bundle LISTS
EXPECTED_OPEN = ["Ф2", "Ф4"]               # what is counted open (Ф5 is unknown)


class ArchiverDiagnostics(unittest.TestCase):
    """The archiver report carries the open list from `phases:` and how the sections disagree (Ф299 п.4)."""

    def _report(self, card_text: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            card_dir = Path(tmp) / "inbox" / "WP-9301"
            card_dir.mkdir(parents=True)
            (card_dir / "WP-9301.md").write_text(card_text, encoding="utf-8")
            out = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "wp-archive-closed-phases.py"), "9301", "--json",
                 "--governance-repo", tmp],
                capture_output=True, text=True,
            )
        return json.loads(out.stdout)

    def test_phases_card_lists_open_records_and_diagnostics(self):
        report = self._report(
            "---\nwp: 9301\nphases:\n  Ф1: pending\n  Ф2: done\n  Ф3: waiting\n  Ф4: pending\n---\n"
            "### Ф1 — a\n\nbody\n\n### Ф2 ✅ — b\n\nbody\n\n### Ф5 — no record\n\nbody\n"
        )
        self.assertTrue(report["phases_present"])
        self.assertEqual(report["open_by_record"], ["Ф1", "Ф4"])
        self.assertEqual(report["unknown_status"], ["Ф3"])
        self.assertEqual(report["sections_unaccounted"], ["Ф5"])
        self.assertEqual(report["open_without_section"], ["Ф4"])

    def test_legacy_card_without_phases_block_is_marked_and_has_no_diagnostics(self):
        report = self._report("---\nwp: 9301\n---\n### Ф1 — a\n\nbody\n")
        self.assertFalse(report["phases_present"])
        self.assertEqual(report["open_by_record"], [])
        self.assertEqual(report["sections_unaccounted"], [])

    def test_list_form_with_quoted_bare_number_is_read(self):
        report = self._report(
            "---\nwp: 9301\nphases:\n  - id: \"6\"\n    status: implemented-partial\n---\n### Ф6 — a\n\nbody\n"
        )
        self.assertEqual(report["open_by_record"], ["Ф6"])

    def test_unreadable_block_is_read_by_headings_and_says_so(self):
        report = self._report("---\nwp: 9301\nphases:\n  f1: in_progress\n---\n### Ф1 — open heading\n\nbody\n")
        self.assertFalse(report["phases_present"])
        self.assertTrue(report["phases_unreadable"])
        self.assertEqual([n["phase"] for n in report["no_terminal_marker"]], ["Ф1"])

    def test_record_wins_over_heading_marker(self):
        report = self._report("---\nwp: 9301\nphases:\n  Ф1: pending\n---\n### Ф1 ✅ — closed heading\n\nbody\n")
        self.assertEqual([c["phase"] for c in report["candidates"]], [])
        self.assertEqual(report["open_by_record"], ["Ф1"])


class Consumers(unittest.TestCase):
    def test_handoff_check_counts_only_open_not_unknown(self):
        path = ROOT / "DS-my-strategy" / "scripts" / "wp-handoff-check.py"
        if not path.is_file():
            self.skipTest("DS-my-strategy not present")
        mod = _load(path, "wp_handoff_check_under_test")
        self.assertEqual(mod.open_phases(CARD), EXPECTED_OPEN)

    def test_archiver_treats_merged_and_moved_as_closed_not_implemented(self):
        mod = _load(ROOT / "scripts" / "wp-archive-closed-phases.py", "wp_archive_under_test")
        self.assertTrue(mod._phase_status.is_closed("merged"))
        self.assertFalse(mod._phase_status.is_closed("implemented"))
        self.assertFalse(mod._phase_status.is_closed("waiting"))

    def test_sync_bundle_lists_open_and_unknown_not_closed(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        card = Path(tmp.name) / "card.md"
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
            card.unlink(missing_ok=True)
        self.assertEqual(body.returncode, 0, body.stderr)
        listed = [line.split()[0] for line in body.stdout.splitlines()]
        self.assertEqual(listed, EXPECTED_NOT_CLOSED)
        self.assertIn("неизвестный статус: waiting", body.stdout)

    def test_sync_bundle_count_does_not_count_unknown_as_open(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        card = Path(tmp.name) / "card.md"
        card.write_text(CARD, encoding="utf-8")
        try:
            script = ROOT / ".claude" / "scripts" / "wp-sync-bundle.sh"
            body = subprocess.run(
                ["bash", "-c",
                 f'FIND_PYTHON3="{LIB}/find-python3.sh"; '
                 f'for fn in extract_structured_open_phases count_open_phases; do '
                 f'src=$(sed -n "/^$fn() {{/,/^}}/p" "{script}"); eval "$src"; done; '
                 f'count_open_phases "{card}"'],
                capture_output=True, text=True,
            )
        finally:
            card.unlink(missing_ok=True)
        self.assertEqual(body.stdout.strip(), "2", body.stderr)


if __name__ == "__main__":
    unittest.main()
