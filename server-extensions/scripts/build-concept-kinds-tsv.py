#!/usr/bin/env python3
"""Build the detector's copy of the concept-kind registry (РП-388 Ф21).

Source of truth: PACK-digital-platform/pack/digital-platform/concept-kinds-registry.yaml.
Copy read by .claude/hooks/response-clarity-hook.sh (rule A14):
.claude/hooks/lib/concept-kinds.tsv, one `kind<TAB>stem` line per stem.

Usage:
  build-concept-kinds-tsv.py            write the copy
  build-concept-kinds-tsv.py --check    exit 1 when the copy differs from the registry

Env: CONCEPT_KINDS_REGISTRY overrides the registry path, CONCEPT_KINDS_TSV the copy path.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = Path(
    os.environ.get(
        "CONCEPT_KINDS_REGISTRY",
        ROOT / "PACK-digital-platform/pack/digital-platform/concept-kinds-registry.yaml",
    )
)
TSV = Path(os.environ.get("CONCEPT_KINDS_TSV", ROOT / ".claude/hooks/lib/concept-kinds.tsv"))

# A stem goes straight into a Perl regex: letters, digits, space and a few regex marks only.
STEM_RE = re.compile(r"^[а-яёa-z0-9 \[\]()?|\-!+]+$")
STATUSES = {"pilot", "pack", "fpf", "draft"}


def load_registry() -> dict:
    try:
        data = yaml.safe_load(REGISTRY.read_text(encoding="utf-8"))
    except yaml.YAMLError as err:
        raise SystemExit(f"{REGISTRY}: not valid YAML (quote regex stems that hold [ ] ? !):\n{err}")
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise SystemExit(f"{REGISTRY}: schema_version must be 1")
    return data


def validate(data: dict) -> list[tuple[str, str]]:
    """Return (kind, stem) rows; raise SystemExit on the first broken entry."""
    kind_ids = [k["id"] for k in data["kinds"]]
    if len(set(kind_ids)) != len(kind_ids):
        raise SystemExit("duplicate kind id in kinds")
    rows: list[tuple[str, str]] = []
    seen: dict[str, str] = {}
    for term in data["terms"]:
        name = term.get("term", "?")
        if term.get("kind") not in kind_ids:
            raise SystemExit(f"term {name!r}: unknown kind {term.get('kind')!r}")
        if term.get("status") not in STATUSES:
            raise SystemExit(f"term {name!r}: status must be one of {sorted(STATUSES)}")
        if not term.get("basis"):
            raise SystemExit(f"term {name!r}: basis is required (a word alone is not a test)")
        for stem in term.get("stems") or []:
            if not STEM_RE.match(stem):
                raise SystemExit(f"term {name!r}: stem {stem!r} has characters outside the allowed set")
            if stem in seen and seen[stem] != term["kind"]:
                raise SystemExit(f"stem {stem!r} is in kinds {seen[stem]!r} and {term['kind']!r}")
            seen[stem] = term["kind"]
            rows.append((term["kind"], stem))
    return rows


def render(rows: list[tuple[str, str]]) -> str:
    header = (
        "# GENERATED from PACK-digital-platform concept-kinds-registry.yaml by "
        "scripts/build-concept-kinds-tsv.py -- do not edit by hand.\n"
        "# kind<TAB>stem; the hook adds a left word boundary to every stem.\n"
    )
    return header + "".join(f"{kind}\t{stem}\n" for kind, stem in rows)


def main() -> int:
    check = "--check" in sys.argv[1:]
    text = render(validate(load_registry()))
    if check:
        current = TSV.read_text(encoding="utf-8") if TSV.exists() else ""
        if current != text:
            print(f"{TSV} is out of date with {REGISTRY}; run {Path(__file__).name}", file=sys.stderr)
            return 1
        return 0
    TSV.parent.mkdir(parents=True, exist_ok=True)
    TSV.write_text(text, encoding="utf-8")
    print(f"wrote {TSV} ({text.count(chr(10)) - 2} stems)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
