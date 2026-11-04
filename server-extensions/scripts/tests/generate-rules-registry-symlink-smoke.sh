#!/bin/bash
# generate-rules-registry-symlink-smoke.sh -- WP-7 F292: the rules-registry generator
# refuses (exit 3) to write when the output path goes through a symlink (the output
# itself or a parent strictly below HOME), leaves the target tree untouched, writes
# through only with --write-through-symlink, and --validate warns on the same predicate.
set -uo pipefail

GEN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/generate-rules-registry.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"
EXT="$TMP/ext"   # stands for the iwe-local-config clone: link targets live here
mkdir -p "$H/IWE/.claude" "$H/IWE/PACK-agent-rules/rules" "$EXT"

# One valid synthetic rule: the real pack does not pass strict --validate.
cat > "$H/IWE/PACK-agent-rules/rules/AR.001.md" <<'EOF'
---
id: AR.001
name: smoke rule
type: structural
priority: 1
status: active
triggers: [always]
tests: {positive: [a], negative: [b]}
hook: none
---
body
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
# HOME is swapped for the generator, which hides per-user site-packages (where PyYAML
# often lives); keep them importable.
USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
export PYTHONPATH="$USER_SITE${PYTHONPATH:+:$PYTHONPATH}"
HOME="$H" python3 -c 'import yaml' 2>/dev/null || fail "PyYAML is not importable: the test cannot reach the guard"
gen() { HOME="$H" python3 "$GEN" "$@" >"$TMP/out" 2>"$TMP/err"; }
tree() { (cd "$1" && find . | LC_ALL=C sort); }

# 1. Regular file at the default path is written.
gen; rc=$?
[ "$rc" -eq 0 ] || fail "default path: rc=$rc $(cat "$TMP/err")"
[ -f "$H/IWE/.claude/rules-registry.yaml" ] && [ ! -L "$H/IWE/.claude/rules-registry.yaml" ] || fail "default path: regular file not written"
grep -q '^rule_count: 1$' "$H/IWE/.claude/rules-registry.yaml" || fail "default path: registry content wrong"
rm "$H/IWE/.claude/rules-registry.yaml"

# 2. Output is a symlink -> 3, target byte-for-byte unchanged, link kept.
printf 'ORIG\n' > "$EXT/reg.yaml"
ln -s "$EXT/reg.yaml" "$H/IWE/.claude/rules-registry.yaml"
gen; rc=$?
[ "$rc" -eq 3 ] || fail "output link: expected 3, got $rc"
[ "$(cat "$EXT/reg.yaml")" = ORIG ] || fail "output link: target was modified"
[ -L "$H/IWE/.claude/rules-registry.yaml" ] || fail "output link: link replaced"
grep -q "$EXT/reg.yaml" "$TMP/err" || fail "output link: diagnostic does not name the target"

# 3. --validate on the same path -> 0, warning on stderr, nothing touched.
gen --validate; rc=$?
[ "$rc" -eq 0 ] || fail "validate via link: expected 0, got $rc $(cat "$TMP/err")"
grep -q 'была бы отклонена с кодом 3' "$TMP/err" || fail "validate via link: no warning"
[ "$(cat "$EXT/reg.yaml")" = ORIG ] || fail "validate via link: target was modified"

# 4. --write-through-symlink -> target updated, link still a link.
gen --write-through-symlink; rc=$?
[ "$rc" -eq 0 ] || fail "flag: rc=$rc $(cat "$TMP/err")"
grep -q '^rule_count: 1$' "$EXT/reg.yaml" || fail "flag: target not updated"
[ -L "$H/IWE/.claude/rules-registry.yaml" ] || fail "flag: link replaced by a file"
rm "$H/IWE/.claude/rules-registry.yaml"

# 5. Dangling link -> 3, target not created.
ln -s "$EXT/missing.yaml" "$H/dangling.yaml"
gen --output "$H/dangling.yaml"; rc=$?
[ "$rc" -eq 3 ] || fail "dangling link: expected 3, got $rc"
[ ! -e "$EXT/missing.yaml" ] || fail "dangling link: target was created"

# 6. Link to a directory -> 3, directory unchanged.
mkdir -p "$EXT/dir"
ln -s "$EXT/dir" "$H/dir-link"
gen --output "$H/dir-link"; rc=$?
[ "$rc" -eq 3 ] || fail "directory link: expected 3, got $rc"
[ -z "$(ls -A "$EXT/dir")" ] || fail "directory link: directory changed"

# 7. Parent below HOME is a link -> 3, whole target tree unchanged (no mkdir in it).
mkdir -p "$EXT/clone"
ln -s "$EXT/clone" "$H/linked"
before=$(tree "$EXT/clone")
gen --output "$H/linked/sub/reg.yaml"; rc=$?
[ "$rc" -eq 3 ] || fail "parent link: expected 3, got $rc"
[ "$(tree "$EXT/clone")" = "$before" ] || fail "parent link: target tree changed"

# 7a. ".." after a link: the OS walks through the link, lexical normalisation would not.
gen --output "$H/linked/../dotdot.yaml"; rc=$?
[ "$rc" -eq 3 ] || fail "'..' after link: expected 3, got $rc"
[ ! -e "$EXT/dotdot.yaml" ] || fail "'..' after link: wrote into the link target's parent"

# 7b. Relative --output through a link below HOME.
(cd "$H" && HOME="$H" python3 "$GEN" --output linked/rel.yaml >"$TMP/out" 2>"$TMP/err"); rc=$?
[ "$rc" -eq 3 ] || fail "relative path via link: expected 3, got $rc"
[ ! -e "$EXT/clone/rel.yaml" ] || fail "relative path via link: target written"

# 7c. HOME reached through an alias link above it: the link inside HOME still counts.
ln -s "$H" "$TMP/home-alias"
gen --output "$TMP/home-alias/linked/alias.yaml"; rc=$?
[ "$rc" -eq 3 ] || fail "home alias: expected 3, got $rc"
[ ! -e "$EXT/clone/alias.yaml" ] || fail "home alias: target written"

# 8. Link above HOME (system link such as macOS /tmp) is not a reason to refuse.
mkdir -p "$TMP/sys-real"
ln -s "$TMP/sys-real" "$TMP/sys-link"
gen --output "$TMP/sys-link/reg.yaml"; rc=$?
[ "$rc" -eq 0 ] || fail "link outside HOME: rc=$rc $(cat "$TMP/err")"
grep -q '^rule_count: 1$' "$TMP/sys-real/reg.yaml" || fail "link outside HOME: file not written"

# 9. Link cycle -> 3 with a message, not a traceback.
ln -s "$H/cycle-b" "$H/cycle-a"
ln -s "$H/cycle-a" "$H/cycle-b"
gen --output "$H/cycle-a"; rc=$?
[ "$rc" -eq 3 ] || fail "link cycle: expected 3, got $rc $(cat "$TMP/err")"
grep -q Traceback "$TMP/err" && fail "link cycle: traceback instead of a refusal"

echo "OK: generate-rules-registry symlink guard (12 cases)"
