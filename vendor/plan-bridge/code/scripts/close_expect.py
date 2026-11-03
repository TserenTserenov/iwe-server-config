"""Shared close_check `expect` value matching (WP-484 F250).

One function for the Stop-hook checker (close_obligation.py) and the runner's AI-step
intake (process-runner.py), so both accept the same values.
"""
from __future__ import annotations


def expect_value_matches(actual, expected) -> bool:
    """String expectations are tokens, not their case (LLM steps answer PASS or pass);
    non-strings compare strictly. A list in `expected` means "any of"."""
    if isinstance(expected, list):
        return any(expect_value_matches(actual, option) for option in expected)
    if isinstance(actual, str) and isinstance(expected, str):
        return actual.strip().lower() == expected.strip().lower()
    return actual == expected
