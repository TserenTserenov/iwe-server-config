# P0 secret-read barrier (WP-544 D27/Вg2, 2026-09-01)

Staged from the peer session `2026-09-01-06-secret-broker-sudoers-mcp-gate`
(Claude + Kimi + Codex). Two independent layers, neither is the other's
replacement:

1. **Hooks** (`~/IWE/iwe-local-config/.claude/hooks/secret-bypass-lib.sh`,
   `secret-mcp-dump-guard.sh`) — already fixed, tested (self-tests pass),
   and copied to the live mirror is blocked by filesystem permissions (see
   "Deployment gap" below).
2. **sudoers drop-in** (`99-iwe-secret-deny.sudoers`) — staged here,
   validated with `visudo -c`, **not installed**. Requires the pilot's
   explicit go-ahead (Codex's ESCALATE_TO_USER from the peer session,
   accepted): this changes root-command policy on a live host.

## Install (only after explicit pilot confirmation)

```bash
sudo install -m 0440 -o root -g root \
  ~/IWE/iwe-local-config/scripts/system/99-iwe-secret-deny.sudoers \
  /etc/sudoers.d/99-iwe-secret-deny
sudo visudo -c
sudo -n /bin/cat /etc/iwe/env        # expect: permission denied by policy
sudo -n systemctl --version           # expect: still works
```

## Rollback (instant)

```bash
sudo rm -f /etc/sudoers.d/99-iwe-secret-deny
sudo visudo -c
```

## Deployment gap (open item, not resolved by this session)

The live hook mirror at `~/IWE/.claude/hooks/` is read-only (mode 555,
mtime = epoch — a generated/declarative deployment, same pattern already
documented for `~/IWE/.claude/skills/` in
`reference_iwe_local_config_real_source.md`). The source fix here is
committed and correct; whatever mechanism normally promotes
`iwe-local-config` changes to that mirror on tsekh-1 needs to run before
the hook fix is live. This session did not identify or trigger that
mechanism — flagged to the pilot rather than guessed at.

## Known residual after this P0 layer

`sudo -n awk '1' /etc/iwe/env`, `sudo -n python3 -c '...'`, and reading
through a symlink still bypass the sudoers deny (command+argv matching,
not inode-based). Tracked as WP-544 D27 P1 (capability broker), not closed
here.
