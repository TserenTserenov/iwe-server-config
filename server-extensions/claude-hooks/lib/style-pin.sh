#!/usr/bin/env bash
# lib/style-pin.sh — style rules pinned per session for inject-communication-style.sh / inject-code-style.sh.
#
# WP-539 (peer-session 2026-11-03-12-wp539-sync-processes-audit, consensus with Kimi and Codex):
# the style hooks used to read PACK-rhetoric / PACK-digital-platform straight from the working
# trees. Now reader-copies-sync.py fast-forwards those trees every few minutes, so one session
# could see rules change between turns (or a half-moved tree). A session therefore reads a
# read-only snapshot of both packs at the SHAs it first saw, without reset/stash of the live
# copies and without a shared symlink. The pin is refreshed after STYLE_PIN_MAX_AGE_MIN
# (default 360) so a resumed multi-day session does not keep stale rules forever.
#
# Live dispatcher instead of a pin (caller's default): STYLE_PIN=0; uncommitted edits in either
# pack (an author is changing the rules -- they must see them at once); any build failure, which
# is remembered for STYLE_PIN_RETRY_MIN (default 10) so a broken build is not retried every turn.
#
# Snapshots are keyed by the SHA pair under .iwe-runtime/style-pins/ and shared by sessions;
# non-pack sources of the style compiler (DS-my-strategy, DS-Knowledge-Index-Tseren) stay live
# via per-snapshot links.

DISPATCHER_REL="PACK-rhetoric/pack/language-style/registry/dispatcher.py"
STYLE_PIN_LIVE_SOURCES=(DS-my-strategy DS-Knowledge-Index-Tseren)
STYLE_PIN_FAILED="none"

# _style_pin_build <root> <pin_dir> <rhetoric_sha> <platform_sha>: build the snapshot atomically.
_style_pin_build() {
  local root="$1" pin="$2" rh_sha="$3" dp_sha="$4" tmp live rel
  local -a dp_files=() sources=()
  tmp=$(mktemp -d "$(dirname "$pin")/.build.XXXXXX") || return 1
  mkdir -p "$tmp/PACK-rhetoric" "$tmp/PACK-digital-platform"
  if ! git -C "$root/PACK-rhetoric" archive "$rh_sha" pack/language-style | tar -x -C "$tmp/PACK-rhetoric"; then
    rm -rf "$tmp"; return 1
  fi
  for live in "${STYLE_PIN_LIVE_SOURCES[@]}"; do
    [ -e "$root/$live" ] && ln -s "$root/$live" "$tmp/$live"
  done
  # Every source the compiler names (its own content-sources.yaml) must exist in the pin.
  local listing
  # No mapfile: hooks may run under macOS /bin/bash 3.2.
  if ! listing=$(python3 - "$tmp/PACK-rhetoric/pack/language-style/registry/content-sources.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    for rel in (yaml.safe_load(f) or {}).values():
        print(rel)
PY
  ); then
    rm -rf "$tmp"; return 1
  fi
  while IFS= read -r rel; do [ -n "$rel" ] && sources+=("$rel"); done <<<"$listing"
  for rel in "${sources[@]}"; do
    case "$rel" in PACK-digital-platform/*) dp_files+=("${rel#PACK-digital-platform/}") ;; esac
  done
  if [ "${#dp_files[@]}" -gt 0 ] &&
    ! git -C "$root/PACK-digital-platform" archive "$dp_sha" -- "${dp_files[@]}" | tar -x -C "$tmp/PACK-digital-platform"; then
    rm -rf "$tmp"; return 1
  fi
  for rel in "${sources[@]}"; do
    # A source outside the archived trees and the live links would differ from the live run.
    [ -e "$tmp/$rel" ] || [ ! -e "$root/$rel" ] || { echo "style-pin: source not pinned: $rel" >&2; rm -rf "$tmp"; return 1; }
  done
  # `mv dir existing_dir` would nest tmp inside the winner of a concurrent build: never move onto it.
  if [ -e "$pin" ] || ! mv "$tmp" "$pin" 2>/dev/null; then
    rm -rf "$tmp"
  fi
  [ -d "$pin/$(basename "$tmp")" ] && rm -rf "${pin:?}/$(basename "$tmp")"  # lost the race inside the gap
  [ -f "$pin/$DISPATCHER_REL" ]
}

# _style_pin_dirty <root>: true when either pack has uncommitted edits to tracked files.
_style_pin_dirty() {
  local pack
  for pack in PACK-rhetoric PACK-digital-platform; do
    [ -n "$(git -C "$1/$pack" status --porcelain --untracked-files=no 2>/dev/null)" ] && return 0
  done
  return 1
}

# style_pin_dispatcher <root> <session_id>: print the pinned dispatcher path for this session;
# print nothing and return 1 when the caller should use the live dispatcher.
style_pin_dispatcher() {
  local root="$1" sid="$2" max_age="${STYLE_PIN_MAX_AGE_MIN:-360}" retry="${STYLE_PIN_RETRY_MIN:-10}"
  local state="$root/.claude/state/style-pin-$sid" pins="$root/.iwe-runtime/style-pins"
  local pin rh_sha dp_sha
  [ "${STYLE_PIN:-1}" != 0 ] || return 1
  if [ -f "$state" ]; then
    pin=$(cat "$state" 2>/dev/null)
    if [ "$pin" = "$STYLE_PIN_FAILED" ]; then
      [ -n "$(find "$state" -mmin +"$retry" 2>/dev/null)" ] || return 1
    elif [ -z "$(find "$state" -mmin +"$max_age" 2>/dev/null)" ] && [ -f "$pin/$DISPATCHER_REL" ]; then
      printf '%s\n' "$pin/$DISPATCHER_REL"
      return 0
    fi
  fi
  _style_pin_dirty "$root" && return 1
  mkdir -p "$pins" "$(dirname "$state")" || return 1
  rh_sha=$(git -C "$root/PACK-rhetoric" rev-parse --verify -q HEAD) &&
    dp_sha=$(git -C "$root/PACK-digital-platform" rev-parse --verify -q HEAD) || {
    printf '%s\n' "$STYLE_PIN_FAILED" > "$state"; return 1
  }
  pin="$pins/${rh_sha:0:12}-${dp_sha:0:12}"
  if [ ! -f "$pin/$DISPATCHER_REL" ] && ! _style_pin_build "$root" "$pin" "$rh_sha" "$dp_sha"; then
    echo "style-pin: snapshot build failed for $(basename "$pin"); live rules for ${retry} min" >&2
    printf '%s\n' "$STYLE_PIN_FAILED" > "$state"
    return 1
  fi
  touch "$pin"
  printf '%s\n' "$pin" > "$state"
  # Snapshots nobody used for a week are garbage; live sessions touch theirs on every refresh.
  find "$pins" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
  printf '%s\n' "$pin/$DISPATCHER_REL"
}
