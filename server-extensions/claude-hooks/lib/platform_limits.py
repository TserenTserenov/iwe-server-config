"""Measured limits of the Claude Code harness that IWE hooks must respect.

Single owner of these numbers (OwnerIntegrity): hooks and audit scripts import
them from here instead of repeating literals.

PLATFORM_HOOK_CONTEXT_CHAR_LIMIT — the harness keeps a hook's additionalContext
inline only up to this many characters; above it the text is written to
tool-results/hook-*-additionalContext.txt and the model sees a ~2 KB preview.
Measured 2026-11-05 on claude 2.1.318 (WP-7 F299, peer session
2026-11-05-05-wp7-system-prompt-budget): 10000 chars inline, 10001 persisted,
same boundary for Cyrillic and Latin text (characters, not bytes); the limit
applies per hook, two hooks of 6000 chars in one turn both stayed inline.
Re-measure after a Claude Code upgrade if the audit starts reporting
persisted hook output.
"""

PLATFORM_HOOK_CONTEXT_CHAR_LIMIT = 10000
HARD_CAP_RATIO = 0.7
HOOK_CONTEXT_HARD_CAP = int(PLATFORM_HOOK_CONTEXT_CHAR_LIMIT * HARD_CAP_RATIO)
