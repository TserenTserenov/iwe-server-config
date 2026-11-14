#!/usr/bin/env python3
"""Check delivery of the "Дальше:" rule (A12) to agents, not model behavior.

Run against explicit checkouts (use immutable revisions when verifying a release):
    python3 scripts/tests/test_wp603_delivery.py --root PATH [--template PATH]

What is checked (WP-7 F309, rewritten after WP-605 F6 replaced the WP-603
wording of A12 on 2026-10-23, commit 72d1a3035):
  1. CLAUDE.md and AGENTS.md carry exactly one current A12 paragraph with its
     key clauses, and AGENTS.md matches the generator byte for byte.
  2. The pack (source of truth) carries the full rule, register rule 6.1-6.7.
  3. The style hook really outputs the rule: the hook runs in an isolated
     HOME and project folder, first with only the fallback snapshot
     (.claude/styles/s0-core.md, no PACK-rhetoric dispatcher), then with the
     dispatcher if the root has one. Text present in a file is not delivery.

Three WP-603 clauses removed from the core by WP-605 F6 exist in neither the
pack nor the author layer; whether to restore them is the pilot's decision
(WP-7 F309 checklist), so they are not required here.
"""

import argparse
import os
import shutil
import site
import subprocess
import sys
import tempfile
from pathlib import Path

A12_MARKER = "**A12 (БЛОКИРУЮЩЕЕ, все агенты, любая сессия)**"
CORE_CLAUSES = {
    "one line per turn": "одной на весь ход, в конце последнего сообщения",
    "line format": "Запись «кто[, где]: что»",
    "two readings fail": "два прочтения — нарушение",
    "pointer names the register list": "(полный текст — пак, регистр 6)",
}
PACK_FILE = "PACK-digital-platform/pack/digital-platform/02-domain-entities/communication-style-base.md"
PACK_CLAUSES = {
    "6.1 one line per turn": "**6.1 Одна строка на ход.**",
    "6.2 who/where/what": "**6.2 Шаг записывают «кто[, где]: что».**",
    "6.3 place": "**6.3 Где - только если не этот чат.**",
    "6.5 closed session": "**6.5 Закрытая сессия.**",
}
# Phrases that prove the hook delivered the rule and the ontology rule.
DELIVERED = {
    "next-step rule": "Шаг записывают «кто[, где]: что»",
    "ontology rule": "Онтологическая чистота: не смешивать роды",
}
# Only the PACK-rhetoric dispatcher adds the author layer S1; the snapshot never
# has it. Without this check a broken dispatcher would pass on the snapshot.
DISPATCHER_ONLY = "Авторский стиль общения (S1)"
HOOK = ".claude/hooks/inject-communication-style.sh"
# Warm-up hands out every part on consecutive turns; 30 turns cover the
# largest style seen so far (about ten parts) with a wide margin.
HOOK_TURNS = 30


def normalize(text):
    return " ".join(text.replace("—", "-").split())


def a12_paragraph(text):
    paragraphs = [p for p in text.split("\n\n") if A12_MARKER in p]
    if len(paragraphs) != 1:
        raise ValueError(f"expected exactly one A12 paragraph; found {len(paragraphs)}")
    return normalize(paragraphs[0])


def check_core(path):
    try:
        paragraph = a12_paragraph(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        return [(f"{path.name}: readable, unique A12", False, str(error))]
    return [
        (f"{path.name}: {name}", normalize(clause) in paragraph, clause)
        for name, clause in CORE_CLAUSES.items()
    ]


def check_pack(root):
    path = root / PACK_FILE
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        return [("pack: readable", False, str(error))]
    return [(f"pack: {name}", clause in text, clause) for name, clause in PACK_CLAUSES.items()]


def check_generated_agents(root):
    # Bypass environment loading so --root stays authoritative.
    env = {
        **os.environ,
        "IWE_ROOT": str(root),
        "WORKSPACE_DIR": str(root),
        "_IWE_ENV_BOOTSTRAP_SOURCED": "1",
        "HERMES_RUNTIME_DIR": str(root),
    }
    try:
        result = subprocess.run(
            ["bash", str(root / "scripts/sync-agent-instructions.sh"), "--check"],
            cwd=root, env=env, text=True, encoding="utf-8",
            capture_output=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return ("AGENTS.md exactly matches canonical generation", False, str(error))
    return (
        "AGENTS.md exactly matches canonical generation",
        result.returncode == 0,
        (result.stdout + result.stderr).strip(),
    )


def hook_output(root, project, home, session):
    """Run the style hook HOOK_TURNS times in one session; return all output."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "CLAUDE_PROJECT_DIR": str(project),
        # User site-packages live under the real HOME (the dispatcher needs yaml).
        "PYTHONUSERBASE": site.getuserbase(),
    }
    chunks = []
    for _ in range(HOOK_TURNS):
        result = subprocess.run(
            ["bash", str(project / HOOK)],
            input=f'{{"session_id": "{session}"}}',
            env=env, text=True, encoding="utf-8",
            capture_output=True, timeout=60, check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(f"hook exited {result.returncode}: {result.stderr.strip()}")
        chunks.append(result.stdout)
    return "\n".join(chunks)


def make_project(root, base, with_dispatcher):
    """A throwaway project: the root's hooks and snapshot, optionally the dispatcher."""
    project = base / ("with-dispatcher" if with_dispatcher else "snapshot-only")
    shutil.copytree(root / ".claude/hooks", project / ".claude/hooks")
    shutil.copytree(root / ".claude/styles", project / ".claude/styles")
    if with_dispatcher:
        for name in ("PACK-rhetoric", "PACK-digital-platform", "DS-my-strategy"):
            if (root / name).exists():
                (project / name).symlink_to(root / name)
    return project


def check_hook_delivery(root):
    checks = []
    with tempfile.TemporaryDirectory(prefix="wp603-hook-") as tmp:
        base = Path(tmp)
        modes = [("snapshot only (no PACK-rhetoric dispatcher)", False)]
        if (root / "PACK-rhetoric").exists():
            modes.append(("with PACK-rhetoric dispatcher", True))
        else:
            print("SKIP: hook with dispatcher - PACK-rhetoric not in --root")
        for label, with_dispatcher in modes:
            home = base / f"home-{int(with_dispatcher)}"
            home.mkdir()
            project = make_project(root, base, with_dispatcher)
            try:
                output = hook_output(root, project, home, f"wp603-{int(with_dispatcher)}")
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                checks.append((f"hook, {label}: runs", False, str(error)))
                continue
            checks.extend(
                (f"hook, {label}: delivers {name}", phrase in output, phrase)
                for name, phrase in DELIVERED.items()
            )
            if with_dispatcher:
                checks.append((f"hook, {label}: dispatcher really ran (S1 present)", DISPATCHER_ONLY in output, DISPATCHER_ONLY))
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, type=Path, help="IWE root checkout")
    parser.add_argument("--template", type=Path, help="FMT checkout (optional)")
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    checks = []
    for name in ("CLAUDE.md", "AGENTS.md"):
        checks.extend(check_core(root / name))
    checks.append(check_generated_agents(root))
    checks.extend(check_pack(root))
    checks.extend(check_hook_delivery(root))
    if args.template:
        template_style = args.template.expanduser().resolve() / "memory/communication-style-base.md"
        try:
            found = "(A12" in template_style.read_text(encoding="utf-8")
        except OSError as error:
            found, template_style = False, f"{template_style}: {error}"
        checks.append(("template: style base names A12", found, str(template_style)))
    for name, passed, detail in checks:
        print(f"{'OK' if passed else 'FAIL'}: {name}")
        if not passed:
            print(f"  {detail}")
    passed = sum(check[1] for check in checks)
    print(f"Delivery checks: {passed}/{len(checks)} passed.")
    print("This checks instruction files and hook output only; it does not prove model behavior.")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
