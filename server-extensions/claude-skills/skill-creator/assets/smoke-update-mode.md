# Smoke test cases — skill-creator update mode

> Test suite for Ф8 (WP-422). Scenarios 1–2 covered by Ф3–Ф7.
> Run scenarios 3–5 manually on temp skills before closing WP-422.

---

## Scenario 1: New skill (DONE — covered by Ф3–Ф6)

**Input:** `/skill-creator` with name `skill-creator`, no existing SKILL.md.
**Expected:** Step 2.5 skips update branch, proceeds to Step 3 IntegrationGate.
**Result:** PASS (Ф3 session 2026-06-16-14-wp422-scaffold-init-smoke)

---

## Scenario 2: Update existing skill (DONE — covered by Ф7)

**Input:** `/skill-creator` on `agent-fault` and `apply-captures` (existing SKILL.md).
**Expected:** Step 2.5 detects existing file, shows update menu, applies edits via Edit tool.
**Result:** PASS (Ф7 session 2026-06-17-03-wp422-skill-creator-f7)

---

## Scenario 3: Layer swap (project → user level)

**Temp skill name:** `smoke-layer-swap`

**Setup:**
```bash
mkdir -p /tmp/smoke-layer-swap-test/.claude/skills/smoke-layer-swap
cat > /tmp/smoke-layer-swap-test/.claude/skills/smoke-layer-swap/SKILL.md <<'EOF'
---
name: smoke-layer-swap
version: 0.1.0
status: experimental
layer: L1
agents: single
interaction: one-shot
---
# smoke-layer-swap
EOF
```

**Step 1 — Invoke skill-creator with target user-level:**
Ask skill-creator to create `smoke-layer-swap` targeting `~/.claude/skills/`.

**Expected behavior:**
- Step 2.5: detects existing SKILL.md at `.claude/skills/smoke-layer-swap/SKILL.md`
- Offers update menu, NOT fresh scaffold at user-level path
- Layer change NOT offered in menu (known limitation: skill-creator does not move skills between layers)
- Note shown: "To change layer: delete current SKILL.md manually, then run /skill-creator again targeting new path"

**Step 2 — Manual delete + recreate:**
```bash
rm -rf /tmp/smoke-layer-swap-test/.claude/skills/smoke-layer-swap
```
Run `/skill-creator` with `target: ~/.claude/skills/smoke-layer-swap/`.

**Expected behavior:**
- Step 2.5: no existing SKILL.md at new path → proceeds to Step 3 (create mode)
- Step 4 collects params, Step 5 scaffolds at `~/.claude/skills/smoke-layer-swap/`
- Step 7: `verify-skill.sh smoke-layer-swap` PASS

**PASS criteria:**
- [x] Step 2.5 does NOT trigger update-mode at the new (user-level) path
- [x] Scaffold created at correct path
- [x] `verify-skill.sh` passes (ignoring L1 location check — see Known gap below)

**Result:** PASS (WP-422 Ф8, 2026-06-17)

---

## Scenario 4: Cross-platform migration (Claude → Kimi)

**Temp skill name:** `smoke-claude-to-kimi`

**Setup:** Create temp skill in `.claude/skills/smoke-claude-to-kimi/`.

**Step 1 — Manual delete from Claude target:**
```bash
rm -rf .claude/skills/smoke-claude-to-kimi
```

**Step 2 — Run /skill-creator with platform: kimi:**
Invoke skill-creator, select `platform: kimi` when asked in Step 2 (Routing Gate).

**Expected behavior:**
- Step 2: target path = `.kimi/skills/smoke-claude-to-kimi/`
- Step 2.5: no existing SKILL.md at `.kimi/skills/smoke-claude-to-kimi/` → create mode
- Step 5: scaffold at `.kimi/skills/smoke-claude-to-kimi/SKILL.md`
- Step 7: `verify-skill.sh smoke-claude-to-kimi` runs

**PASS criteria:**
- [x] Scaffold created at `.kimi/skills/smoke-claude-to-kimi/SKILL.md`
- [x] Frontmatter contains correct `agents` and `interaction` fields
- [x] `verify-skill.sh` runs without fatal error
- [x] Known gap: `check_l1_location` skipped (L2 layer → no FMT check). For L1 kimi skills, WARN expected — documented.

**Result:** PASS (WP-422 Ф8, 2026-06-17)

**Known gap (verified Ф8):** `verify-skill.sh check_l1_location` only checks `.claude/skills/` paths.
For `.kimi/skills/` targets, `L1 location` check is skipped or WARNs. This is acceptable until
`verify-skill.sh` is extended to support multi-platform targets.

---

## Scenario 5: Path hardening (no hardcoded absolute paths)

**Check script:**
```bash
cd ~/IWE
echo "=== Checking for hardcoded user paths in .claude/skills/ ==="
grep -r '/Users/' .claude/skills/ --include="*.md" --include="*.sh" -l 2>/dev/null | head -20
grep -r '/home/' .claude/skills/ --include="*.md" --include="*.sh" -l 2>/dev/null | head -20
grep -rE 'IWE_DIR|IWE_GOVERNANCE_REPO' .claude/skills/ --include="*.sh" -l 2>/dev/null | head -20
echo "=== Checking FMT copy ==="
grep -r '/Users/' FMT-exocortex-template/.claude/skills/ --include="*.md" --include="*.sh" -l 2>/dev/null | head -20
```

**PASS criteria:**
- [x] Zero files with `/Users/` in `.claude/skills/` (smoke-update-mode.md uses it as grep search string, not hardcoded path)
- [x] Zero files with `/Users/` in `FMT-exocortex-template/.claude/skills/`
- [x] Scripts in `scripts/` use `$IWE_DIR` or relative paths, not hardcoded `/Users/tserentserenov`

**Result:** PASS (WP-422 Ф8, 2026-06-17). Fixed: `org-dev/test_skill.sh`, `audit-docs/SKILL.md`.

---

## Summary

| Scenario | Status | Notes |
|----------|--------|-------|
| 1. New skill | PASS (Ф3–Ф6) | |
| 2. Update existing | PASS (Ф7) | agent-fault, apply-captures |
| 3. Layer swap | PASS (Ф8, 2026-06-17) | delete+recreate, verify-skill.sh PASS |
| 4. Claude→Kimi | PASS (Ф8, 2026-06-17) | .kimi/skills/ scaffold, L2 layer → no FMT check |
| 5. Path hardening | PASS (Ф8, 2026-06-17) | Fixed org-dev/test_skill.sh + audit-docs/SKILL.md |
