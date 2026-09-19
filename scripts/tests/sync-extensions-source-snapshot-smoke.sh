#!/usr/bin/env bash
# Verifies that sync-extensions.sh reads every delivered tree from the explicit
# immutable source snapshot instead of the shared ~/IWE checkout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sync-extensions-source.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURE_REPO="$WORK/server"
SOURCE="$WORK/source"
mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/server-extensions"
git -C "$FIXTURE_REPO" init -q
cp "$REPO_ROOT/scripts/sync-extensions.sh" "$FIXTURE_REPO/scripts/"

mkdir -p \
  "$SOURCE/scripts" \
  "$SOURCE/extensions" \
  "$SOURCE/.claude/skills/demo" \
  "$SOURCE/.claude/hooks" \
  "$SOURCE/.claude/scripts"
printf 'snapshot-script\n' > "$SOURCE/scripts/from-snapshot.sh"
printf 'snapshot-extension\n' > "$SOURCE/extensions/from-snapshot.txt"
printf 'snapshot-skill\n' > "$SOURCE/.claude/skills/demo/SKILL.md"
printf 'snapshot-hook\n' > "$SOURCE/.claude/hooks/hook.sh"
printf 'snapshot-claude-script\n' > "$SOURCE/.claude/scripts/tool.sh"
printf 'snapshot-instructions\n' > "$SOURCE/CLAUDE.md"

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
git -C "$SOURCE" add -- .
git -C "$SOURCE" commit -qm fixture
EXPECTED_SHA=$(git -C "$SOURCE" rev-parse HEAD)

cat > "$WORK/lint.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/lint.sh"
cat > "$WORK/classifier.py" <<'EOF'
raise SystemExit(0)
EOF

IWE_EXTENSIONS_SOURCE_ROOT="$SOURCE" \
SYNC_EXTENSIONS_LINT="$WORK/lint.sh" \
SYNC_EXTENSIONS_CLASSIFIER="$WORK/classifier.py" \
  bash "$FIXTURE_REPO/scripts/sync-extensions.sh" >/dev/null

test "$(cat "$FIXTURE_REPO/server-extensions/ROOT_COMMIT_SHA")" = "$EXPECTED_SHA"
test "$(cat "$FIXTURE_REPO/server-extensions/scripts/from-snapshot.sh")" = snapshot-script
test "$(cat "$FIXTURE_REPO/server-extensions/extensions/from-snapshot.txt")" = snapshot-extension
test "$(cat "$FIXTURE_REPO/server-extensions/claude-skills/demo/SKILL.md")" = snapshot-skill
test "$(cat "$FIXTURE_REPO/server-extensions/claude-hooks/hook.sh")" = snapshot-hook
test "$(cat "$FIXTURE_REPO/server-extensions/claude-scripts/tool.sh")" = snapshot-claude-script
test "$(cat "$FIXTURE_REPO/server-extensions/CLAUDE.md")" = snapshot-instructions

echo "PASS: sync-extensions uses the explicit source snapshot"
