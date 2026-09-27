"""Exercise the real quarantine barrier with independent Git repositories."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class QuarantineScopeTest(unittest.TestCase):
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

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_barrier(self, extra_env=None):
        env = {**os.environ, 'ACTIVE_SEMAPHORES': str(self.active),
               'SESSION_DIR': str(self.sessions), 'IWE_AGENT': 'codex',
               **(extra_env or {})}
        result = subprocess.run(['bash', '-c', self.function +
                                 '\n_frozen_quarantine_commit_barrier "$ACTIVE_SEMAPHORES"'],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        return result.returncode

    def write(self, path=None, repo=None):
        text = self.header
        if path:
            text += 'file: ' + path + '\n'
            if repo:
                text += 'file_v2: ' + json.dumps({'repo': str(repo), 'path': path}) + '\n'
        self.quarantine.write_text(text)

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


if __name__ == '__main__':
    unittest.main()
