# P0 secret-read barrier (WP-544 D27/Вg2, 2026-09-01)

Staged from the peer session `2026-09-01-06-secret-broker-sudoers-mcp-gate`
(Claude + Kimi + Codex). Two independent layers, neither is the other's
replacement:

1. **Hooks** (`.claude/hooks/secret-bypass-lib.sh`, `secret-mcp-dump-guard.sh`
   in the `iwe-local-config` repo) — already fixed, tested (self-tests
   pass). Whether the fix is live depends on the machine — see "Deployment
   gap" below; do not assume a path with an `iwe-local-config/` prefix, it
   is only correct on tsekh-1, not on the Mac (root `~/IWE` there IS the
   repo).
2. **sudoers drop-in** (`99-iwe-secret-deny.sudoers`) — staged here,
   validated with `visudo -c`, **not installed**. Requires the pilot's
   explicit go-ahead (Codex's ESCALATE_TO_USER from the peer session,
   accepted): this changes root-command policy on a live host.

## Install (only after explicit pilot confirmation)

```bash
sudo install -m 0440 -o root -g root \
  scripts/system/99-iwe-secret-deny.sudoers \
  /etc/sudoers.d/99-iwe-secret-deny
# run from the iwe-local-config working copy root: ~/IWE/iwe-local-config
# on tsekh-1, plain root ~/IWE on the Mac (see "Deployment gap" above)
sudo visudo -c
sudo -n /bin/cat /etc/iwe/env        # expect: permission denied by policy
sudo -n systemctl --version           # expect: still works
```

## Rollback (instant)

```bash
sudo rm -f /etc/sudoers.d/99-iwe-secret-deny
sudo visudo -c
```

## Deployment gap — tsekh-1 only (Mac confirmed clear, 2026-09-01)

On **tsekh-1** the live hook mirror at `~/IWE/.claude/hooks/` is read-only
(mode 555, mtime = epoch — a generated/declarative NixOS deployment).
Promoting an `iwe-local-config` fix there requires the mirror's normal
promotion mechanism to run before the hook fix is live.

On **the Mac** this gap does not apply and was re-checked from scratch
(WP-544 journal, 2026-09-01): root `~/IWE` on this machine IS the
`iwe-local-config` working copy (same origin, ordinary writable files, no
declarative rebuild step) — a committed fix there is live in
`~/IWE/.claude/hooks/` immediately. A separate launchd timer
(`com.iwe.sync-server-extensions`, `iwe-server-config/scripts/sync-extensions-auto.sh`,
every 2h) then mirrors those files into `iwe-server-config` to feed the
tsekh-1 deploy pipeline. Do not confuse this with the stale, unrelated
`~/IWE/iwe-local-config/` sub-clone that also happens to exist on this
Mac — it is a second, disconnected checkout of the same repo (last commit
lagging root by several days) and is not wired into any sync; the correct
source on the Mac is root `~/IWE`, not that subdirectory.

## Known residual after this P0 layer

`sudo -n awk '1' /etc/iwe/env`, `sudo -n python3 -c '...'`, and reading
through a symlink still bypass the sudoers deny (command+argv matching,
not inode-based). Tracked as WP-544 D27 P1 (capability broker), not closed
here.
