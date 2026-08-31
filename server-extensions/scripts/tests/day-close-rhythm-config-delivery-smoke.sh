#!/usr/bin/env bash
# Smoke test for the day-rhythm-config.yaml -> tsekh-1 delivery block added to
# day-close.sh do_backup() (WP-526 "Осталось" 31.08).
#
# .iwe-runtime/ is intentionally outside git (WP-526), so this file can only
# reach tsekh-1 over SSH, not via the usual git-publish path. The delivery
# block must be best-effort (never fail Day Close) and atomic (never leave a
# partially-written file on the remote side). This fixture pins both
# properties plus the hostname guard, using mocked ssh/scp so it runs without
# real network access.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DAY_CLOSE="$ROOT_DIR/scripts/day-close.sh"

# Extract the delivery block by anchor comments — the same technique used to
# verify it live before merge. A missing anchor means the block was renamed
# or removed elsewhere without updating this fixture; fail loud, not silently.
START_LINE=$(grep -n "Cross-machine delivery to tsekh-1" "$DAY_CLOSE" | head -1 | cut -d: -f1)
END_LINE=$(grep -n "issue #217" "$DAY_CLOSE" | head -1 | cut -d: -f1)
if [[ -z "$START_LINE" || -z "$END_LINE" ]]; then
    echo "FAIL: could not locate delivery block anchors in day-close.sh (renamed?)" >&2
    exit 1
fi
BLOCK=$(sed -n "${START_LINE},$((END_LINE - 1))p" "$DAY_CLOSE")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_block() {
    local fixture="$1" mock_hostname="$2"
    (
        log() { :; }
        warn() { echo "WARN:$1"; }
        hostname() { echo "$mock_hostname"; }
        # shellcheck disable=SC2317  # invoked indirectly via mocked ssh below
        run_delivery() {
            # shellcheck disable=SC2034  # read inside the eval'd $BLOCK below
            local rhythm_dst="$fixture"
            eval "$BLOCK"
        }
        run_delivery
    )
}

# --- Check 1: happy path — delivered atomically via temp+mv, no partial state ---
cat > "$WORK/good.yaml" <<'EOF'
day_open:
  calendar_ids: ["smoke"]
EOF
REMOTE_ROOT="$WORK/remote-home/IWE"
mkdir -p "$REMOTE_ROOT"
PATH_STUB="$WORK/bin"
mkdir -p "$PATH_STUB"
# Mocked ssh/scp target a fake $HOME so real bash tilde-expansion (not manual
# string substitution) resolves "~/IWE/..." correctly regardless of where it
# appears in the remote command string.
cat > "$PATH_STUB/ssh" <<STUB
#!/bin/bash
shift \$(( \$# - 1 ))
HOME="$WORK/remote-home" bash -c "\$1" -- "\$1"
STUB
cat > "$PATH_STUB/scp" <<STUB
#!/bin/bash
# macOS ships bash 3.2 as /bin/bash — no negative array indices (bash 4.3+ only),
# so the last two positional args are picked by explicit offset instead.
args=("\$@")
n=\${#args[@]}
src="\${args[\$((n - 2))]}"
dst="\${args[\$((n - 1))]#*:}"
dst=\$(HOME="$WORK/remote-home" bash -c "echo \$dst")
mkdir -p "\$(dirname "\$dst")"
cp "\$src" "\$dst"
STUB
chmod +x "$PATH_STUB/ssh" "$PATH_STUB/scp"

OUT=$(PATH="$PATH_STUB:$PATH" run_block "$WORK/good.yaml" "not-tsekh-1")
if [[ "$OUT" != *"WARN"* ]] && diff -q "$WORK/good.yaml" "$REMOTE_ROOT/.iwe-runtime/day-rhythm-config.yaml" >/dev/null 2>&1; then
    echo "PASS: happy path delivers byte-identical content, no warnings"
else
    echo "FAIL: happy path did not deliver correctly (output: $OUT)" >&2
    exit 1
fi
if compgen -G "$REMOTE_ROOT/.iwe-runtime/.day-rhythm-config.yaml.tmp.*" >/dev/null 2>&1; then
    echo "FAIL: temp file left behind after successful delivery" >&2
    exit 1
fi
echo "PASS: no leftover temp file after successful delivery"

# --- Check 2: unreachable host — warns, does not raise (set -e safe) ---
cat > "$PATH_STUB/ssh" <<'STUB'
#!/bin/bash
exit 255
STUB
chmod +x "$PATH_STUB/ssh"
OUT=$(PATH="$PATH_STUB:$PATH" run_block "$WORK/good.yaml" "not-tsekh-1")
if [[ "$OUT" == *"WARN"* ]]; then
    echo "PASS: unreachable host warns instead of raising"
else
    echo "FAIL: unreachable host did not produce the expected warning (output: $OUT)" >&2
    exit 1
fi

# --- Check 3: invalid YAML — delivery skipped before any network call ---
echo 'not: [valid yaml' > "$WORK/bad.yaml"
cat > "$PATH_STUB/ssh" <<'STUB'
#!/bin/bash
echo "SSH_CALLED_UNEXPECTEDLY" >&2
exit 1
STUB
chmod +x "$PATH_STUB/ssh"
OUT=$(PATH="$PATH_STUB:$PATH" run_block "$WORK/bad.yaml" "not-tsekh-1" 2>&1)
if [[ "$OUT" == *"WARN"* && "$OUT" != *"SSH_CALLED_UNEXPECTEDLY"* ]]; then
    echo "PASS: invalid YAML skips delivery before touching the network"
else
    echo "FAIL: invalid YAML did not short-circuit before ssh (output: $OUT)" >&2
    exit 1
fi

# --- Check 4: hostname guard — block is a no-op when already on tsekh-1 ---
cat > "$PATH_STUB/ssh" <<'STUB'
#!/bin/bash
echo "SSH_CALLED_UNEXPECTEDLY" >&2
exit 1
STUB
chmod +x "$PATH_STUB/ssh"
OUT=$(PATH="$PATH_STUB:$PATH" run_block "$WORK/good.yaml" "tsekh-1" 2>&1)
if [[ -z "$OUT" ]]; then
    echo "PASS: hostname guard skips the block entirely on tsekh-1"
else
    echo "FAIL: hostname guard did not suppress the block (output: $OUT)" >&2
    exit 1
fi

echo "ALL PASS"
