#!/usr/bin/env python3
"""Check WP-603 instruction delivery, not model behavior or remote publication.

Run against explicit checkouts (use immutable revisions when verifying a release):
    python3 scripts/tests/test_wp603_delivery.py --root PATH --template PATH

Only reads files. The canonical generator runs in --check mode with an explicit
root and without loading a checkout's potentially unrelated .exocortex.env.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# These shared clauses are the delivery contract, not a semantic model evaluator.
# Keep checks inside the actual A12 paragraph so unrelated prose cannot satisfy it.
REQUIRED_CLAUSES = {
    "target action evidence": "результат именно целевого действия",
    "returned background identifier": "с возвращённым ID",
    "unfinished task stays open": (
        "конкретное ожидание или блокер, при которых незавершённое поручение "
        "остаётся открытым"
    ),
    "nothing pending only after completion": (
        "«ничего не жду» только при завершённом объёме и отсутствии доступных действий"
    ),
    "act before final response": "Доступное действие выполняется до финального ответа",
    "tool requirement scoped to tool actions": (
        "если оно требует инструмента, утверждение подтверждается результатом "
        "именно целевого вызова"
    ),
    "unrelated and failed calls excluded": "чужой или неуспешный вызов не считается",
    "quoted errors are not promises": (
        "цитата и разбор чужой ошибки - не обещание агента"
    ),
}


def normalize(text):
    return " ".join(text.replace("—", "-").split())


def a12_paragraph(text, marker):
    paragraphs = re.split(r"\n\s*\n", text)
    matches = [paragraph for paragraph in paragraphs if marker in paragraph]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one A12 paragraph; found {len(matches)}")
    return normalize(matches[0])


def check_document(path, marker):
    try:
        text = path.read_text(encoding="utf-8")
        paragraph = a12_paragraph(text, marker)
    except (OSError, UnicodeError, ValueError) as error:
        return [(f"{path}: readable, unique A12", False, str(error))]

    checks = [
        (f"{path}: {name}", normalize(clause) in paragraph, clause)
        for name, clause in REQUIRED_CLAUSES.items()
    ]
    checks.append(
        (
            f"{path}: old positive continuation example removed",
            "продолжаю Ф61 без вопросов" not in normalize(text),
            "legacy positive example remains",
        )
    )
    return checks


def check_generated_agents(root):
    # Bypass environment loading so --root remains authoritative even in a
    # different workspace or when the checkout contains .exocortex.env.
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
            cwd=root,
            env=env,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return ("AGENTS.md exactly matches canonical generation", False, str(error))
    return (
        "AGENTS.md exactly matches canonical generation",
        result.returncode == 0,
        (result.stdout + result.stderr).strip(),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="IWE root checkout")
    parser.add_argument("--template", required=True, type=Path, help="FMT checkout")
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    template = args.template.expanduser().resolve()
    checks = []
    for path, marker in (
        (root / "CLAUDE.md", "**A12 (БЛОКИРУЮЩЕЕ, все агенты)**"),
        (root / "AGENTS.md", "**A12 (БЛОКИРУЮЩЕЕ, все агенты)**"),
        (template / "memory/communication-style-base.md", "(A12)"),
    ):
        checks.extend(check_document(path, marker))
    checks.append(check_generated_agents(root))
    for name, passed, detail in checks:
        print(f"{'OK' if passed else 'FAIL'}: {name}")
        if not passed:
            print(f"  {detail}")
    passed = sum(check[1] for check in checks)
    print(f"Delivery checks: {passed}/{len(checks)} passed.")
    print("This checks instruction files only; it does not prove model behavior.")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
