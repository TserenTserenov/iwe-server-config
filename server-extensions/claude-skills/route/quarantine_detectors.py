"""Detector-core перенесён из guide-kit/structurer/quarantine.py (peer-session
2026-07-15-04, РП449 Ф4.2). Переносится только сам детектор (regex под форматы
вендоров + labeled high-entropy assignment + Luhn/IBAN) — без forced-flag/PII/
frontmatter-политики guide-kit, которой /route не пользуется (нет бизнес-политики
WP-483 в переносимой части). Синхронизация с оригиналом проверяется тестом
tests/test_quarantine_parity.py.
"""
from __future__ import annotations

import re

# Known vendor token formats — zero ambiguity, the shape alone is the signal.
VENDOR_SECRET_PATTERNS = [
    re.compile(r"AKIA[0-9A-Z]{16}"),                          # AWS access key
    re.compile(r"sk-ant-api\d{2}-[A-Za-z0-9_-]{30,}"),        # Anthropic
    re.compile(r"gh[poshru]_[A-Za-z0-9]{30,}"),               # GitHub
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),              # Slack
    re.compile(r"AIza[0-9A-Za-z_-]{35}"),                     # Google API key
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----"),
]

# Labeled high-entropy assignment — catches arbitrary third-party keys the vendor
# list above doesn't know about. The label anchors intent (this is a "secret",
# not just any long string); the length floor keeps placeholders like
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
    for pattern in VENDOR_SECRET_PATTERNS:
        if pattern.search(text):
            return "known-vendor-format"
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
