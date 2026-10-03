"""Real Git regressions for publication receipts (WP-561 F23)."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "publication_receipt", Path(__file__).parents[1] / "lib/publication_receipt.py")
receipt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)


class PublicationReceiptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-qb", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("remote", "add", "origin", str(self.root / "remote.git"))
        self.base = self.commit("a.txt", "base\n")
        self.sem = self.root / "codex-one.open"
        self.sem.write_text("agent: codex\nsession_id: one\nwp: WP-561\n")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if content is None:
            target.unlink()
        else:
            target.write_text(content)
        self.git("add", "--", path)
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "change " + path)
        return self.git("rev-parse", "HEAD")

    def claim(self, source):
        with self.sem.open("a") as out:
            out.write("commit: repo " + source + "\n")

    def published(self, commit):
        self.git("update-ref", "refs/remotes/origin/main", commit)

    def record(self, anchor):
        return receipt.record(self.repo, self.sem, "repo", anchor)

    def verify(self, source, remote):
        return receipt.verify(self.repo, self.sem, "repo", source, remote)

    def test_later_replacement_preserves_historical_delivery(self):
        source = self.commit("a.txt", "mine\n")
        self.claim(source)
        self.published(source)
        self.assertEqual(self.record(source), 1)
        later = self.commit("a.txt", "later writer\n")
        self.published(later)
        self.assertTrue(self.verify(source, later))
        self.assertEqual(self.record(later), 0)

    def test_guard_records_only_the_selected_session_and_close_reader_accepts(self):
        remote = self.root / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        source = self.commit('a.txt', 'mine')
        self.git('push', '-q', 'origin', 'HEAD:main')
        session_dir = self.root / '.iwe-runtime/sessions'
        session_dir.mkdir(parents=True)
        self.sem = session_dir / 'codex-one.open'
        self.sem.write_text('agent: codex\nsession_id: one\nwp: WP-561\n')
        self.claim(source)
        other = session_dir / 'codex-other.open'
        other.write_text('agent: codex\nsession_id: other\nwp: WP-561\n')
        before = other.read_bytes()
        guard = Path(__file__).parents[1] / 'session-guard.sh'
        env = {**os.environ, 'IWE_ROOT': str(self.root), 'IWE_GOVERNANCE_REPO': 'repo'}
        result = subprocess.run(['bash', str(guard), 'note-publication', source, '--repo', 'repo',
                                 '--agent', 'codex', '--session-id', 'one'],
                                env=env, cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(other.read_bytes(), before)
        self.assertTrue(self.verify(source, source))
        # Call the actual close proof reader without invoking unrelated close
        # ritual transitions; its legacy resolvers are the production functions.
        script = guard.read_text()
        names = ['_resolve_repo_checkout', '_publication_receipt_tool',
                 '_record_publication_receipts', '_claimed_commits_have_publish_proof']
        functions = []
        for name in names:
            body = script.split(name + '() {', 1)[1].split('\n}', 1)[0]
            functions.append(name + '() {' + body + '\n}')
        # Library location is otherwise relative to the extracted shell file.
        functions[1] = '_publication_receipt_tool() { python3 "$RECEIPT_TOOL" "$@"; }'
        env.update(RECEIPT_TOOL=str(guard.parent / 'lib/publication_receipt.py'),
                   GOV_REPO='repo')
        result = subprocess.run(['bash', '-c', '\n'.join(functions) +
                                 '\n_claimed_commits_have_publish_proof "$1"', 'close-proof', str(self.sem)],
                                env=env, cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_remote_change_during_proof_refuses(self):
        source = self.commit('a.txt', 'mine')
        self.claim(source)
        self.published(source)
        self.record(source)
        original = receipt.receipt

        def move_remote(*args):
            result = original(*args)
            self.published(self.base)
            return result

        with patch.object(receipt, 'receipt', side_effect=move_remote):
            self.assertFalse(self.verify(source, source))

    def test_prepared_inventory_is_bound_to_its_session_and_repository(self):
        source = self.commit('a.txt', 'prepared source')
        with self.sem.open('a') as out:
            out.write('close_delivery_version: isolate-push/v2\n'
                      'close_delivery_session_id: one\n'
                      'close_delivery_target_ref: refs/heads/main\n'
                      'close_delivery_common_dir: ' + str(self.repo / '.git') + '\n'
                      'close_delivery_source_commits: ' + json.dumps([source]) + '\n')
        self.published(source)
        self.assertEqual(self.record(source), 1)
        self.assertTrue(self.verify(source, source))
        self.sem.write_text(self.sem.read_text().replace('close_delivery_session_id: one',
                                                       'close_delivery_session_id: other'))
        self.assertFalse(self.verify(source, source))

    def prepared_replay_history(self, pending_paths=()):
        remote = self.root / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        base = self.commit('b.txt', 'base\n')
        for path in ('a.txt', 'b.txt'):
            (self.repo / path).write_text('mine\n')
        self.git('add', '--', 'a.txt', 'b.txt')
        self.git('-c', 'commit.gpgsign=false', 'commit', '-qm', 'two source changes')
        source = self.git('rev-parse', 'HEAD')
        sources = [source]
        for path in pending_paths:
            sources.append(self.commit(path, 'still to publish\n'))
        self.sem.write_text(
            'agent: codex\nsession_id: one\nwp: WP-561\n'
            'close_delivery_version: isolate-push/v2\n'
            'close_delivery_session_id: one\n'
            'close_delivery_target_ref: refs/heads/main\n'
            'close_delivery_common_dir: ' + str(self.repo / '.git') + '\n'
            'close_delivery_source_base: ' + base + '\n'
            'close_delivery_source_head: ' + sources[-1] + '\n'
            'close_delivery_source_commits: ' + json.dumps(sources) + '\n')
        self.git('checkout', '-q', '--detach', base)
        self.commit('a.txt', 'mine\n')
        # The real cherry-pick contains only b.txt because a.txt is already
        # delivered. Its patch-id differs, but exact replay proves both paths.
        self.git('-c', 'commit.gpgsign=false', 'cherry-pick', source)
        anchor = self.git('rev-parse', 'HEAD')
        self.git('push', '-q', 'origin', 'HEAD:refs/heads/main')
        self.assertEqual(self.git('cherry', anchor, source, source + '^'), '+ ' + source)
        self.assertEqual(self.record(anchor), 1)
        self.assertTrue(self.verify(source, anchor))
        self.commit('a.txt', 'later writer\n')
        superseded = self.commit('b.txt', 'later writer\n')
        self.git('push', '-q', 'origin', 'HEAD:main')
        self.git('checkout', '-q', '--detach', sources[-1])
        return sources, superseded

    def publish_prepared(self):
        guard = Path(__file__).parents[1] / 'session-guard.sh'
        script = guard.read_text()
        names = ['normalize_remote_url', '_unique_record_field', '_resolve_repo_checkout',
                 '_record_publication_receipts', '_receipt_checkout_has_publish_proof',
                 '_prepared_source_set_has_publish_proof', '_publish_prepared_source']
        functions = []
        for name in names:
            body = script.split(name + '() {', 1)[1].split('\n}', 1)[0]
            functions.append(name + '() {' + body + '\n}')
        functions.append('_publication_receipt_tool() { python3 "$RECEIPT_TOOL" "$@"; }')
        publisher = self.root / 'publisher.sh'
        publisher.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$4" >> "$PUBLISH_LOG"
target=$(mktemp -d "$PUBLISH_TMP/publish.XXXXXX")
git -C "$1" worktree add --quiet --detach "$target" refs/remotes/origin/main
trap 'git -C "$1" worktree remove --force "$target" >/dev/null 2>&1' EXIT
git -C "$target" -c commit.gpgsign=false cherry-pick "$4"
git -C "$target" push --quiet origin HEAD:main
''')
        publisher.chmod(0o700)
        env = {**os.environ, 'IWE_ROOT': str(self.root), 'GOV_REPO': 'repo',
               'RECEIPT_TOOL': str(guard.parent / 'lib/publication_receipt.py'),
               'PUBLISH_LOG': str(self.root / 'published.log'), 'PUBLISH_TMP': str(self.root)}
        # Assert that the fixture actually needs the new proof, then exercise
        # the production helper with real fetch, proof, cherry-pick and push.
        commands = '''
if _prepared_source_set_has_publish_proof "$1" "$2"; then
    echo 'fixture unexpectedly passes legacy proof' >&2
    exit 97
fi
_publish_prepared_source "$1" "$2" "$3"
'''
        return subprocess.run(['bash', '-c', '\n'.join(functions) + commands,
                               'prepared-publish', str(self.sem), str(self.repo), str(publisher)],
                              env=env, cwd=self.repo, capture_output=True, text=True, timeout=90)

    def test_prepared_publish_recovers_historical_receipt_before_replay(self):
        sources, superseded = self.prepared_replay_history()
        # Recovery also works if the previous attempt delivered the source
        # but crashed before writing its optional receipt.
        self.sem.write_text(''.join(line for line in self.sem.read_text().splitlines(keepends=True)
                                    if not line.startswith(receipt.PREFIX)))
        result = self.publish_prepared()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'published.log').exists())
        self.assertTrue(self.verify(sources[0], superseded))
        self.assertEqual(self.git('rev-parse', 'refs/remotes/origin/main'), superseded)
        self.assertEqual(self.git('rev-parse', 'HEAD'), sources[-1])
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_prepared_publish_skips_proven_prefix_and_delivers_remaining_source(self):
        sources, superseded = self.prepared_replay_history(('remaining.txt',))
        self.assertFalse(self.verify(sources[-1], superseded))
        self.assertFalse(receipt.verify_checkout(self.repo, self.sem, 'repo', superseded))
        result = self.publish_prepared()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'published.log').read_text().splitlines(), sources[1:])
        self.git('fetch', '-q', 'origin', '+refs/heads/main:refs/remotes/origin/main')
        self.assertEqual(self.git('show', 'origin/main:remaining.txt'), 'still to publish')
        for path in ('a.txt', 'b.txt'):
            self.assertEqual(self.git('show', 'origin/main:' + path), 'later writer')
        self.assertEqual(self.git('rev-parse', 'HEAD'), sources[-1])
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_checkout_becomes_dirty_during_verification_refuses(self):
        source = self.commit('a.txt', 'mine')
        self.claim(source)
        self.git('checkout', '-q', '--detach', self.base)
        self.commit('unrelated.txt', 'parallel')
        self.git('-c', 'commit.gpgsign=false', 'cherry-pick', source)
        anchor = self.git('rev-parse', 'HEAD')
        self.published(anchor)
        self.record(anchor)
        self.git('checkout', '-q', '--detach', source)
        original = receipt.verify

        def dirty_after_proof(*args):
            result = original(*args)
            (self.repo / 'a.txt').write_text('not committed')
            return result

        with patch.object(receipt, 'verify', side_effect=dirty_after_proof):
            self.assertFalse(receipt.verify_checkout(self.repo, self.sem, 'repo', anchor))

    def test_receipt_does_not_store_origin_credentials(self):
        self.git('remote', 'set-url', 'origin', 'https://user:secret@example.invalid/repo')
        source = self.commit('a.txt', 'mine')
        self.claim(source)
        self.published(source)
        self.record(source)
        self.assertNotIn('secret', self.sem.read_text())
        with self.sem.open('a') as out:
            out.write(receipt.PREFIX + '[]\n')
        self.assertTrue(self.verify(source, source))

    def test_unpublished_claim_cannot_borrow_same_path(self):
        source = self.commit("a.txt", "mine\n")
        self.claim(source)
        self.git("checkout", "-q", "--detach", self.base)
        other = self.commit("a.txt", "other\n")
        self.published(other)
        before = self.sem.read_bytes()
        with self.assertRaisesRegex(receipt.ProofError, "no claimed change"):
            self.record(other)
        self.assertEqual(before, self.sem.read_bytes())
        self.assertFalse(self.verify(source, other))

    def test_replay_with_concurrent_change_and_late_replacement(self):
        source = self.commit("a.txt", "mine\n")
        self.claim(source)
        self.git("checkout", "-q", "--detach", self.base)
        self.commit("unrelated.txt", "parallel\n")
        self.git("-c", "commit.gpgsign=false", "cherry-pick", source)
        anchor = self.git("rev-parse", "HEAD")
        self.assertNotEqual(anchor, source)
        self.published(anchor)
        self.assertEqual(self.record(anchor), 1)
        later = self.commit("a.txt", "superseded\n")
        self.published(later)
        self.assertTrue(self.verify(source, later))
        self.git("checkout", "-q", "--detach", source)
        self.assertTrue(receipt.verify_checkout(self.repo, self.sem, "repo", later))

    def test_delete_and_rename_have_exact_path_evidence(self):
        deleted = self.commit("a.txt", None)
        self.claim(deleted)
        self.published(deleted)
        self.record(deleted)
        self.assertTrue(self.verify(deleted, deleted))
        data = json.loads(self.sem.read_text().split(receipt.PREFIX)[1].splitlines()[0])
        self.assertEqual(data["published_paths"], [{"path": "a.txt", "entry": None}])
        self.commit("old.txt", "name\n")
        self.git("mv", "old.txt", "new.txt")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "rename")
        renamed = self.git("rev-parse", "HEAD")
        self.claim(renamed)
        self.published(renamed)
        self.record(renamed)
        self.assertTrue(self.verify(renamed, renamed))
        self.assertEqual(set(receipt.changed_paths(self.repo, renamed)), {"old.txt", "new.txt"})

    def test_partial_publication_leaves_other_claim_unproven(self):
        first = self.commit("a.txt", "one\n")
        self.claim(first)
        second = self.commit("b.txt", "two\n")
        self.claim(second)
        self.published(first)
        self.assertEqual(self.record(first), 1)
        self.assertTrue(self.verify(first, first))
        self.assertFalse(self.verify(second, first))
        self.assertFalse(receipt.verify_checkout(self.repo, self.sem, "repo", first))

    def test_wrong_session_repo_tampered_blob_and_rewritten_history(self):
        source = self.commit("a.txt", "mine\n")
        self.claim(source)
        self.published(source)
        self.record(source)
        original = self.sem.read_text()
        self.sem.write_text(original.replace("session_id: one", "session_id: two"))
        self.assertFalse(self.verify(source, source))
        self.sem.write_text(original)
        self.git("remote", "set-url", "origin", str(self.root / "foreign.git"))
        self.assertFalse(self.verify(source, source))
        self.git("remote", "set-url", "origin", str(self.root / "remote.git"))
        head, encoded = original.split(receipt.PREFIX)
        data = json.loads(encoded)
        data["published_paths"][0]["entry"]["oid"] = "0" * 40
        self.sem.write_text(head + receipt.PREFIX + json.dumps(data) + "\n")
        self.assertFalse(self.verify(source, source))
        self.sem.write_text(original)
        self.assertFalse(self.verify(source, self.base))

    def test_foreign_local_commit_is_not_checkout_proof(self):
        source = self.commit("a.txt", "mine\n")
        self.claim(source)
        self.published(source)
        self.record(source)
        self.commit("foreign.txt", "not claimed\n")
        self.assertFalse(receipt.verify_checkout(self.repo, self.sem, "repo", source))

    def test_unclaimed_and_symlink_session_are_rejected(self):
        source = self.commit("a.txt", "mine\n")
        self.published(source)
        with self.assertRaisesRegex(receipt.ProofError, "no commit claims"):
            self.record(source)
        real = self.sem.with_suffix(".real")
        self.sem.rename(real)
        self.sem.symlink_to(real)
        with self.assertRaises(OSError):
            self.record(source)


class ProductPublicationReceiptTest(unittest.TestCase):
    """A declared product target proves delivery without rewriting old claims."""

    git = PublicationReceiptTest.git
    commit = PublicationReceiptTest.commit
    claim = PublicationReceiptTest.claim

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / "IWE"
        self.repo = self.root / "DS-IT-systems" / "repo"
        self.governance = self.root / "governance"
        self.orz = self.root / "sessions"
        for path in (self.root, self.governance, self.orz, self.repo):
            path.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "init", "-qb", "main", str(path)], check=True)
            for key, value in (("user.name", "Test"), ("user.email", "test@example.invalid")):
                subprocess.run(["git", "-C", str(path), "config", key, value], check=True)
            subprocess.run(["git", "-C", str(path), "remote", "add", "origin",
                            str(self.root.parent / (path.name + "-origin.git"))], check=True)
        self.remote = self.root.parent / "repo-origin.git"
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        self.base = self.commit("a.txt", "heading\nbase\nfooter\n")
        self.source = self.commit("a.txt", "heading\nowned one\nowned two\nfooter\n")
        self.git("checkout", "-q", "--detach", self.base)
        self.commit("concurrent.txt", "another writer\n")
        self.git("-c", "commit.gpgsign=false", "cherry-pick", self.source)
        self.anchor = self.git("rev-parse", "HEAD")
        self.assertNotEqual(self.anchor, self.source)
        self.git("push", "-q", "origin", "HEAD:refs/heads/pilot")
        self.sem = self.root / ".iwe-runtime/sessions/codex-one.open"
        self.sem.parent.mkdir(parents=True)
        self.sem.write_text("agent: codex\nsession_id: one\nwp: WP-484\nslug: product-close\n"
                            "close_path: peer-session\n"
                            f"governance_worktree: {self.governance}\n"
                            f"orz_sessions_dir: {self.orz}\n")
        self.claim(self.source)
        self.claim(self.anchor)
        self.guard = Path(__file__).parents[1] / "session-guard.sh"
        self.env = {**os.environ, "IWE_ROOT": str(self.root), "IWE_GOVERNANCE_REPO": "governance",
                    "GIT_ALLOW_PROTOCOL": "file"}

    def record_cli(self, target="refs/heads/pilot"):
        return subprocess.run(
            [sys.executable, str(self.guard.parent / "lib/publication_receipt.py"),
             "record", str(self.sem), str(self.repo), "repo", self.anchor,
             "--target-ref", target, "--workspace", str(self.root)],
            env=self.env, capture_output=True, text=True)

    def note_publication(self):
        return subprocess.run(
            ["bash", str(self.guard), "note-publication", self.anchor, "--repo", "repo",
             "--target-ref", "refs/heads/pilot", "--agent", "codex", "--session-id", "one"],
            env=self.env, cwd=self.repo, capture_output=True, text=True)

    def verify(self, source=None):
        return receipt.verify_product(self.repo, self.sem, "repo", source or self.source, self.root)

    def verify_cli(self):
        return subprocess.run(
            [sys.executable, str(self.guard.parent / "lib/publication_receipt.py"),
             "verify-product", str(self.sem), str(self.repo), "repo", self.source,
             "--workspace", str(self.root)], env=self.env, capture_output=True, text=True)

    def assert_recorded(self):
        before = self.sem.read_bytes()
        result = self.record_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.sem.read_bytes().startswith(before), "existing claims must remain unchanged")
        self.assertTrue(self.verify())
        self.assertTrue(self.verify(self.anchor))

    def functions(self, *names):
        source = self.guard.read_text()
        functions = []
        for name in names:
            lines = source[source.index(name + "() {"):].splitlines(keepends=True)
            body, in_python = [], False
            for line in lines:
                body.append(line)
                if "<<'PY'" in line:
                    in_python = True
                elif in_python and line.rstrip() == "PY":
                    in_python = False
                elif not in_python and line.rstrip() == "}":
                    break
            functions.append("".join(body))
        return "\n".join(functions)

    def close_proof(self):
        functions = self.functions("normalize_remote_url", "_resolve_repo_checkout",
                                   "_claimed_commits_have_publish_proof")
        functions += '\n_publication_receipt_tool() { python3 "$RECEIPT_TOOL" "$@"; }\n'
        return subprocess.run(
            ["bash", "-c", functions + '\n_claimed_commits_have_publish_proof "$1"',
             "close-proof", str(self.sem)], cwd=self.repo,
            env={**self.env, "GOV_REPO": "governance",
                 "RECEIPT_TOOL": str(self.guard.parent / "lib/publication_receipt.py")},
            capture_output=True, text=True)

    def test_rebased_claim_and_close_proof_accept_explicit_pilot_without_main(self):
        self.assert_recorded()
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main"), "")
        result = self.close_proof()
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = [json.loads(line[len(receipt.PREFIX):]) for line in self.sem.read_text().splitlines()
                 if line.startswith(receipt.PREFIX)]
        self.assertEqual({item["source_commit"] for item in saved}, {self.source, self.anchor})
        self.assertEqual({item["target_ref"] for item in saved}, {"refs/heads/pilot"})
        self.assertEqual(next(item["proof"] for item in saved if item["source_commit"] == self.source),
                         "exact-replay")

    def test_later_remote_edit_keeps_historical_delivery_proven(self):
        self.assert_recorded()
        self.commit("a.txt", "later legitimate replacement\n")
        self.git("push", "-q", "origin", "HEAD:refs/heads/pilot")
        self.assertTrue(self.verify())

    def test_guard_records_product_delivery_before_prepare(self):
        before = self.sem.read_bytes()
        result = self.note_publication()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.sem.read_bytes().startswith(before))
        self.assertTrue(self.verify())

    def test_new_architecture_is_an_explicit_supported_target(self):
        self.git("push", "-q", "origin", "HEAD:refs/heads/new-architecture")
        result = self.record_cli("refs/heads/new-architecture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.verify())

    def test_non_peer_session_cannot_use_product_delivery_policy(self):
        self.sem.write_text(self.sem.read_text().replace("close_path: peer-session\n", ""))
        before = self.sem.read_bytes()
        result = self.record_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sem.read_bytes(), before)

    def test_deleted_target_ref_rejects_stale_cached_receipt(self):
        self.assert_recorded()
        self.git("push", "-q", "origin", ":refs/heads/pilot")
        self.git("update-ref", "refs/remotes/origin/pilot", self.anchor)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/pilot"), self.anchor)
        before = self.sem.read_bytes()
        self.assertNotEqual(self.verify_cli().returncode, 0)
        self.assertEqual(self.sem.read_bytes(), before)

    def test_foreign_session_origin_and_tampered_target_are_rejected(self):
        self.assert_recorded()
        original = self.sem.read_text()
        self.sem.write_text(original.replace("session_id: one", "session_id: other"))
        self.assertFalse(self.verify())
        self.sem.write_text(original)
        foreign = self.root.parent / "foreign.git"
        subprocess.run(["git", "clone", "--bare", "-q", str(self.remote), str(foreign)], check=True)
        self.git("remote", "set-url", "origin", str(foreign))
        self.assertFalse(self.verify())
        self.git("remote", "set-url", "origin", str(self.remote))
        self.sem.write_text(original.replace('"target_ref":"refs/heads/pilot"',
                                            '"target_ref":"refs/heads/new-architecture"'))
        self.assertNotEqual(self.verify_cli().returncode, 0)
        # Even the same commit on another allowed ref cannot repair a forged
        # receipt: target identity is part of the reconstructed claim ID.
        self.git("push", "-q", "origin", "HEAD:refs/heads/new-architecture")
        self.assertFalse(self.verify())

    def test_receipt_never_restores_an_unclaimed_source(self):
        self.assert_recorded()
        self.sem.write_text(self.sem.read_text().replace("commit: repo " + self.source + "\n", ""))
        self.assertFalse(self.verify())
        self.assertTrue(self.verify(self.anchor))

    def test_dropped_hunk_cannot_prove_original_claim(self):
        self.git("checkout", "-q", "--detach", self.anchor + "^")
        self.anchor = self.commit("a.txt", "heading\nowned one\nfooter\n")
        self.git("push", "-q", "--force", "origin", "HEAD:refs/heads/pilot")
        self.claim(self.anchor)
        result = self.record_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.verify())
        self.assertTrue(self.verify(self.anchor))

    def test_protected_repository_identity_cannot_use_product_target(self):
        before = self.sem.read_bytes()
        for protected in (self.root, self.governance, self.orz):
            with self.subTest(protected=protected.name):
                old_origin = subprocess.run(["git", "-C", str(protected), "remote", "get-url", "origin"],
                                            check=True, capture_output=True, text=True).stdout.strip()
                subprocess.run(["git", "-C", str(protected), "remote", "set-url", "origin",
                                str(self.remote)], check=True)
                try:
                    self.assertNotEqual(self.record_cli().returncode, 0)
                    self.assertEqual(self.sem.read_bytes(), before)
                finally:
                    subprocess.run(["git", "-C", str(protected), "remote", "set-url", "origin",
                                    old_origin], check=True)

    def test_existing_receipt_rechecks_protected_identity(self):
        self.assert_recorded()
        before = self.sem.read_bytes()
        subprocess.run(["git", "-C", str(self.governance), "remote", "set-url", "origin",
                        str(self.remote)], check=True)
        self.assertNotEqual(self.verify_cli().returncode, 0)
        self.assertEqual(self.sem.read_bytes(), before)

    def test_unpublished_target_does_not_write_a_receipt(self):
        self.git("push", "-q", "origin", "HEAD:refs/heads/scratch")
        before = self.sem.read_bytes()
        for target in ("refs/heads/scratch", "refs/heads/new-architecture", "refs/tags/pilot",
                       "pilot", "refs/heads/../pilot"):
            with self.subTest(target=target):
                self.assertNotEqual(self.record_cli(target).returncode, 0)
                self.assertEqual(self.sem.read_bytes(), before)

    def prepare(self):
        terminal = self.root / "terminal.txt"
        terminal.write_text("completed peer work\n")
        functions = self.functions("_unique_record_field", "_terminal_proof_snapshot_sha",
                                   "_owned_semaphore_snapshot_sha", "_append_close_fields_atomic",
                                   "_record_close_prepared", "_close_delivery_state")
        self.prepared_functions = functions
        claim_rows = sorted(line[8:] for line in self.sem.read_text().splitlines()
                            if line.startswith("commit: "))
        command = functions + '''
terminal_sha=$(_terminal_proof_snapshot_sha file "$4")
_record_close_prepared "$1" one "$2" "$2/.git" "$3" "$3" "$3" \
    '[]' "$5" file "$4" "$terminal_sha" "$6" refs/heads/main
_close_delivery_state "$1" one
'''
        result = subprocess.run(
            ["bash", "-c", command, "prepare", str(self.sem), str(self.governance), self.base,
             str(terminal), json.dumps(claim_rows), str(self.root.parent / "governance-origin.git")],
            env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], "prepared")

    def test_prepared_guard_appends_receipt_without_changing_frozen_claims(self):
        self.prepare()
        before = self.sem.read_bytes()
        result = self.note_publication()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.sem.read_bytes().startswith(before))
        result = subprocess.run(
            ["bash", "-c", self.prepared_functions + '\n_close_delivery_state "$1" one',
             "state", str(self.sem)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "prepared")
        self.assertTrue(self.verify())

    def test_prepared_changed_claim_set_is_rejected(self):
        self.prepare()
        self.claim(self.base)
        before = self.sem.read_bytes()
        result = self.note_publication()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sem.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
