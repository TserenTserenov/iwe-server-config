"""Reject stale replacements of shared documents at the publication point.

Local fenced writers protect a checkout; this check plus fast-forward push
protects publication across worktrees and hosts. A moved document must be
read again and a new source change created, never silently cherry-picked.
"""
import re
import subprocess
import sys


def git(repo, *args):
    return subprocess.run(['git', '--no-replace-objects', '-C', repo, *args],
                          check=True, capture_output=True, timeout=15).stdout


def hot(path):
    return (path in {'docs/WP-REGISTRY.md', 'current/hypotheses-log.md'}
            or re.fullmatch(r'inbox/WP-([0-9]+)/WP-\1\.md', path) is not None)


def entry(repo, commit, path):
    return git(repo, 'ls-tree', '-z', commit, '--', ':(literal)' + path)


def check(repo, target, commits, resolved=None):
    expected, result = {}, {}
    for commit in commits:
        parents = git(repo, 'rev-list', '--parents', '-n', '1', commit).decode().split()
        if len(parents) != 2:
            raise ValueError('publication requires single-parent source commits')
        paths = git(repo, 'diff-tree', '--no-commit-id', '--no-renames', '--name-only',
                    '-r', '-z', commit).decode().split('\0')
        for path in filter(hot, paths):
            expected.setdefault(path, entry(repo, parents[1], path))
            result[path] = entry(repo, commit, path)
    for path in expected:
        current = entry(repo, target, path)
        if current not in (expected[path], result[path]):
            raise ValueError('hot-file version conflict; reread and rebuild source: ' + path)
        if resolved and entry(repo, resolved, path) != result[path]:
            raise ValueError('manual resume changes the declared hot-file result: ' + path)


if __name__ == '__main__':
    try:
        # A dash denotes no manually resumed result to verify.
        check(sys.argv[1], sys.argv[2], sys.argv[4:],
              None if sys.argv[3] == '-' else sys.argv[3])
    except (ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
