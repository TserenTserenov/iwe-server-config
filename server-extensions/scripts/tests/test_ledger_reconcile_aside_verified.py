"""WP-484 F327: a set-aside copy that changed after the check is never deleted by the reconcile."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
import unittest.mock

LIB = Path(__file__).resolve().parents[1] / "lib" / "ledger-reconcile-published.py"
EVENT_DIFF = Path(os.environ.get("IWE_ROOT", str(Path.home() / "IWE"))) / "DS-my-strategy/scripts/lib/ledger-event-diff.py"


@unittest.skipUnless(EVENT_DIFF.exists(), f"journal event diff not installed at {EVENT_DIFF}")
class DropVerifiedAside(unittest.TestCase):
    def setUp(self) -> None:
        spec = importlib.util.spec_from_file_location("ledger_reconcile_published", LIB)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def aside(self, tmp: str, contents: dict) -> Path:
        aside = Path(tmp) / "aside"
        aside.mkdir()
        for index, data in enumerate(contents):
            (aside / str(index)).write_bytes(data)
            os.chmod(aside / str(index), 0o644)
        return aside

    def test_unchanged_copies_are_dropped_and_the_directory_goes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            files = {"a.md": (b"one\n", 0o644), "b.md": (b"two\n", 0o644)}
            aside = self.aside(tmp, [b"one\n", b"two\n"])
            dropped, kept = self.mod.drop_verified_aside(aside, files)
            self.assertEqual((dropped, kept), (["a.md", "b.md"], []))
            self.assertFalse(aside.exists())

    def test_a_copy_a_writer_changed_is_kept_with_its_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            files = {"a.md": (b"one\n", 0o644), "b.md": (b"two\n", 0o644)}
            aside = self.aside(tmp, [b"one\n", b"two\nappended by a running writer\n"])
            dropped, kept = self.mod.drop_verified_aside(aside, files)
            self.assertEqual((dropped, kept), (["a.md"], ["b.md"]))
            self.assertEqual((aside / "1").read_bytes(), b"two\nappended by a running writer\n")
            self.assertFalse((aside / "0").exists())

    def test_a_write_between_the_check_and_the_unlink_is_put_back(self) -> None:
        # Codex review 23.11: a writer holding the file open can append after the comparison.
        with tempfile.TemporaryDirectory() as tmp:
            files = {"a.md": (b"one\n", 0o644)}
            aside = self.aside(tmp, [b"one\n"])
            real_unlink = os.unlink

            def unlink_after_a_late_write(path, *args, **kwargs):
                with open(path, "ab") as stream:
                    stream.write(b"late line\n")
                real_unlink(path, *args, **kwargs)

            with unittest.mock.patch.object(self.mod.os, "unlink", unlink_after_a_late_write):
                dropped, kept = self.mod.drop_verified_aside(aside, files)
            self.assertEqual((dropped, kept), ([], ["a.md"]))
            self.assertEqual((aside / "0").read_bytes(), b"one\nlate line\n")

    def test_a_file_that_appears_in_the_aside_directory_is_not_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            files = {"a.md": (b"one\n", 0o644)}
            aside = self.aside(tmp, [b"one\n"])
            real_unlink = os.unlink

            def unlink_while_a_stranger_arrives(path, *args, **kwargs):
                (aside / "stranger").write_bytes(b"not ours\n")
                real_unlink(path, *args, **kwargs)

            with unittest.mock.patch.object(self.mod.os, "unlink", unlink_while_a_stranger_arrives):
                dropped, kept = self.mod.drop_verified_aside(aside, files)
            self.assertEqual((dropped, kept), (["a.md"], []))
            self.assertEqual((aside / "stranger").read_bytes(), b"not ours\n")


if __name__ == "__main__":
    unittest.main()
