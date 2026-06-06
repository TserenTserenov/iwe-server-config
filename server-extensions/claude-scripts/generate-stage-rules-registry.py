#!/usr/bin/env python3
"""
generate-stage-rules-registry.py — собрать stage-rules-registry.yaml из PACK-agent-rules/rules/SR.NNN.md.

SR (Stage Rules) — вычислительные предикаты для stage-evaluation-worker.
Отличие от AR (Agent Rules): не pre-action gates агента, а SQL/Python условия
оценки ступени мастерства. Исполняются projection-worker, не rule-engine.sh.

Запуск: python3 generate-stage-rules-registry.py [--validate]
Output: ~/IWE/.claude/stage-rules-registry.yaml
"""

import re
import sys
import yaml
from pathlib import Path

PACK_DIR = Path.home() / "IWE" / "PACK-agent-rules" / "rules"
OUTPUT = Path.home() / "IWE" / ".claude" / "stage-rules-registry.yaml"

REQUIRED_FIELDS = {"id", "name", "type", "priority", "status", "triggers", "stage_from", "stage_to", "condition", "tests"}
VALID_TYPES = {"stage_gate"}
VALID_STATUSES = {"active", "draft", "deprecated", "superseded"}


def parse_frontmatter(filepath):
    content = filepath.read_text(encoding="utf-8")
    match = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
    if not match:
        return None
    try:
        return yaml.safe_load(match.group(1))
    except yaml.YAMLError as e:
        print(f"ERROR: invalid YAML in {filepath.name}: {e}", file=sys.stderr)
        return None


def validate_rule(rule, filename):
    errors = []
    missing = REQUIRED_FIELDS - set(rule.keys())
    if missing:
        errors.append(f"{filename}: missing fields {missing}")

    if rule.get("type") not in VALID_TYPES:
        errors.append(f"{filename}: invalid type '{rule.get('type')}', expected {VALID_TYPES}")

    if rule.get("status") not in VALID_STATUSES:
        errors.append(f"{filename}: invalid status '{rule.get('status')}'")

    sf = rule.get("stage_from")
    st = rule.get("stage_to")
    if not isinstance(sf, int) or not isinstance(st, int):
        errors.append(f"{filename}: stage_from/stage_to must be integers")
    elif st != sf + 1:
        errors.append(f"{filename}: stage_to must equal stage_from + 1 (got {sf}→{st})")

    tests = rule.get("tests", {})
    if not tests.get("positive") or not tests.get("negative"):
        errors.append(f"{filename}: must have both positive and negative tests")

    return errors


def build_registry():
    rules = []
    all_errors = []

    if not PACK_DIR.exists():
        print(f"ERROR: PACK-agent-rules/rules/ not found at {PACK_DIR}", file=sys.stderr)
        sys.exit(1)

    for rule_file in sorted(PACK_DIR.glob("SR.*.md")):
        fm = parse_frontmatter(rule_file)
        if not fm:
            all_errors.append(f"{rule_file.name}: no frontmatter")
            continue

        errors = validate_rule(fm, rule_file.name)
        if errors:
            all_errors.extend(errors)
            continue

        related = fm.get("related", {})
        rules.append({
            "id": fm["id"],
            "name": fm["name"],
            "type": fm["type"],
            "priority": fm["priority"],
            "status": fm["status"],
            "stage_from": fm["stage_from"],
            "stage_to": fm["stage_to"],
            "triggers": fm["triggers"],
            "applies_when": fm.get("applies_when", "rcs_profile_updated"),
            "condition": fm.get("condition", ""),
            "mnemonic": fm.get("mnemonic", ""),
            "depends_on": related.get("depends_on", []),
            "associated_with": related.get("associated_with", []),
            "critical_for": related.get("critical_for", []),
            "source_file": str(rule_file.relative_to(Path.home() / "IWE")),
        })

    if all_errors:
        print("Validation errors:", file=sys.stderr)
        for e in all_errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(2)

    rules.sort(key=lambda r: r["stage_from"])

    return {
        "schema_version": "1.0",
        "generated_at": "auto",
        "source": "PACK-agent-rules/rules/SR.*.md",
        "description": "Stage Gate rules — evaluated by stage-evaluation-worker, NOT rule-engine.sh",
        "rule_count": len(rules),
        "rules": rules,
    }


def main():
    validate_only = "--validate" in sys.argv
    registry = build_registry()

    if validate_only:
        print(f"OK: {registry['rule_count']} stage rules validated")
        return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as f:
        yaml.safe_dump(registry, f, allow_unicode=True, sort_keys=False, default_flow_style=False)

    print(f"OK: stage-rules-registry generated → {OUTPUT}")
    print(f"     {registry['rule_count']} stage rules (ступени 1→5)")
    for r in registry["rules"]:
        print(f"     SR.{r['stage_from']:03d}: ст. {r['stage_from']}→{r['stage_to']} ({r['id']})")


if __name__ == "__main__":
    main()
