#!/usr/bin/env python3
"""
generate-rules-registry.py — собрать rules-registry.yaml из PACK-agent-rules/rules/AR.NNN.md.

Парсит frontmatter каждого файла правила, валидирует обязательные поля,
строит dependency graph, выдаёт single yaml registry для rule-engine.sh.

Запуск: python3 generate-rules-registry.py [--validate]
Output: ~/IWE/.claude/rules-registry.yaml
"""

import os
import re
import sys
import yaml
from pathlib import Path

PACK_DIR = Path.home() / "IWE" / "PACK-agent-rules" / "rules"
OUTPUT = Path.home() / "IWE" / ".claude" / "rules-registry.yaml"

REQUIRED_FIELDS = {"id", "name", "type", "priority", "status", "triggers", "tests", "hook"}
VALID_TYPES = {"structural", "behavioural", "procedural"}
VALID_STATUSES = {"active", "draft", "deprecated", "superseded"}

def parse_frontmatter(filepath):
    """Извлечь YAML frontmatter из markdown файла."""
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
    """Проверить обязательные поля и валидность значений."""
    errors = []
    missing = REQUIRED_FIELDS - set(rule.keys())
    if missing:
        errors.append(f"{filename}: missing fields {missing}")

    if rule.get("type") not in VALID_TYPES:
        errors.append(f"{filename}: invalid type '{rule.get('type')}', expected {VALID_TYPES}")

    if rule.get("status") not in VALID_STATUSES:
        errors.append(f"{filename}: invalid status '{rule.get('status')}'")

    priority = rule.get("priority")
    if not isinstance(priority, int) or priority < 1 or priority > 15:
        errors.append(f"{filename}: priority must be int 1-15, got {priority}")

    rule_type = rule.get("type")
    if rule_type == "structural" and (priority or 99) > 5:
        errors.append(f"{filename}: structural rule must have priority 1-5")
    if rule_type == "behavioural" and ((priority or 0) < 6 or (priority or 0) > 10):
        errors.append(f"{filename}: behavioural rule must have priority 6-10")
    if rule_type == "procedural" and ((priority or 0) < 11 or (priority or 0) > 15):
        errors.append(f"{filename}: procedural rule must have priority 11-15")

    tests = rule.get("tests", {})
    if not tests.get("positive") or not tests.get("negative"):
        errors.append(f"{filename}: must have both positive and negative tests")

    return errors

def validate_cross_refs(rules):
    """WP-272 Ф2.5 (R23 audit F5): проверить что все conflicts_with / depends_on /
    superseded_by ссылаются на существующие правила."""
    errors = []
    rule_ids = {r["id"] for r in rules}
    for r in rules:
        for ref_field in ("conflicts_with", "depends_on"):
            for ref_id in r.get(ref_field, []) or []:
                if ref_id and ref_id not in rule_ids:
                    errors.append(f"{r['id']}: {ref_field} references non-existent rule '{ref_id}'")
        sup = r.get("superseded_by")
        if sup and sup not in rule_ids:
            errors.append(f"{r['id']}: superseded_by references non-existent rule '{sup}'")
    return errors


def validate_no_cycles(rules):
    """WP-272 Ф4 closure (audit VR.R.002, 27 апр): проверить, что граф depends_on
    ацикличен (DFS с покраской). Цикл = ошибка проектирования: A → B → A
    означает, что один из direction'ов неверен (одно из правил — частный случай другого
    или зависимость не в ту сторону)."""
    errors = []
    graph = {r["id"]: list(r.get("depends_on") or []) for r in rules}
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {rid: WHITE for rid in graph}

    def dfs(node, path):
        if color[node] == GRAY:
            cycle = path[path.index(node):] + [node]
            errors.append(f"cycle detected in depends_on: {' → '.join(cycle)}")
            return
        if color[node] == BLACK:
            return
        color[node] = GRAY
        for nbr in graph.get(node, []):
            if nbr in graph:
                dfs(nbr, path + [node])
        color[node] = BLACK

    for rid in graph:
        if color[rid] == WHITE:
            dfs(rid, [])
    return errors


def build_registry():
    rules = []
    all_errors = []

    if not PACK_DIR.exists():
        print(f"ERROR: PACK-agent-rules/rules/ not found at {PACK_DIR}", file=sys.stderr)
        sys.exit(1)

    for rule_file in sorted(PACK_DIR.glob("AR.*.md")):
        fm = parse_frontmatter(rule_file)
        if not fm:
            all_errors.append(f"{rule_file.name}: no frontmatter")
            continue

        errors = validate_rule(fm, rule_file.name)
        if errors:
            all_errors.extend(errors)
            continue

        rules.append({
            "id": fm["id"],
            "name": fm["name"],
            "type": fm["type"],
            "priority": fm["priority"],
            "status": fm["status"],
            "triggers": fm["triggers"],
            "applies_when": fm.get("applies_when", "true"),
            "exceptions": fm.get("exceptions", []),
            "hook": fm["hook"],
            "conflicts_with": fm.get("related", {}).get("conflicts_with", []),
            "depends_on": fm.get("related", {}).get("depends_on", []),
            "superseded_by": fm.get("related", {}).get("superseded_by"),
            "source_file": str(rule_file.relative_to(Path.home() / "IWE")),
        })

    # Cross-reference validation после parsing всех правил
    cross_errors = validate_cross_refs(rules)
    all_errors.extend(cross_errors)

    # Cycle detection в depends_on графе (Ф4 closure)
    cycle_errors = validate_no_cycles(rules)
    all_errors.extend(cycle_errors)

    if all_errors:
        print("Validation errors:", file=sys.stderr)
        for e in all_errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(2)

    rules.sort(key=lambda r: r["priority"])

    return {
        "schema_version": "1.0",
        "generated_at": "auto",
        "source": "PACK-agent-rules/rules/",
        "rule_count": len(rules),
        "rules": rules,
    }

def main():
    validate_only = "--validate" in sys.argv

    registry = build_registry()

    if validate_only:
        print(f"OK: {registry['rule_count']} rules validated")
        return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as f:
        yaml.safe_dump(registry, f, allow_unicode=True, sort_keys=False, default_flow_style=False)

    print(f"OK: registry generated → {OUTPUT}")
    print(f"     {registry['rule_count']} rules")
    types = {}
    for r in registry["rules"]:
        types[r["type"]] = types.get(r["type"], 0) + 1
    for t, n in types.items():
        print(f"     {t}: {n}")

if __name__ == "__main__":
    main()
