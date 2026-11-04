#!/usr/bin/env python3
"""
generate-rules-registry.py — собрать rules-registry.yaml из PACK-agent-rules/rules/AR.NNN.md.

Парсит frontmatter каждого файла правила, валидирует обязательные поля,
строит dependency graph, выдаёт single yaml registry для rule-engine.sh.

Запуск: python3 generate-rules-registry.py [--validate] [--output PATH] [--write-through-symlink]
Output: ~/IWE/.claude/rules-registry.yaml (по умолчанию)

Запись через ссылку отклоняется с кодом 3 (WP-7 Ф292): на Цехе реестр — ссылка
в клон iwe-local-config, и запись сквозь неё пачкает клон.
"""

import argparse
import os
import re
import sys
import yaml
from pathlib import Path

PACK_DIR = Path.home() / "IWE" / "PACK-agent-rules" / "rules"
OUTPUT = Path.home() / "IWE" / ".claude" / "rules-registry.yaml"

# WP-7 F294: `hook` is no longer required. Whether a rule has a lock (a binding to the
# rule engine) is derived by derive_lock(); a rule without one is still a valid rule.
REQUIRED_FIELDS = {"id", "name", "type", "priority", "status", "triggers", "tests"}
VALID_TYPES = {"structural", "behavioural", "procedural"}
VALID_STATUSES = {"active", "draft", "deprecated", "superseded"}
# WP-295 Ф5: deterministic step pre/post-conditions. Optional, backward-compatible.
VALID_ON_FAIL = {"warn", "block"}
# WP-481 Ф5 (CGUS): execution_mode — семантика исполнения правила. Отсутствие поля = "linear"
# (текущее поведение: правило срабатывает по триггеру в порядке потока). "constraint-satisfaction"
# — правило = ограничение на трассу сессии: удовлетворяется в любом порядке, проверяется
# полнота набора при Close (rule-engine.sh check-trace-satisfaction), не линейность.
# Имя НЕ "enforcement": ключ уже занят в AR.251 (enforcement: E3 — уровень замка, другая ось).
VALID_EXECUTION_MODES = {"linear", "constraint-satisfaction"}
# WP-7 F294: lock contract v1. A "lock" is a binding of the rule to the rule engine:
#   executable  - hook is "<file>::<identifier>"; the engine may call the function
#   unsupported - no binding, and every enforcement entry says "unsupported" (no lock exists)
#   unknown     - no binding, and the enforcement block does not prove the absence of a lock
# The state is derived, never written in a rule file: a second source of truth next to
# `hook` and `enforcement` would drift. Registry schema 1.1 carries it as `lock`.
LOCK_EXECUTABLE, LOCK_UNSUPPORTED, LOCK_UNKNOWN = "executable", "unsupported", "unknown"
VALID_LOCKS = (LOCK_EXECUTABLE, LOCK_UNSUPPORTED, LOCK_UNKNOWN)
HOOK_BINDING_RE = re.compile(r"[\w.\-/]+::[A-Za-z_]\w*")
VALID_ENFORCEMENT_CLASSES = {"enforced", "unsupported", "unknown"}
# Reference to a rule of another pack (e.g. DP.M.020). Any other id that is not a rule of
# this pack is an error, so that a typo in an AR.* id is still caught.
EXTERNAL_REF_RE = re.compile(r"DP\.[A-Z]+\.[0-9]+")
REGISTRY_SCHEMA_VERSION = "1.1"
# WP-7 F292: policy refusal, distinct from 1 (failure) and 2 (validation/argparse).
SYMLINK_REFUSAL_EXIT = 3

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

def has_hook(rule):
    """A hook key with a null value means "no hook", the same as an absent key."""
    return rule.get("hook") is not None


def hook_binding(rule):
    """The "<file>::<identifier>" binding, or None when the rule has no usable one."""
    hook = rule.get("hook")
    if isinstance(hook, str) and HOOK_BINDING_RE.fullmatch(hook.strip()):
        return hook.strip()
    return None


def validate_lock_inputs(rule, filename):
    """Errors in the fields lock derivation reads: hook and enforcement. A wrong shape is an
    error, never silently turned into `unknown`: only a missing field means "not known"."""
    errors = []
    if "lock" in rule:
        errors.append(f"{filename}: 'lock' is derived by the generator, remove it from the rule file")
    if has_hook(rule):
        hook = rule["hook"]
        if not isinstance(hook, str):
            errors.append(f"{filename}: hook must be a string, got {type(hook).__name__}")
        elif not hook.strip():
            errors.append(f"{filename}: hook is an empty string, omit it or give '<file>::<function>'")
    enforcement = rule.get("enforcement")
    if enforcement is None:
        return errors
    if not isinstance(enforcement, list):
        errors.append(f"{filename}: enforcement must be a list, got {type(enforcement).__name__}")
        return errors
    for i, entry in enumerate(enforcement):
        if not isinstance(entry, dict):
            errors.append(f"{filename}: enforcement[{i}] must be a mapping with 'class'")
        elif not isinstance(entry.get("class"), str) or entry["class"] not in VALID_ENFORCEMENT_CLASSES:
            errors.append(f"{filename}: enforcement[{i}] class must be one of "
                          f"{sorted(VALID_ENFORCEMENT_CLASSES)}, got {entry.get('class')!r}")
    return errors


def derive_lock(rule):
    """Lock state of a rule that passed validate_lock_inputs. Absence of information is not
    proof of absence of a lock, so an empty or missing enforcement block gives `unknown`."""
    if hook_binding(rule):
        return LOCK_EXECUTABLE
    enforcement = rule.get("enforcement") or []
    if enforcement and all(e["class"] == "unsupported" for e in enforcement):
        return LOCK_UNSUPPORTED
    return LOCK_UNKNOWN


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
    if not isinstance(tests, dict):
        # Старый формат `tests: [...]` (список) не несёт семантики positive/negative —
        # помечаем невалидным, НЕ коэрсим. Без этого .get() падает с AttributeError
        # и роняет весь генератор (WP-419, peer-session 2026-06-14-03).
        errors.append(f"{filename}: tests must be a dict with positive+negative keys, got {type(tests).__name__}")
    elif not tests.get("positive") or not tests.get("negative"):
        errors.append(f"{filename}: must have both positive and negative tests")

    # WP-295 Ф5: optional pre/post-conditions. When present, each must be a mapping
    # with a non-empty 'check' (named deterministic check resolved by rule-engine.sh)
    # and 'on_fail' in {warn, block}. Absent field = no conditions (backward-compatible).
    errors.extend(validate_conditions(rule, filename))
    errors.extend(validate_lock_inputs(rule, filename))

    return errors


def validate_conditions(rule, filename):
    """Validate optional pre_conditions / post_conditions structure (WP-295 Ф5)."""
    errors = []
    for field in ("pre_conditions", "post_conditions"):
        conds = rule.get(field)
        if conds is None:
            continue
        if not isinstance(conds, list):
            errors.append(f"{filename}: {field} must be a list, got {type(conds).__name__}")
            continue
        for i, cond in enumerate(conds):
            if not isinstance(cond, dict):
                errors.append(f"{filename}: {field}[{i}] must be a mapping with 'check' and 'on_fail'")
                continue
            if not cond.get("check"):
                errors.append(f"{filename}: {field}[{i}] missing non-empty 'check'")
            if cond.get("on_fail") not in VALID_ON_FAIL:
                errors.append(f"{filename}: {field}[{i}] on_fail must be one of {sorted(VALID_ON_FAIL)}, got {cond.get('on_fail')!r}")
    exm = rule.get("execution_mode")
    if exm is not None and exm not in VALID_EXECUTION_MODES:
        errors.append(f"{filename}: execution_mode must be one of {sorted(VALID_EXECUTION_MODES)}, got {exm!r}")
    return errors

def validate_cross_refs(rules, external_refs=None):
    """WP-272 Ф2.5 (R23 audit F5): проверить что все conflicts_with / depends_on /
    superseded_by ссылаются на существующие правила. WP-7 F294: ссылка на правило другого
    пака (формат EXTERNAL_REF_RE) не ошибка; такие ссылки собираются в external_refs."""
    errors = []
    rule_ids = {r["id"] for r in rules}

    def check(owner, field, ref_id):
        if not ref_id or ref_id in rule_ids:
            return
        if isinstance(ref_id, str) and EXTERNAL_REF_RE.fullmatch(ref_id):
            if external_refs is not None:
                external_refs.append((owner, field, ref_id))
            return
        errors.append(f"{owner}: {field} references non-existent rule '{ref_id}'")

    for r in rules:
        for ref_field in ("conflicts_with", "depends_on"):
            for ref_id in r.get(ref_field, []) or []:
                check(r["id"], ref_field, ref_id)
        check(r["id"], "superseded_by", r.get("superseded_by"))
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


def build_registry(skip_invalid=False, external_refs=None):
    """skip_invalid=False (--validate): любая ошибка → exit 2, реестр не пишется (строгий gate).
    skip_invalid=True (generate): невалидные правила пропускаются с предупреждением, реестр
    собирается из валидных. Без этого один дрейфующий файл (старый формат tests) блокировал
    регенерацию всего реестра — генератор был мёртв с 8 мая (WP-419, peer-session 2026-06-14-03)."""
    rules = []
    invalid_errors = []   # per-file: невалидный файл пропускается

    if not PACK_DIR.exists():
        print(f"ERROR: PACK-agent-rules/rules/ not found at {PACK_DIR}", file=sys.stderr)
        sys.exit(1)

    for rule_file in sorted(PACK_DIR.glob("AR.*.md")):
        fm = parse_frontmatter(rule_file)
        if not fm:
            invalid_errors.append(f"{rule_file.name}: no frontmatter")
            continue

        errors = validate_rule(fm, rule_file.name)
        if errors:
            invalid_errors.extend(errors)
            continue

        # `related` иногда оформлено списком вместо словаря — нормализуем, иначе .get() падает.
        related = fm.get("related", {})
        if not isinstance(related, dict):
            related = {}

        rule_entry = {
            "id": fm["id"],
            "name": fm["name"],
            "type": fm["type"],
            "priority": fm["priority"],
            "status": fm["status"],
            "triggers": fm["triggers"],
            "applies_when": fm.get("applies_when", "true"),
            "exceptions": fm.get("exceptions", []),
            "hook": hook_binding(fm),
            "lock": derive_lock(fm),
            "pre_conditions": fm.get("pre_conditions", []),
            "post_conditions": fm.get("post_conditions", []),
            "conflicts_with": related.get("conflicts_with", []),
            "depends_on": related.get("depends_on", []),
            "superseded_by": related.get("superseded_by"),
            "source_file": str(rule_file.relative_to(Path.home() / "IWE")),
        }
        # Free text written in the hook field of older rules ("... не вшит, E3") is not a
        # binding; it is kept for the reader, never executed.
        if has_hook(fm) and rule_entry["hook"] is None:
            rule_entry["hook_note"] = str(fm["hook"]).strip()
        # WP-481 Ф5: опциональное поле execution_mode (constraint-satisfaction для протокольных гейтов)
        if fm.get("execution_mode"):
            rule_entry["execution_mode"] = fm["execution_mode"]
        rules.append(rule_entry)

    # Cross-ref + cycle: считаются только по собранным валидным правилам.
    # depends_on на пропущенное (невалидное) правило → предупреждение, не блок (в skip-режиме).
    ref_errors = validate_cross_refs(rules, external_refs) + validate_no_cycles(rules)

    if not skip_invalid:
        all_errors = invalid_errors + ref_errors
        if all_errors:
            print("Validation errors:", file=sys.stderr)
            for e in all_errors:
                print(f"  {e}", file=sys.stderr)
            sys.exit(2)
    else:
        if invalid_errors:
            print(f"⚠️  пропущено невалидных правил: {len(invalid_errors)} (см. ниже; чинятся отдельно — ресинк реестра правил)", file=sys.stderr)
            for e in invalid_errors:
                print(f"  (skipped) {e}", file=sys.stderr)
        if ref_errors:
            print(f"⚠️  cross-ref/cycle предупреждений: {len(ref_errors)} (ссылка на пропущенное правило — не блок)", file=sys.stderr)
            for e in ref_errors:
                print(f"  (warn) {e}", file=sys.stderr)

    rules.sort(key=lambda r: r["priority"])

    return {
        "schema_version": REGISTRY_SCHEMA_VERSION,
        "generated_at": "auto",
        "source": "PACK-agent-rules/rules/",
        "rule_count": len(rules),
        "rules": rules,
    }

def find_symlink_on_path(output):
    """Return the first symlink the OS would traverse when opening `output`, or None.
    The output itself is always checked; a directory prefix only if it lies strictly
    below the home directory, so system links such as macOS /tmp -> /private/tmp are
    no reason to refuse (WP-7 F292). Prefixes are built from the raw components and
    never normalised: "linked/../x" goes through "linked" at open time, and a lexical
    normpath would hide that link. "Below home" is decided by where the prefix's parent
    really is (realpath), not by its spelling: aliases of home and case differences on
    macOS must not hide a link. Non-strict realpath does not raise on link cycles."""
    real_home = os.path.realpath(Path.home())
    parts = Path(os.path.join(os.getcwd(), output)).parts
    prefixes = []
    for part in parts:
        prefixes.append(os.path.join(prefixes[-1], part) if prefixes else part)
    full_path = prefixes[-1]
    for prefix in prefixes:
        parent = os.path.realpath(os.path.dirname(prefix))
        below_home = parent == real_home or parent.startswith(real_home + os.sep)
        if (prefix == full_path or below_home) and os.path.islink(prefix):
            return Path(prefix)
    return None


def describe_symlink(link):
    """"link -> target" without following the chain: dangling links and cycles must
    still produce a message, not a traceback."""
    try:
        raw = os.readlink(link)
    except OSError:
        return f"{link} -> (цель не прочитана)"
    lexical = os.path.normpath(os.path.join(os.path.dirname(link), raw))
    if lexical == raw:
        return f"{link} -> {raw}"
    return f"{link} -> {raw} (то есть {lexical})"


def refuse_symlink_write(link):
    print(f"ОТКАЗ: путь записи реестра проходит через ссылку: {describe_symlink(link)}", file=sys.stderr)
    print("  Запись сквозь ссылку изменила бы файл в другом месте (на Цехе — в клоне iwe-local-config).", file=sys.stderr)
    print("  Штатный путь на Цехе: закоммитить реестр в iwe-local-config и перемотать клон из origin.", file=sys.stderr)
    print("  Аварийно записать в цель ссылки: --write-through-symlink.", file=sys.stderr)
    sys.exit(SYMLINK_REFUSAL_EXIT)


def print_lock_counts(registry):
    counts = {state: 0 for state in VALID_LOCKS}
    for r in registry["rules"]:
        counts[r["lock"]] += 1
    print("     lock: " + ", ".join(f"{state} {n}" for state, n in counts.items()))


def parse_args(argv):
    # Arguments are parsed before anything is built or written: --help and unknown flags
    # must leave the live registry untouched (WP-7 F290, 04.11: "--help" overwrote it).
    parser = argparse.ArgumentParser(
        description="Build rules-registry.yaml from PACK-agent-rules/rules/AR.*.md.",
        epilog="exit codes: 0 ok; 1 failure; 2 validation or argument error; "
               "3 refused: the output path goes through a symlink (see --write-through-symlink)")
    parser.add_argument("--validate", action="store_true",
                        help="strict check of every rule file; nothing is written")
    parser.add_argument("--output", type=Path, default=OUTPUT,
                        help=f"registry file to write (default: {OUTPUT})")
    parser.add_argument("--write-through-symlink", action="store_true",
                        help="emergency only: write into the target of a symlink on the output path, "
                             "keeping the link. On tsekh-1 the registry is updated by committing it "
                             "to iwe-local-config and fast-forwarding the clone instead")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    # Checked before building and before mkdir/open: a refusal leaves the target tree untouched.
    symlink = find_symlink_on_path(args.output)
    if symlink and args.validate:
        # Same predicate as the refusal, printed before the strict check: the real pack
        # usually fails it (exit 2), and the warning must not depend on rule hygiene.
        print(f"ВНИМАНИЕ: запись в {args.output} была бы отклонена с кодом {SYMLINK_REFUSAL_EXIT}: "
              f"{describe_symlink(symlink)}", file=sys.stderr)
    elif symlink and not args.write_through_symlink:
        refuse_symlink_write(symlink)

    # generate: skip-invalid (best-effort реестр из валидных); --validate: строгий gate
    external_refs = []
    registry = build_registry(skip_invalid=not args.validate, external_refs=external_refs)
    if external_refs:
        print(f"external references to other packs (not checked here): {len(external_refs)}", file=sys.stderr)
        for owner, field, ref_id in external_refs:
            print(f"  {owner}: {field} -> {ref_id}", file=sys.stderr)

    if args.validate:
        print(f"OK: {registry['rule_count']} rules validated")
        print_lock_counts(registry)
        return

    output = args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        yaml.safe_dump(registry, f, allow_unicode=True, sort_keys=False, default_flow_style=False)

    print(f"OK: registry generated → {output}")
    print(f"     {registry['rule_count']} rules")
    print_lock_counts(registry)
    types = {}
    for r in registry["rules"]:
        types[r["type"]] = types.get(r["type"], 0) + 1
    for t, n in types.items():
        print(f"     {t}: {n}")

if __name__ == "__main__":
    main()
