"""Route quarantine detectors.

Vendor-token formats come from the canonical hook helper shared with runtime
guards. This module keeps only route-specific contextual/entropy heuristics and
payment checks. The helper returns identifiers and counts, never matched text;
an unavailable or malformed helper fails closed into quarantine.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

_CLAUDE_LAYOUT_ROOT = Path(__file__).resolve().parents[2]
_CANONICAL_SECRET_HELPER_CANDIDATES = (
    _CLAUDE_LAYOUT_ROOT / "hooks" / "secret-bypass-lib.sh",
    _CLAUDE_LAYOUT_ROOT / "claude-hooks" / "secret-bypass-lib.sh",
)
_CANONICAL_SECRET_HELPER = next(
    (
        candidate
        for candidate in _CANONICAL_SECRET_HELPER_CANDIDATES
        if candidate.is_file()
    ),
    _CANONICAL_SECRET_HELPER_CANDIDATES[0],
)
_BASH = Path("/bin/bash")
_CANONICAL_DETECTOR_UNAVAILABLE = "canonical-detector-unavailable"
_CANONICAL_DETECTED = "known-vendor-format"
_SAFE_PATTERN_ID_RE = re.compile(r"[a-z0-9-]{1,64}")


def _canonical_secret_match(text: str) -> bool | None:
    """Return match state without returning or logging matched source text."""
    if not isinstance(text, str):
        return None
    if not _BASH.is_file() or not _CANONICAL_SECRET_HELPER.is_file():
        return None
    try:
        completed = subprocess.run(
            [
                str(_BASH),
                "--noprofile",
                "--norc",
                "-c",
                'source "$1" >/dev/null 2>&1 && '
                "declare -F secret_pattern_process >/dev/null && "
                "secret_pattern_process detect-text",
                "route-quarantine",
                str(_CANONICAL_SECRET_HELPER),
            ],
            input=text,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None
    if completed.returncode != 0 or len(completed.stdout) > 1_000_000:
        return None
    try:
        result = json.loads(completed.stdout)
        if not isinstance(result, dict) or set(result) != {
            "pattern_ids",
            "match_count",
            "patterns",
        }:
            return None
        match_count = result["match_count"]
        pattern_ids = result["pattern_ids"]
        patterns = result["patterns"]
        if type(match_count) is not int or match_count < 0:
            return None
        if not isinstance(pattern_ids, list) or not all(
            isinstance(pattern_id, str) and _SAFE_PATTERN_ID_RE.fullmatch(pattern_id)
            for pattern_id in pattern_ids
        ):
            return None
        if not isinstance(patterns, list):
            return None
        detail_ids = []
        detail_count = 0
        for detail in patterns:
            if not isinstance(detail, dict) or set(detail) != {
                "pattern_id",
                "count",
                "lines",
            }:
                return None
            if detail["pattern_id"] not in pattern_ids:
                return None
            if type(detail["count"]) is not int or detail["count"] <= 0:
                return None
            if not isinstance(detail["lines"], list) or not all(
                type(line) is int and line > 0 for line in detail["lines"]
            ):
                return None
            detail_ids.append(detail["pattern_id"])
            detail_count += detail["count"]
        if detail_ids != pattern_ids or detail_count != match_count:
            return None
    except (TypeError, ValueError):
        return None
    return match_count > 0

# Labeled high-entropy assignment — catches arbitrary third-party keys the
# canonical corpus doesn't know about. The label anchors intent (this is a
# "secret", not just any long string); the length floor keeps placeholders like
# "password: changeme" out.
LABELED_SECRET_RE = re.compile(
    r"\b(?:api[_-]?key|secret|token|access[_-]?key)\b\s*[:=]\s*['\"]?([A-Za-z0-9_\-/+=]{20,})['\"]?",
    re.IGNORECASE,
)
PLACEHOLDER_VALUES = frozenset({
    "changeme", "your_api_key_here", "your-api-key-here", "insert_key_here",
    "xxxxxxxxxxxxxxxxxxxx", "redacted", "example_key_do_not_use",
})


def _looks_like_secret_value(value: str) -> bool:
    """Length alone doesn't distinguish a real token from an ordinary long path or
    dashed phrase. Real vendor tokens mix case and digits; prose and file paths after
    a "key:"/"token:" label typically don't — requiring both is a cheap, explainable
    filter, not a claim of true entropy measurement."""
    return any(c.isdigit() for c in value) and any(c.isupper() for c in value)


_CARD_RE = re.compile(r"\b(?:\d[ -]?){13,19}\b")
_IBAN_RE = re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b")


def _luhn_valid(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def _iban_valid(candidate: str) -> bool:
    """ISO 7064 mod-97-10 checksum — rejects the vast majority of alnum strings
    that happen to start with 2 letters + 2 digits (e.g. hashes, IDs)."""
    rearranged = candidate[4:] + candidate[:4]
    digits = "".join(str(int(c, 36)) for c in rearranged)
    return int(digits) % 97 == 1


def detect_secret(text: str) -> str | None:
    canonical_match = _canonical_secret_match(text)
    if canonical_match is None:
        return _CANONICAL_DETECTOR_UNAVAILABLE
    if canonical_match:
        return _CANONICAL_DETECTED
    for match in LABELED_SECRET_RE.finditer(text):
        value = match.group(1)
        if value.lower() not in PLACEHOLDER_VALUES and _looks_like_secret_value(value):
            return "labeled-high-entropy-assignment"
    return None


def detect_payment(text: str) -> str | None:
    for match in _CARD_RE.finditer(text):
        digits = match.group(0).replace(" ", "").replace("-", "")
        if 13 <= len(digits) <= 19 and _luhn_valid(digits):
            return "luhn-valid-card-number"
    for match in _IBAN_RE.finditer(text):
        if _iban_valid(match.group(0)):
            return "iban-checksum"
    return None
