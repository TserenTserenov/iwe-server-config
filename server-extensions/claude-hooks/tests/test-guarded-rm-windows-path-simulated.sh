#!/usr/bin/env bash
# Simulated Windows path-handling check for .claude/bin/guarded-rm (issue #1005a).
#
# NOT a substitute for running guarded-rm under real Git Bash on Windows: it
# fakes `cygpath` with a minimal shell shim so the WINDOWS=1 branch of
# canon()/windows_long_path() runs on macOS/Linux too, and checks the logic
# is internally consistent (long-name expansion, lower-casing, nonexistent
# suffix preserved). It cannot catch real cygpath quirks (8.3 short-name
# edge cases, drive letter mapping specifics, line-ending handling) that
# only show up on an actual Windows host.
set -euo pipefail

GUARDED_RM="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)/guarded-rm"
[ -x "$GUARDED_RM" ] || { echo "guarded-rm not found/executable at $GUARDED_RM" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/fakebin"
mkdir -p "$WORKDIR/RUNNER~1/target-dir"

# Fake cygpath: -u passes the path through unchanged (we feed POSIX paths
# already); -m -l returns an uppercase-drive "long form" so we can check
# windows_long_path() resolves the 8.3-style short segment and the tr
# lower-casing step in canon() actually runs.
cat > "$WORKDIR/fakebin/cygpath" <<'EOF'
#!/usr/bin/env bash
mode_u=0
mode_ml=0
args=()
for a in "$@"; do
  case "$a" in
    -u) mode_u=1 ;;
    -m|-l) mode_ml=1 ;;
    --) ;;
    *) args+=("$a") ;;
  esac
done
path="${args[-1]}"
if [ "$mode_u" = 1 ]; then
  printf '%s\n' "$path"
  exit 0
fi
if [ "$mode_ml" = 1 ]; then
  # Simulate 8.3 short-name expansion for the one fixture directory that has
  # it, wherever it falls in the resolved path (real cygpath -m -l expands
  # the whole path, not just a trailing component).
  printf '%s\n' "${path/RUNNER~1/RUNNER-LONG-NAME}"
  exit 0
fi
printf '%s\n' "$path"
EOF
chmod +x "$WORKDIR/fakebin/cygpath"

RESULT=$(PATH="$WORKDIR/fakebin:$PATH" bash -c '
  source /dev/stdin <<SCRIPT
$(sed -n "/^WINDOWS=0/,/^ROOTS=()/p" "'"$GUARDED_RM"'" | sed "\$d")
SCRIPT
  canon "'"$WORKDIR"'/RUNNER~1/target-dir/missing-child"
' 2>&1) || { echo "FAIL: canon() under simulated Windows crashed: $RESULT" >&2; exit 1; }

echo "canon() result: $RESULT"

case "$RESULT" in
  *runner~1*) echo "FAIL: 8.3 short name was not expanded by windows_long_path()" >&2; exit 1 ;;
esac
case "$RESULT" in
  *runner-long-name*) : ;;
  *) echo "FAIL: expected the mocked long-name expansion in the result" >&2; exit 1 ;;
esac
case "$RESULT" in
  *[A-Z]*) echo "FAIL: canon() did not lower-case the Windows path" >&2; exit 1 ;;
esac
case "$RESULT" in
  */missing-child) : ;;
  *) echo "FAIL: nonexistent trailing segment was not preserved" >&2; exit 1 ;;
esac

echo "PASS: simulated Windows canon()/windows_long_path() logic is internally consistent"
echo "NOTE: this is a mock-cygpath simulation, not a real Git Bash / Windows run"
