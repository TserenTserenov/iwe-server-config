#!/bin/bash
# install-ledger-merge-driver.sh -- WP-484 F157; the captures driver was added by WP-5 F60.
#
# Installs the git merge drivers of this repository into a clone. .gitattributes maps files to
# them; a driver itself is per-clone git config, which git does not version, so every clone (Mac,
# tsekh-1, the publisher's own copy) must run this once:
#   ledger-events    machine/ledger/**/*.yaml        event-level merge of the ledger files
#   captures-blocks  inbox/captures/YYYY-MM.md       block-level merge of the monthly capture feeds
#                    (scripts/lib/captures-block-merge.py; both extractor hosts append to the same file)
#
# A clone without a driver falls back to git's text merge: a visible conflict, never the silent
# interleaving the old line-wise `merge=union` produced.
#
# What the installer writes per driver, all in the clone's COMMON git dir (shared by every worktree):
#   <name>-merge-driver.py  a copy of the driver source, so it works for any commit that is checked
#                           out (an old commit, a temporary worktree, a checkout that is behind origin);
#   config merge.<name>.*   points at that copy;
#   info/attributes         the same attribute line as .gitattributes. info/attributes wins over the
#                           tracked file, so a clone or worktree that still has an old .gitattributes
#                           is protected too.
# Each copy is versioned (MERGE_DRIVER_VERSION): the installer never replaces it with an older one,
# so a stale worktree that shares the common dir cannot downgrade the driver, and `--check` passes
# when the installed version is at least this source's. Bump the constant on every driver change.
#
# The ledger driver is required: its failure is this script's failure (ledger-publish.sh stops on it).
# The captures driver is best effort: a failure only warns, so it can never block a ledger write, and a
# checkout whose scripts/lib has no captures driver source simply does not manage it.
#
# Usage:
#   install-ledger-merge-driver.sh [REPO_PATH]              install or refresh (idempotent)
#   install-ledger-merge-driver.sh --check [REPO_PATH]      exit 0 only if installed and current
#   install-ledger-merge-driver.sh --uninstall [REPO_PATH]  remove config, info/attributes lines and copies
#                                                           (rollback: also switch .gitattributes to
#                                                           `merge=text`, never back to `merge=union`)
set -euo pipefail

MODE=install
case "${1:-}" in
  --check) MODE=check; shift ;;
  --uninstall) MODE=uninstall; shift ;;
esac
REPO="${1:-$PWD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }

# Refuse to guess: an empty answer (a bare or odd repo, a wrapped git) once made this resolve to the
# repository directory itself and litter its working tree.
RAW_COMMON="$(cd "$REPO" && git rev-parse --git-common-dir 2>/dev/null || true)"
[[ -n "$RAW_COMMON" ]] || { echo "cannot resolve the git common dir of $REPO" >&2; exit 1; }
COMMON_DIR="$(cd "$REPO" && cd "$RAW_COMMON" && pwd)"
[[ -f "$COMMON_DIR/HEAD" && -d "$COMMON_DIR/objects" ]] || { echo "not a git directory: $COMMON_DIR" >&2; exit 1; }
ATTRIBUTES="$COMMON_DIR/info/attributes"

# Read the constant with sed, not python: this runs on every ledger write (ledger-append.sh).
# A missing copy, or one that predates the constant, counts as version 0.
version_of() { { sed -n 's/^MERGE_DRIVER_VERSION = \([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null || true; } | head -1; }

# select_driver NAME: load one driver's description into the D_* variables.
select_driver() {
  D_NAME="$1"
  case "$1" in
    ledger-events)
      D_SOURCE="$SCRIPT_DIR/lib/ledger-event-diff.py"
      D_LINE='machine/ledger/**/*.yaml merge=ledger-events'
      D_MARK='# WP-484 F157: event-level merge of ledger files (install-ledger-merge-driver.sh)'
      D_TITLE='event-level merge of ledger files (WP-484 F157)'
      ;;
    captures-blocks)
      D_SOURCE="$SCRIPT_DIR/lib/captures-block-merge.py"
      D_LINE='inbox/captures/[0-9][0-9][0-9][0-9]-[0-9][0-9].md merge=captures-blocks'
      D_MARK='# WP-5 F60: block-level merge of the monthly capture feeds (install-ledger-merge-driver.sh)'
      D_TITLE='block-level merge of the monthly capture feeds (WP-5 F60)'
      ;;
  esac
  D_TARGET="$COMMON_DIR/$1-merge-driver.py"
  D_WANT="python3 \"$D_TARGET\" --merge-driver %O %A %B"
  D_SOURCE_VERSION="$(version_of "$D_SOURCE")"; D_SOURCE_VERSION="${D_SOURCE_VERSION:-0}"
  D_INSTALLED_VERSION="$(version_of "$D_TARGET")"; D_INSTALLED_VERSION="${D_INSTALLED_VERSION:-0}"
}

uninstall_driver() {
  git -C "$REPO" config --remove-section "merge.$D_NAME" 2>/dev/null || true
  if [[ -f "$ATTRIBUTES" ]]; then
    grep -vxF -e "$D_LINE" -e "$D_MARK" "$ATTRIBUTES" > "$ATTRIBUTES.tmp" || true
    mv -f "$ATTRIBUTES.tmp" "$ATTRIBUTES"
  fi
  rm -f "$D_TARGET"
  echo "uninstalled: $D_NAME merge driver for $REPO"
}

check_driver() {
  local have_driver
  have_driver="$(git -C "$REPO" config --get "merge.$D_NAME.driver" || true)"
  if [[ "$have_driver" != "$D_WANT" ]]; then
    echo "$D_NAME merge driver is not configured for $REPO" >&2
    return 1
  fi
  if ! grep -qxF "$D_LINE" "$ATTRIBUTES" 2>/dev/null; then
    echo "$D_NAME attribute is missing from $ATTRIBUTES" >&2
    return 1
  fi
  if [[ "$D_INSTALLED_VERSION" -lt "$D_SOURCE_VERSION" ]]; then
    echo "$D_NAME merge driver copy is missing or stale (installed v$D_INSTALLED_VERSION, need v$D_SOURCE_VERSION): $D_TARGET" >&2
    return 1
  fi
  echo "ok: $D_NAME merge driver installed and current (v$D_INSTALLED_VERSION, $D_TARGET)"
}

# Every step ends in `|| return 1`: the captures call site runs this inside `||`, where `set -e` is off,
# and a failed copy must not be followed by a config line that points at the missing copy. The `driver`
# line goes before `name`: a section with a name and no command line makes git fail every merge of the
# file with a fatal error (exit 128), while a driver without a name merges fine.
install_driver() {
  if [[ "$D_INSTALLED_VERSION" -le "$D_SOURCE_VERSION" ]]; then
    # atomic: a merge may run right now
    cp "$D_SOURCE" "$D_TARGET.tmp.$$" && mv -f "$D_TARGET.tmp.$$" "$D_TARGET" || return 1
  fi
  git -C "$REPO" config "merge.$D_NAME.driver" "$D_WANT" || return 1
  git -C "$REPO" config "merge.$D_NAME.name" "$D_TITLE" || return 1
  mkdir -p "$COMMON_DIR/info" || return 1
  if ! grep -qxF "$D_LINE" "$ATTRIBUTES" 2>/dev/null; then
    printf '%s\n' "$D_MARK" "$D_LINE" >> "$ATTRIBUTES" || return 1
  fi
  echo "installed: $D_NAME merge driver for $REPO (v$(version_of "$D_TARGET"), $D_TARGET)"
}

if [[ "$MODE" == "uninstall" ]]; then
  select_driver captures-blocks; uninstall_driver
  select_driver ledger-events; uninstall_driver
  exit 0
fi

select_driver ledger-events
[[ -f "$D_SOURCE" ]] || { echo "missing driver source: $D_SOURCE" >&2; exit 1; }
CAPTURES_SOURCE="$SCRIPT_DIR/lib/captures-block-merge.py"

if [[ "$MODE" == "check" ]]; then
  STATUS=0
  check_driver || STATUS=1
  if [[ -f "$CAPTURES_SOURCE" ]]; then
    select_driver captures-blocks
    check_driver || STATUS=1
  fi
  exit "$STATUS"
fi

# Best effort and first, so a ledger-side failure below (no PyYAML) cannot keep it from being installed.
if [[ -f "$CAPTURES_SOURCE" ]]; then
  select_driver captures-blocks
  install_driver || echo "WARN: captures-blocks merge driver could not be installed for $REPO" >&2
fi

python3 -c 'import yaml' 2>/dev/null || { echo "python3 with PyYAML is required" >&2; exit 1; }
select_driver ledger-events
install_driver
