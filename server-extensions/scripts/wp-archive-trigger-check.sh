#!/usr/bin/env bash
# routing: helper  called-by=protocol-close(step 5c)  deterministic=true
# wp-archive-trigger-check.sh -- mechanical licence check for protocol-close step
# 5c (auto-archival of the closed phases of a WP card into WP-N-archive.md,
# RP-541 Ф5 -> WP-561 Ф24). It replaced the closing agent's by-eye decision made
# by re-reading the frontmatter every time -- WP-561 2026-09-03-19 (Codex,
# placement-reviewer): make the size check "a separate deterministic reflex
# step", done without changing the quick-close.yaml graph (agreed boundary with
# check-wp-transfer-completeness.sh: that one archives a WHOLE finished WP, this
# one handles what accumulates inside an active card).
#
# The licence no longer depends on card age or size: since WP-561 Ф94 part 3
# (pilot decision 28.11.2026) every card is licensed unless the pilot declined
# archival less than 14 days ago; the archiver's own vetoes decide per phase.
#
# Usage:
#   wp-archive-trigger-check.sh <WP_NUM> [IWE_ROOT]
# Stdout (always, exit 0 -- a report, not a gate):
#   age_days=<N|unknown>
#   line_count=<N>
#   archive_declined_recent=<true|false>   archive_declined less than 14 days old
#   over_threshold=<true|false>   informational, does not gate: created more than
#                14 days ago AND more than 400 lines AND no fresh decline
#   auto_archive=<licensed|declined>   (WP-561 Ф24: licensed = protocol §5c
#                auto-archival applies; declined = a fresh archive_declined wins;
#                n/a, "under threshold", is no longer emitted since Ф94 part 3)
# exit 1 only on a usage error or a missing card.
#
# Compatibility: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

WP_NUM="${1:-}"
IWE="${2:-${IWE_ROOT:-$HOME/IWE}}"
# Governance repo: an explicit $IWE_GOVERNANCE_REPO always wins (never replaced
# by a guess); only when it is unset, the first known name that holds
# docs/WP-REGISTRY.md (same candidates as .claude/scripts/wp-sync-bundle.sh).
GOV_REPO="${IWE_GOVERNANCE_REPO:-}"
if [[ -z "$GOV_REPO" ]]; then
  for cand in DS-my-strategy DS-strategy strategy; do
    if [[ -f "$IWE/$cand/docs/WP-REGISTRY.md" ]]; then GOV_REPO="$cand"; break; fi
  done
fi
INBOX="$IWE/$GOV_REPO/inbox"

# The two thresholds feed only the informational over_threshold; the licence
# depends on the decline cooldown alone.
AGE_THRESHOLD_DAYS=14
LINE_THRESHOLD=400
DECLINE_COOLDOWN_DAYS=14

if [[ -z "$WP_NUM" ]]; then
  echo "Использование: $0 <WP_NUM> [IWE_ROOT]" >&2
  exit 1
fi
WP_NUM="${WP_NUM#WP-}"
WP_NUM="${WP_NUM#wp-}"

# Та же WP-434 папочная конвенция, что archive-done-wp.sh/check-wp-transfer-completeness.sh
WP_FILE="$INBOX/WP-${WP_NUM}/WP-${WP_NUM}.md"
if [[ ! -f "$WP_FILE" ]]; then
  echo "[ERROR] $WP_FILE не найден" >&2
  exit 1
fi

extract_fm_field() {
  local field="$1"
  awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$WP_FILE" 2>/dev/null \
    | grep -E "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"'
}

created="$(extract_fm_field created)"
archive_declined="$(extract_fm_field archive_declined)"

age_days="unknown"
if [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  today_epoch=$(date -u +%s)
  created_epoch=$(date -u -j -f "%Y-%m-%d" "$created" +%s 2>/dev/null \
    || date -u -d "$created" +%s 2>/dev/null || echo "")
  if [[ -n "$created_epoch" ]]; then
    age_days=$(( (today_epoch - created_epoch) / 86400 ))
  fi
fi

line_count=$(wc -l < "$WP_FILE" | tr -d ' ')

# A decline stays fresh for DECLINE_COOLDOWN_DAYS (same date formula as age_days).
archive_declined_recent="false"
if [[ "$archive_declined" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  today_epoch=$(date -u +%s)
  declined_epoch=$(date -u -j -f "%Y-%m-%d" "$archive_declined" +%s 2>/dev/null \
    || date -u -d "$archive_declined" +%s 2>/dev/null || echo "")
  if [[ -n "$declined_epoch" ]]; then
    declined_age_days=$(( (today_epoch - declined_epoch) / 86400 ))
    [[ "$declined_age_days" -lt "$DECLINE_COOLDOWN_DAYS" ]] && archive_declined_recent="true"
  fi
fi

over_threshold="false"
if [[ "$age_days" != "unknown" ]] \
  && [[ "$age_days" -gt "$AGE_THRESHOLD_DAYS" ]] \
  && [[ "$line_count" -gt "$LINE_THRESHOLD" ]] \
  && [[ "$archive_declined_recent" == "false" ]]; then
  over_threshold="true"
fi

# WP-561 Ф24 (peer-session 2026-09-27-09, Kimi's condition, Codex's shape):
# the closing agent must not guess whether archival is allowed. The licence is
# the protocol version (protocol-close.md §5c, standing pilot directive of
# 27.09.2026) plus the ABSENCE of a fresh archive_declined -- a fresh decline
# always wins. The per-card `auto_archive_policy:` field is an audit trail of
# an already executed decision, never the licence itself (otherwise the first
# run could never happen). Readers: protocol-close.md step 5c and the quick-close
# handler wp-phase-archive.sh (DS-my-strategy), which runs
# scripts/wp-archive-closed-phases.py --apply only on `licensed`.
# WP-561 Ф94 part 3, pilot decision 28.11.2026: over_threshold no longer gates the
# licence -- on 21-28.11 the threshold skipped archival on 25 closes across 16 WPs.
auto_archive="licensed"
if [[ "$archive_declined_recent" == "true" ]]; then
  auto_archive="declined"
fi

echo "age_days=${age_days}"
echo "line_count=${line_count}"
echo "archive_declined_recent=${archive_declined_recent}"
echo "over_threshold=${over_threshold}"
echo "auto_archive=${auto_archive}"
