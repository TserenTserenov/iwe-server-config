"""Fixture test for scripts/convergence-report.py (WP-539 F21 B0a).

Builds a throwaway IWE_ROOT with one bare origin and four clones in known
states, plus a broker log, and checks the three report fields per repo.
"""

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "convergence-report.py"
GIT_ID = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]


def git(cwd, *args):
    subprocess.run(["git", *GIT_ID, "-C", str(cwd), *args], check=True, capture_output=True)


def commit(repo, name):
    (repo / name).write_text(name)
    git(repo, "add", name)
    git(repo, "commit", "-q", "-m", name)


class ConvergenceReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "IWE"
        self.root.mkdir()
        origin = base / "origin.git"
        subprocess.run(["git", *GIT_ID, "init", "-q", "--bare", str(origin)], check=True)
        seed = base / "seed"
        subprocess.run(["git", *GIT_ID, "clone", "-q", str(origin), str(seed)], check=True, capture_output=True)
        commit(seed, "a")
        git(seed, "push", "-q", "origin", "main")
        for name in ("equal", "behind", "ahead"):
            subprocess.run(["git", *GIT_ID, "clone", "-q", str(origin), str(self.root / name)],
                           check=True, capture_output=True)
        commit(seed, "b")
        git(seed, "push", "-q", "origin", "main")
        git(self.root / "equal", "pull", "-q", "--ff-only")
        git(self.root / "behind", "fetch", "-q")
        commit(self.root / "ahead", "c")
        local = self.root / "local"
        local.mkdir()
        git(local, "init", "-q")
        commit(local, "x")
        broker = self.root / ".iwe-runtime" / "refs-sync-broker"
        broker.mkdir(parents=True)
        stamp = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        (broker / "broker.log").write_text(
            f"{stamp} OK equal <- origin +refs/heads/main:refs/remotes/origin/main\n"
            f"{stamp} FAIL behind <- origin timeout\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_report(self, *extra):
        env = dict(os.environ, HOME=self.tmp.name)  # no real sync state file
        proc = subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root), "--host", "t", *extra],
                              capture_output=True, text=True, env=env)
        return proc

    def test_three_fields_per_repo(self):
        proc = self.run_report("--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = {r["repo"]: r for r in json.loads(proc.stdout)["repos"]}
        self.assertEqual(sorted(rows), ["ahead", "behind", "equal", "local"])
        self.assertEqual(rows["equal"]["relation"], "equal")
        self.assertEqual(rows["behind"]["relation"], "behind -1")
        # Relation is against the locally known upstream ref: "ahead" never
        # fetched commit b, so it reads ahead +1, not diverged.
        self.assertEqual(rows["ahead"]["relation"], "ahead +1")
        self.assertTrue(rows["local"]["relation"].startswith("no-upstream"))
        # Only a logged OK counts as a confirmed fetch; FAIL and silence are unknown.
        self.assertEqual(rows["equal"]["fetch"], "5m")
        self.assertEqual(rows["behind"]["fetch"], "unknown")
        self.assertEqual(rows["local"]["fetch"], "unknown")
        self.assertEqual(rows["equal"]["block"], "")

    def test_text_lists_problems_and_completeness(self):
        proc = self.run_report("--problems-only")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = proc.stdout
        self.assertIn("найдено 4, проверено 4, ошибок 0, проблемных 3", out)
        self.assertIn("- behind: behind -1; получено с GitHub: unknown", out)
        self.assertNotIn("- equal:", out)
        self.assertNotIn("совпадают", out)


if __name__ == "__main__":
    unittest.main()
