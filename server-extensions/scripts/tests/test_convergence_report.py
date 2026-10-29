"""Fixture test for scripts/convergence-report.py (WP-539 F21 B0a).

Builds a throwaway IWE_ROOT with one bare origin and clones in known states,
a broker log and a canon sync state file, and checks the report per repo.
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


def clone(origin, dest):
    subprocess.run(["git", *GIT_ID, "clone", "-q", str(origin), str(dest)], check=True, capture_output=True)


def commit(repo, name):
    (repo / name).write_text(name)
    git(repo, "add", name)
    git(repo, "commit", "-q", "-m", name)


def stamp(minutes_ago):
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


class ConvergenceReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "IWE"
        self.root.mkdir()
        origin = base / "origin.git"
        subprocess.run(["git", *GIT_ID, "init", "-q", "--bare", str(origin)], check=True)
        seed = base / "seed"
        clone(origin, seed)
        commit(seed, "a")
        git(seed, "push", "-q", "origin", "main")
        for name in ("equal", "unconfirmed", "behind", "stale-ahead", "diverged", "DS-my-strategy", "stale-ok"):
            clone(origin, self.root / name)
        commit(seed, "b")
        git(seed, "push", "-q", "origin", "main")
        for name in ("equal", "unconfirmed", "DS-my-strategy", "stale-ok"):
            git(self.root / name, "pull", "-q", "--ff-only")
        git(self.root / "behind", "fetch", "-q")
        commit(self.root / "stale-ahead", "c")      # never fetched b
        commit(self.root / "diverged", "d")
        git(self.root / "diverged", "fetch", "-q")  # knows b, has d
        local = self.root / "local"
        local.mkdir()
        git(local, "init", "-q")
        commit(local, "x")
        broken = self.root / "broken"
        broken.mkdir()
        (broken / ".git").write_text("gitdir: /nonexistent/gitdir\n")

        broker = self.root / ".iwe-runtime" / "refs-sync-broker"
        broker.mkdir(parents=True)
        ok = f"{stamp(5)} OK {{}} <- origin +refs/heads/{{}}:refs/remotes/origin/{{}}\n"
        (broker / "broker.log").write_text(
            ok.format("equal", "main", "main")
            + ok.format("DS-my-strategy", "main", "main")
            + f"{stamp(60 * 24 * 30)} OK stale-ok <- origin +refs/heads/main:refs/remotes/origin/main\n"
            # Confirms a different ref than "unconfirmed" tracks: must not count.
            + ok.format("unconfirmed", "release", "release")
            + f"{stamp(5)} FAIL behind <- origin timeout\n")
        self.state = base / "sync-state.json"

    def tearDown(self):
        self.tmp.cleanup()

    def run_report(self, *extra, host_id="mac", label="t"):
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), "--host", label,
             "--state-file", str(self.state), *extra],
            capture_output=True, text=True, env=dict(os.environ, CONVERGENCE_HOST_ID=host_id))
        return proc

    def rows(self):
        proc = self.run_report("--json")
        self.assertIn(proc.returncode, (0, 1), proc.stderr)
        data = json.loads(proc.stdout)
        return {r["repo"]: r for r in data["repos"]}, data["sources"], proc.returncode

    def test_relation_and_fetch_per_repo(self):
        self.state.write_text(json.dumps({"consecutive_fails": 0, "last_run_ts": stamp(3)}))
        rows, _, rc = self.rows()
        self.assertEqual(rc, 1)  # the broken repo is an error, not a pass
        self.assertEqual(rows["equal"]["relation"], "equal")
        self.assertEqual(rows["behind"]["relation"], "behind -1")
        # Relation is against the locally known ref: never-fetched b reads ahead.
        self.assertEqual(rows["stale-ahead"]["relation"], "ahead +1")
        self.assertEqual(rows["diverged"]["relation"], "diverged +1/-1")
        self.assertTrue(rows["local"]["relation"].startswith("no-upstream"))
        self.assertFalse(rows["local"]["error"])
        self.assertTrue(rows["broken"]["error"])
        self.assertEqual(rows["equal"]["fetch"], "5m")
        self.assertEqual(rows["unconfirmed"]["fetch"], "unknown")  # OK was for another ref
        self.assertEqual(rows["behind"]["fetch"], "unknown")       # FAIL is not evidence
        self.assertEqual(rows["DS-my-strategy"]["block"], "")

    def test_text_groups_unconfirmed_separately(self):
        self.state.write_text(json.dumps({"consecutive_fails": 0, "last_run_ts": stamp(3)}))
        out = self.run_report("--problems-only").stdout
        self.assertIn("найдено 9, проверено 8, ошибок 1", out)
        # A 30-day-old confirmation is shown as a problem with its age, not as confirmed.
        self.assertIn("- stale-ok: equal; данные с сервера получены: 30d (устарело)", out)
        self.assertIn("- behind: behind -1; данные с сервера получены: unknown", out)
        self.assertIn("совпадение не подтверждено: unconfirmed", out)
        self.assertNotIn("- equal:", out)
        self.assertNotIn("совпадение подтверждено:", out)
        self.assertIn("broker.log: 4 подтверждений", out)

    def test_canon_block_from_state(self):
        self.state.write_text(json.dumps({
            "consecutive_fails": 0, "last_run_ts": stamp(180), "behind_since_ts": stamp(240)}))
        block = self.rows()[0]["DS-my-strategy"]["block"]
        # Zero fails is not "no blocker": behind for 4h and no run for 3h.
        self.assertIn("позади с GitHub уже 4h", block)
        self.assertIn("синхронизатор не запускался 3h", block)
        self.assertEqual(self.rows()[0]["equal"]["block"], "")

    def test_bad_state_is_reported_not_fatal(self):
        self.state.write_text(json.dumps({"consecutive_fails": "many"}))
        rows, sources, _ = self.rows()
        self.assertEqual(rows["DS-my-strategy"]["block"], "состояние синхронизатора не читается")
        self.assertIn("состояние синхронизатора: ошибка (ValueError)", sources)
        self.assertEqual(rows["equal"]["relation"], "equal")  # rest of the report survives

    def write_registry(self, text):
        path = Path(self.tmp.name) / "registry.yaml"
        path.write_text(text)
        return str(path)

    def test_registry_categories_and_coverage_note(self):
        registry = self.write_registry(
            "version: 1\nrepos:\n"
            "  - {repo_id: equal, class: undecided, checkouts: [{host: mac, path: equal}]}\n"
            "  - {repo_id: ghost, class: undecided, checkouts: [{host: mac, path: ghost}]}\n"
            "  - {repo_id: cech, class: undecided, checkouts: [{host: tsekh-1, path: behind}]}\n")
        proc = self.run_report("--registry", registry)
        out = proc.stdout
        self.assertIn("реестр сходимости: записей 3; найдено в реестре 1", out)
        self.assertIn("в реестре, но не найдено: ghost", out)
        self.assertIn("присутствие на этом хосте не ожидается: behind", out)
        self.assertRegex(out, r"вне реестра \d+: .*unconfirmed")
        self.assertNotRegex(out, r"вне реестра \d+: .*\bbehind\b")  # registered for the other host only
        self.assertIn("полнота обхода: корень и каталоги первого уровня; вложенные репозитории не видны", out)

    def test_registry_host_comes_from_the_machine_not_the_display_label(self):
        """Regression: the digest labels the server 'Цех'; matching on that label made it read as the Mac."""
        registry = self.write_registry(
            "version: 1\nrepos:\n"
            "  - {repo_id: equal, class: undecided,"
            " checkouts: [{host: mac, path: equal}, {host: tsekh-1, path: behind}]}\n")
        out = self.run_report("--registry", registry, host_id="tsekh-1", label="Цех").stdout
        self.assertIn("найдено в реестре 1", out)           # 'behind' is this host's checkout
        self.assertIn("присутствие на этом хосте не ожидается: equal", out)
        self.assertNotIn("в реестре, но не найдено", out)

    def test_missing_registry_is_loud_and_rest_of_report_survives(self):
        proc = self.run_report("--registry", str(Path(self.tmp.name) / "nope.yaml"))
        self.assertIn("реестр сходимости НЕ РАБОТАЕТ (1 ош.): нет файла реестра: nope.yaml", proc.stdout)
        self.assertIn("полнота обхода:", proc.stdout)
        self.assertIn("найдено 9", proc.stdout)

    def test_script_piped_on_stdin_reports_registry_unavailable_not_crash(self):
        """The old morning digest feeds the script on stdin (`python3 -`): no __file__, no siblings."""
        proc = subprocess.run(
            [sys.executable, "-", "--root", str(self.root), "--host", "t", "--state-file", str(self.state)],
            input=SCRIPT.read_text(encoding="utf-8"), capture_output=True, text=True)
        self.assertIn(proc.returncode, (0, 1), proc.stderr)
        self.assertIn("реестр сходимости НЕ РАБОТАЕТ", proc.stdout)
        self.assertIn("со стандартного ввода", proc.stdout)
        self.assertIn("найдено 9", proc.stdout)

    def test_registry_with_fetch_permission_is_rejected_in_report(self):
        registry = self.write_registry(
            "version: 1\nrepos:\n"
            "  - {repo_id: equal, class: undecided, fetch_allowed: true,"
            " checkouts: [{host: mac, path: equal}]}\n")
        data = json.loads(self.run_report("--registry", registry, "--json").stdout)
        self.assertEqual(data["registry"]["state"], "unavailable")
        self.assertTrue(any("fetch_allowed здесь запрещён" in e for e in data["registry"]["errors"]))
        self.assertEqual(len(data["repos"]), 9)  # per-repo facts are not replaced by registry state


if __name__ == "__main__":
    unittest.main()
