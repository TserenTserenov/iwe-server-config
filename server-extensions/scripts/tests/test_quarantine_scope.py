"""Exercise the real quarantine barrier with independent Git repositories."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class BarrierHarness(unittest.TestCase):
    """The real commit-barrier function, extracted from session-guard.sh, run against a throwaway Git repo."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.sessions = self.root / 'sessions'
        self.sessions.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        (self.repo / 'own.txt').write_text('base')
        self.git('add', 'own.txt')
        self.git('-c', 'commit.gpgsign=false', 'commit', '-qm', 'base')
        (self.repo / 'own.txt').write_text('changed')
        self.git('add', 'own.txt')
        self.active = self.sessions / 'codex-current.open'
        self.active.write_text('agent: codex\nsession_id: current\nwp: WP-530\nfile: own.txt\n')
        self.quarantine = self.sessions / 'foreign-old.open.orphaned-dead-interactive.recovery-pending'
        self.header = ('agent: foreign\nsession_id: old\nwp: WP-530\n'
                       'recovery_version: terminal-proof/v1\nrecovery_id: ' + 'a'*64 +
                       '\nrecovery_terminal_sha256: ' + 'b'*64 + '\n')
        guard = Path(__file__).parents[1] / 'session-guard.sh'
        code = guard.read_text().split('_frozen_quarantine_commit_barrier() {', 1)[1]
        self.function = '_frozen_quarantine_commit_barrier() {' + code.split('\nscope_has_path()', 1)[0]
        identity = guard.read_text().split('_runtime_harness_session_id() {', 1)[1].split('\n}', 1)[0]
        self.function = '_runtime_harness_session_id() {' + identity + '\n}\n' + self.function
        # WP-561 Ф25: the classifier takes its sentinel set from the script's own constant.
        self.sentinel_def = re.search(r'^readonly SG_WP_SENTINELS=.*$', guard.read_text(), re.M).group(0)
        self.function = self.sentinel_def + '\n' + self.function

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_barrier(self, extra_env=None, active=None, function=None):
        env = {**os.environ, 'ACTIVE_SEMAPHORES': active or str(self.active),
               'SESSION_DIR': str(self.sessions), 'IWE_AGENT': 'codex',
               **(extra_env or {})}
        result = subprocess.run(['bash', '-c', (function or self.function) +
                                 '\n_frozen_quarantine_commit_barrier "$ACTIVE_SEMAPHORES"'],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        self.stderr = result.stderr
        return result.returncode

    def write(self, path=None, repo=None):
        text = self.header
        if path:
            text += 'file: ' + path + '\n'
            if repo:
                text += 'file_v2: ' + json.dumps({'repo': str(repo), 'path': path}) + '\n'
        self.quarantine.write_text(text)


class QuarantineScopeTest(BarrierHarness):
    def test_same_wp_unrelated_file_and_empty_scope_do_not_block(self):
        for path in ('other.txt', None):
            with self.subTest(path=path):
                self.write(path)
                self.assertEqual(self.run_barrier(), 0)

    def test_empty_scope_still_freezes_own_isolated_checkout(self):
        self.header += 'isolated_worktree: ' + str(self.repo) + '\n'
        self.write()
        self.assertEqual(self.run_barrier(), 1)
        self.header = self.header.replace(str(self.repo), str(self.root / 'other'))
        self.write()
        self.assertEqual(self.run_barrier(), 0)

    def test_empty_scope_still_freezes_exact_harness_owner(self):
        self.header += 'harness_session_id: frozen-harness\n'
        self.write()
        self.assertEqual(self.run_barrier({'IWE_AGENT': 'foreign',
                                          'CLAUDE_CODE_SESSION_ID': 'frozen-harness'}), 1)
        self.assertEqual(self.run_barrier({'IWE_AGENT': 'foreign',
                                          'CLAUDE_CODE_SESSION_ID': 'other-harness'}), 0)

    def test_codex_legacy_harness_and_explicit_agent_stay_frozen(self):
        self.header = self.header.replace('agent: foreign', 'agent: codex')
        self.quarantine = self.sessions / 'codex-old.open.orphaned-dead-interactive.recovery-pending'
        self.header += 'harness_session_id: frozen-harness\n'
        self.write()
        for identity in (
            {'IWE_AGENT': 'codex', 'CODEX_THREAD_ID': '',
             'CLAUDE_CODE_SESSION_ID': 'frozen-harness'},
            {'AGENT': 'codex', 'IWE_AGENT': '', 'CODEX_THREAD_ID': 'frozen-harness'},
        ):
            with self.subTest(identity=identity):
                self.assertEqual(self.run_barrier(identity), 1)

    def test_legacy_overlap_still_blocks(self):
        self.write('own.txt')
        self.assertEqual(self.run_barrier(), 1)

    def test_repository_qualified_scope(self):
        self.write('own.txt', self.root / 'other' / '.git')
        self.assertEqual(self.run_barrier(), 0)
        self.write('own.txt', self.repo / '.git')
        self.assertEqual(self.run_barrier(), 1)

    def test_directory_boundary(self):
        self.git('restore', '--staged', 'own.txt')
        (self.repo / 'foo.bak').write_text('x')
        self.git('add', '-f', 'foo.bak')
        self.write('foo/')
        self.assertEqual(self.run_barrier(), 0)
        (self.repo / 'foo').mkdir()
        (self.repo / 'foo' / 'inside').write_text('x')
        self.git('add', 'foo/inside')
        self.assertEqual(self.run_barrier(), 1)

    def test_old_claim_not_suppressed_by_new_other_repo_claim(self):
        self.header += 'file: own.txt\n'
        self.write('own.txt', self.root / 'other' / '.git')
        self.assertEqual(self.run_barrier(), 1)

    def test_rename_and_deletion_are_intersections(self):
        self.git('mv', 'own.txt', 'renamed.txt')
        self.write('own.txt')
        self.assertEqual(self.run_barrier(), 1)

    def test_malformed_unrelated_metadata_does_not_block_related_does(self):
        self.header = 'broken metadata\n'
        self.write('other.txt')
        self.assertEqual(self.run_barrier(), 0)
        self.write('own.txt')
        self.assertEqual(self.run_barrier(), 2)


class ActiveSemaphoreWpTest(BarrierHarness):
    """WP-561 Ф25: what the barrier does with an ACTIVE semaphore whose wp: it cannot classify."""

    def write_active(self, wp, path='own.txt', name='codex-current.open'):
        target = self.sessions / name
        target.write_text('agent: codex\nsession_id: current\nwp: %s\nfile: %s\n' % (wp, path))
        return target

    def test_bad_wp_on_intersecting_scope_blocks_and_names_the_value(self):
        self.write_active('week-review-w39')
        self.assertEqual(self.run_barrier(), 2)
        self.assertIn("wp: 'week-review-w39'", self.stderr)
        self.assertIn('WP-<число>, day-close, unknown', self.stderr)
        # close selects by the OWNER's agent, and the committer is usually a different one
        self.assertIn("session-guard.sh close --wp 'week-review-w39' --agent codex", self.stderr)

    def test_bad_wp_on_non_intersecting_scope_does_not_block(self):
        self.write_active('week-review-w39', path='other.txt')
        self.assertEqual(self.run_barrier(), 0)

    def test_valid_semaphore_beside_bad_non_intersecting_one_does_not_block(self):
        valid = self.write_active('WP-530')
        bad = self.write_active('week-review-w39', path='other.txt', name='codex-other.open')
        self.assertEqual(self.run_barrier(active='%s\n%s' % (valid, bad)), 0)

    def test_unreadable_active_semaphore_blocks_with_scope_unknown_reason(self):
        self.active.write_text('')
        self.assertEqual(self.run_barrier(), 2)
        self.assertIn('область семафора неизвестна', self.stderr)
        self.assertNotIn("wp: '", self.stderr)

    def test_legacy_spellings_stay_classifiable(self):
        # `open` is strict now; semaphores written before that must not start blocking commits.
        for wp in ('Unknown', 'DAY-CLOSE', '578'):
            with self.subTest(wp=wp):
                self.write_active(wp)
                self.assertEqual(self.run_barrier(), 0)

    def test_ambient_environment_cannot_widen_the_sentinel_set(self):
        self.write_active('week-review-w39')
        for name in ('SG_WP_SENTINELS', 'NON_PRODUCT_WP_SENTINELS'):
            with self.subTest(name=name):
                self.assertEqual(self.run_barrier({name: 'unknown day-close week-review-w39'}), 2)
                # rc 2 alone would also come from a broken harness; the reason proves the wp was judged
                self.assertIn("wp: 'week-review-w39'", self.stderr)

    def test_sentinel_naming_a_real_wp_is_reported_as_evasion_not_as_unreadable(self):
        self.active.write_text('agent: codex\nsession_id: current\nwp: unknown\nscheduled_owner: WP-484\nfile: own.txt\n')
        self.assertEqual(self.run_barrier(), 2)
        self.assertIn('обходом заморозки', self.stderr)
        self.assertIn('scheduled_owner: WP-484', self.stderr)
        self.assertNotIn('нечитаем', self.stderr)

    def test_evasion_message_names_the_offending_line_even_when_it_is_the_slug(self):
        self.active.write_text('agent: codex\nsession_id: current\nwp: unknown\nslug: wp-561-review\nfile: own.txt\n')
        self.assertEqual(self.run_barrier(), 2)
        self.assertIn('slug: wp-561-review', self.stderr)
        self.assertIn('slug:', self.stderr.split('лечение:')[1])

    def test_missing_or_repeated_wp_field_is_named_not_reported_as_unknown_scope(self):
        for body in ('agent: codex\nsession_id: current\nfile: own.txt\n',
                     'agent: codex\nsession_id: current\nwp: WP-530\nwp: WP-531\nfile: own.txt\n',
                     'agent: codex\nsession_id: current\nwp: \nfile: own.txt\n'):
            with self.subTest(body=body):
                self.active.write_text(body)
                self.assertEqual(self.run_barrier(), 2)
                self.assertIn('поле wp: отсутствует, пусто или задано дважды', self.stderr)
                self.assertNotIn('область семафора неизвестна', self.stderr)

    def test_malformed_housekeeping_semaphore_gets_its_own_reason(self):
        self.active.write_text('agent: codex\nhousekeeping: sweep\nslug: sweep\nwp: WP-530\nfile: own.txt\n')
        self.assertEqual(self.run_barrier(), 2)
        self.assertIn('housekeeping-семафор', self.stderr)
        self.assertNotIn('область семафора неизвестна', self.stderr)

    def test_lost_sentinel_set_fails_closed(self):
        self.write_active('unknown')
        self.assertEqual(self.run_barrier(function=self.function.replace(self.sentinel_def, '')), 2)
        self.assertIn('sentinel wp set was not handed', self.stderr)


if __name__ == '__main__':
    unittest.main()
