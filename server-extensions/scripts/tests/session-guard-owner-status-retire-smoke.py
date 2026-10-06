#!/usr/bin/env python3
"""WP-530 Ф90: owner-status absence verdict vs retired artifacts, blockers list,
retire-semaphore-artifact preconditions, and the per-agent identity gate in open.

Peer-session 2026-10-06-10-wp530-f90-session-close-blockers (Claude+Kimi+Codex).
Every case asserts the observable JSON/exit/registry effect, not "it ran".
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


GUARD = Path(os.environ.get(
    "SESSION_GUARD_UNDER_TEST",
    str(Path(__file__).resolve().parents[1] / "session-guard.sh"),
))

OWNER = "e5d50674-5942-40e2-b510-a682d71cc4cd"  # UUIDv4 harness id: no encoded start time
LEGACY_QUARANTINE = ("---\nagent: claude-code\nwp: WP-561\nslug: WP-561\n"
                     "opened_at: 2026-10-05T07:07:54Z\ncreated_at: 2026-10-05T07:07:54Z\n"
                     "session_id: 1791184072-9391\nclose_path: unknown\nhost: tsekh-1\n---\n")
LEGACY_NAME = "claude-code-1791184072-9391.open.orphaned-manual-quarantine-pilot-authorized-20261005"
BACKUP_NAME = "claude-code-1791299876-a05a.open.bak-wp7-f209"
BACKUP_BODY = ("---\nagent: claude-code\nwp: WP-7\nslug: wp7-triage\n"
               "opened_at: 2026-10-06T15:17:58Z\nsession_id: 1791299876-a05a\n"
               "harness_session_id: 5ec43110-f01d-4256-984e-30f7ac049342\n---\n")


class OwnerStatusRetireTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="wp530-f90-", dir=os.path.realpath(tempfile.gettempdir()))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sessions = self.root / ".iwe-runtime/sessions"
        self.sessions.mkdir(parents=True, mode=0o700)
        self.registry = self.root / ".iwe-runtime/zombie-semaphores.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("IWE_", "CLAUDE_", "CODEX_", "GIT_"))}
        self.env.update(IWE_ROOT=str(self.root), IWE_GOVERNANCE_REPO="DS-strategy",
                        IWE_SCHEDULED_ADMISSION_WAIT_SEC="2",
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")

    # --- helpers -------------------------------------------------------
    def write(self, name, body, mode=0o600):
        path = self.sessions / name
        path.write_text(body)
        path.chmod(mode)
        return path

    def guard(self, *args, env=None):
        merged = dict(self.env)
        merged.update(env or {})
        return subprocess.run(["/bin/bash", str(GUARD), *args], text=True,
                              capture_output=True, cwd=self.root, env=merged, timeout=30)

    def owner_status(self, owner=OWNER, agent="claude-code"):
        result = self.guard("owner-status", "--owner-session-id", owner, "--owner-agent", agent)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), result.stderr

    def retire(self, name, *extra, reason="not a live session (test)"):
        return self.guard("retire-semaphore-artifact", str(self.sessions / name),
                          "--reason", reason, "--agent", "claude-code", *extra)

    def registry_records(self):
        if not self.registry.exists():
            return []
        return [json.loads(line) for line in self.registry.read_text().splitlines() if line.strip()]

    # --- owner-status --------------------------------------------------
    def test_quarantined_same_agent_without_harness_blocks_absence_and_names_itself(self):
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "unknown")
        self.assertEqual([b["file"] for b in status["blockers"]], [LEGACY_NAME])
        self.assertIn("retire-semaphore-artifact", stderr)
        self.assertIn(LEGACY_NAME, stderr)

    def test_blockers_list_every_ambiguity_not_only_the_first(self):
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        self.write("zz-foreign.open.mystery", "unreadable sibling\n")
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "unknown")
        self.assertEqual(sorted(b["file"] for b in status["blockers"]),
                         sorted([LEGACY_NAME, "zz-foreign.open.mystery"]))

    def test_retired_quarantine_with_matching_sha_no_longer_blocks_absence(self):
        path = self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.registry.write_text(json.dumps({"action": "retired", "artifact": str(path),
                                             "sha256": digest}) + "\n")
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "absent", stderr)
        self.assertEqual(status["blockers"], [])
        self.assertIn("retired", stderr)

    def test_retired_record_with_stale_sha_keeps_blocking(self):
        path = self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        self.registry.write_text(json.dumps({"action": "retired", "artifact": str(path),
                                             "sha256": "0" * 64}) + "\n")
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "unknown")
        self.assertEqual([b["file"] for b in status["blockers"]], [LEGACY_NAME])

    def test_torn_registry_line_is_skipped_and_other_retire_records_still_count(self):
        path = self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.registry.write_text("not json\n" + json.dumps(
            {"action": "retired", "artifact": str(path), "sha256": digest}) + "\n")
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "absent", stderr)
        self.assertIn("line 1 is not JSON, skipped", stderr)

    def test_unreadable_registry_grants_no_skip_but_is_not_itself_a_blocker(self):
        path = self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.registry.write_bytes(b"\xff\xfe" + json.dumps(
            {"action": "retired", "artifact": str(path), "sha256": digest}).encode() + b"\n")
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "unknown")
        self.assertEqual([b["file"] for b in status["blockers"]], [LEGACY_NAME])
        self.assertIn("retire-записи не учитываются", stderr)
        path.unlink()
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "absent")

    def test_unreadable_registry_never_hides_present(self):
        mine = ("---\nagent: claude-code\nsession_id: 1791300000-aaaa\n"
                f"harness_session_id: {OWNER}\n---\n")
        self.write("claude-code-1791300000-aaaa.open", mine)
        self.registry.write_bytes(b"\xff not utf-8\n")
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "present")

    def test_present_verdict_still_lists_blockers(self):
        mine = ("---\nagent: claude-code\nsession_id: 1791300000-aaaa\n"
                f"harness_session_id: {OWNER}\n---\n")
        self.write("claude-code-1791300000-aaaa.open", mine)
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "present")
        self.assertEqual([b["file"] for b in status["blockers"]], [LEGACY_NAME])

    def test_exact_owner_match_in_quarantine_is_present_even_with_recovered_suffix(self):
        mine = ("---\nagent: claude-code\nsession_id: 1791300000-aaaa\n"
                f"harness_session_id: {OWNER}\n---\n")
        self.write("claude-code-1791300000-aaaa.open.orphaned-dead-interactive.recovered", mine)
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "present")

    def test_hand_renamed_copy_of_foreign_harness_conversation_does_not_block(self):
        self.write(BACKUP_NAME, BACKUP_BODY)
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "absent", stderr)
        self.assertIn("нестандартным суффиксом", stderr)

    def test_hand_renamed_copy_naming_this_owner_is_present(self):
        self.write(BACKUP_NAME, BACKUP_BODY.replace("5ec43110-f01d-4256-984e-30f7ac049342", OWNER))
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "present")

    def test_active_same_agent_without_harness_still_unknown(self):
        self.write("claude-code-1791184072-9391.open", LEGACY_QUARANTINE)
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "unknown")
        self.assertIn("semaphore has no harness identity", status["reason"])
        self.assertIn("audit --cleanup-orphans", stderr)
        self.assertNotIn("retire-semaphore-artifact", stderr)

    def test_active_record_cannot_be_retired_even_with_registry_record(self):
        path = self.write("claude-code-1791184072-9391.open", LEGACY_QUARANTINE)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.registry.write_text(json.dumps({"action": "retired", "artifact": str(path),
                                             "sha256": digest}) + "\n")
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "unknown")

    # --- retire-semaphore-artifact ------------------------------------
    def test_retire_refuses_active_semaphore(self):
        self.write("claude-code-1791184072-9391.open", LEGACY_QUARANTINE)
        result = self.retire("claude-code-1791184072-9391.open")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("активный семафор", result.stderr)
        self.assertEqual(self.registry_records(), [])

    def test_retire_quarantine_without_journal_or_flag_refuses(self):
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        result = self.retire(LEGACY_NAME)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--i-confirm-no-live-owner", result.stderr)
        self.assertEqual(self.registry_records(), [])

    def test_retire_quarantine_with_matching_generation_journal_record(self):
        path = self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        original = str(self.sessions / "claude-code-1791184072-9391.open")
        self.registry.write_text(json.dumps({
            "action": "quarantined", "semaphore": original, "opened_epoch": 1791184074,
            "pass_key": "manual-20261005"}) + "\n")
        result = self.retire(LEGACY_NAME)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.registry_records()
        self.assertEqual(records[-1]["action"], "retired")
        self.assertEqual(records[-1]["artifact"], str(path))
        self.assertEqual(records[-1]["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(records[-1]["basis"], "journal-quarantined:manual-20261005")
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "absent")

    def test_retire_quarantine_with_other_generation_journal_record_needs_flag(self):
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        original = str(self.sessions / "claude-code-1791184072-9391.open")
        self.registry.write_text(json.dumps({
            "action": "quarantined", "semaphore": original, "opened_epoch": 1791000000}) + "\n")
        result = self.retire(LEGACY_NAME)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.registry_records()), 1)
        result = self.retire(LEGACY_NAME, "--i-confirm-no-live-owner")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry_records()[-1]["basis"], "operator-confirmation")

    def test_retire_backup_copy_needs_explicit_confirmation(self):
        self.write(BACKUP_NAME, BACKUP_BODY)
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)  # keep the directory ambiguous for the end check
        result = self.retire(BACKUP_NAME)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("нестандартным суффиксом", result.stderr)
        result = self.retire(BACKUP_NAME, "--i-confirm-no-live-owner", reason="резервная копия ручной правки")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry_records()[-1]["reason"], "резервная копия ручной правки")

    def test_retire_refuses_when_live_generation_exists(self):
        self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        self.write("claude-code-1791184072-9391.open", LEGACY_QUARANTINE)
        result = self.retire(LEGACY_NAME, "--i-confirm-no-live-owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("живой", result.stderr)
        self.assertEqual(self.registry_records(), [])

    def test_retire_refuses_callers_own_record_even_with_flag_and_journal(self):
        mine = ("---\nagent: claude-code\nsession_id: 1791300000-aaaa\n"
                "opened_at: 2026-10-06T15:00:00Z\n"
                f"harness_session_id: {OWNER}\n---\n")
        name = "claude-code-1791300000-aaaa.open.orphaned-dead-interactive"
        self.write(name, mine)
        original = str(self.sessions / "claude-code-1791300000-aaaa.open")
        self.registry.write_text(json.dumps({
            "action": "quarantined", "semaphore": original, "opened_epoch": 1791298800}) + "\n")
        result = self.guard("retire-semaphore-artifact", str(self.sessions / name), "--reason", "x",
                            "--agent", "claude-code", "--i-confirm-no-live-owner",
                            env={"CLAUDE_CODE_SESSION_ID": OWNER})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ЭТОМУ разговору", result.stderr)
        self.assertEqual(len(self.registry_records()), 1)
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "present")

    def test_retire_of_harness_bearing_quarantine_needs_flag_even_with_journal(self):
        foreign = BACKUP_BODY  # harness 5ec43110..., not OWNER
        name = "claude-code-1791299876-a05a.open.orphaned-dead-interactive"
        path = self.write(name, foreign)
        original = str(self.sessions / "claude-code-1791299876-a05a.open")
        self.registry.write_text(json.dumps({
            "action": "quarantined", "semaphore": original, "opened_epoch": 1791299878}) + "\n")
        result = self.retire(name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("5ec43110-f01d-4256-984e-30f7ac049342", result.stderr)
        self.assertEqual(len(self.registry_records()), 1)
        result = self.retire(name, "--i-confirm-no-live-owner")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry_records()[-1]["basis"],
                         "operator-confirmation:harness=5ec43110-f01d-4256-984e-30f7ac049342")
        self.assertEqual(self.registry_records()[-1]["artifact"], str(path))

    def test_retire_housekeeping_quarantine_binds_generation_via_created_at(self):
        body = ("---\nagent: night-cycle\nhousekeeping: night-cycle\nslug: night-cycle\n"
                "created_at: 2026-10-05T03:00:00Z\nsession_id: housekeeping-night-cycle\n---\n")
        name = "night-cycle-housekeeping-night-cycle.open.orphaned-zombie-no-pid"
        self.write(name, body)
        original = str(self.sessions / "night-cycle-housekeeping-night-cycle.open")
        self.registry.write_text(json.dumps({
            "action": "quarantined", "semaphore": original, "opened_epoch": 1791169200,
            "pass_key": "sweep-1"}) + "\n")
        result = self.retire(name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry_records()[-1]["basis"], "journal-quarantined:sweep-1")

    def test_retire_refuses_unsafe_artifact_and_writes_nothing(self):
        path = self.write(LEGACY_NAME, LEGACY_QUARANTINE)
        os.link(path, self.root / "hardlink-twin")  # nlink == 2 fails owner-status read_raw
        result = self.retire(LEGACY_NAME, "--i-confirm-no-live-owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("не читается безопасно", result.stderr)
        self.assertEqual(self.registry_records(), [])

    def test_retire_refuses_group_writable_registry_instead_of_writing_dead_record(self):
        self.write(BACKUP_NAME, BACKUP_BODY)
        self.registry.write_text("")
        self.registry.chmod(0o664)
        result = self.retire(BACKUP_NAME, "--i-confirm-no-live-owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("chmod 600", result.stderr)
        self.assertEqual(self.registry.read_text(), "")
        self.registry.chmod(0o600)
        result = self.retire(BACKUP_NAME, "--i-confirm-no-live-owner")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(oct(self.registry.stat().st_mode & 0o777), "0o600")

    def test_retire_creates_missing_registry_with_owner_only_permissions(self):
        self.write(BACKUP_NAME, BACKUP_BODY)
        self.assertFalse(self.registry.exists())
        result = self.retire(BACKUP_NAME, "--i-confirm-no-live-owner")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(oct(self.registry.stat().st_mode & 0o777), "0o600")
        status, _ = self.owner_status()
        self.assertEqual(status["state"], "absent")

    def test_deeply_nested_registry_line_does_not_crash_or_hide_present(self):
        mine = ("---\nagent: claude-code\nsession_id: 1791300000-aaaa\n"
                f"harness_session_id: {OWNER}\n---\n")
        self.write("claude-code-1791300000-aaaa.open", mine)
        self.registry.write_text("[" * 200000 + "\n")
        status, stderr = self.owner_status()
        self.assertEqual(status["state"], "present", stderr)

    def test_retire_detects_own_record_even_with_quoted_identity(self):
        mine = ("---\nagent: claude-code\nsession_id: 1791300000-aaaa\n"
                "opened_at: 2026-10-06T15:00:00Z\n"
                f"harness_session_id: \"{OWNER}\"\n---\n")
        name = "claude-code-1791300000-aaaa.open.bak-manual"
        self.write(name, mine)
        result = self.guard("retire-semaphore-artifact", str(self.sessions / name), "--reason", "x",
                            "--agent", "claude-code", "--i-confirm-no-live-owner",
                            env={"CLAUDE_CODE_SESSION_ID": OWNER})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ЭТОМУ разговору", result.stderr)
        self.assertEqual(self.registry_records(), [])

    def test_retire_requires_reason_and_rejects_paths_outside_sessions_dir(self):
        self.write(BACKUP_NAME, BACKUP_BODY)
        result = self.guard("retire-semaphore-artifact", str(self.sessions / BACKUP_NAME),
                            "--agent", "claude-code", "--i-confirm-no-live-owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--reason", result.stderr)
        outside = self.root / "elsewhere.open.bak"
        outside.write_text(BACKUP_BODY)
        result = self.guard("retire-semaphore-artifact", str(outside), "--reason", "x",
                            "--agent", "claude-code", "--i-confirm-no-live-owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.registry_records(), [])

    def test_confirmation_flag_is_refused_on_other_commands(self):
        result = self.guard("audit", "--i-confirm-no-live-owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("применим только к retire-semaphore-artifact", result.stderr)

    # --- open identity gate (R3) ------------------------------------
    def test_open_refuses_claude_code_without_conversation_identity(self):
        result = self.guard("open", "--wp", "WP-530", "--agent", "claude-code", "--task", "t")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CLAUDE_CODE_SESSION_ID", result.stderr)
        self.assertEqual(list(self.sessions.glob("*.open")), [])

    def test_open_refuses_codex_with_only_ambient_claude_identity(self):
        result = self.guard("open", "--wp", "WP-530", "--agent", "codex", "--task", "t",
                            env={"CLAUDE_CODE_SESSION_ID": OWNER})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CODEX_THREAD_ID", result.stderr)
        self.assertEqual(list(self.sessions.glob("*.open")), [])

    def test_open_identity_gate_lets_scripted_identity_through_to_later_gates(self):
        # With IWE_SESSION_ID set the Ф90 gate must not be the refusing one;
        # whatever later gate fails in this bare fixture, it is not ours.
        result = self.guard("open", "--wp", "WP-530", "--agent", "claude-code", "--task", "t",
                            env={"IWE_SESSION_ID": "0f3a4c1e-9b2d-4a6f-8c1d-2e3f4a5b6c7d"})
        self.assertNotIn("нет идентичности разговора", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("под freeze", result.stderr)  # the freeze gate, which comes after ours, speaks


if __name__ == "__main__":
    unittest.main()
