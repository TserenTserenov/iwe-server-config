#!/bin/bash
# iwe-secret-read — point-query reader for /etc/iwe/env (WP-544 D27, 2026-09-01)
#
# The only sanctioned way to read a value out of /etc/iwe/env once the
# sudoers drop-in in this directory denies direct cat/less/head/tail/cp/scp
# on that file. Prints exactly one value, never the whole file.
#
# Usage: iwe-secret-read --name VARNAME
set -euo pipefail

SECRET_FILE="/etc/iwe/env"
NAME_RE='^[A-Z][A-Z0-9_]{0,63}$'

usage() {
  printf 'usage: iwe-secret-read --name VARNAME\n' >&2
  exit 2
}

[ "${1:-}" = "--name" ] || usage
name="${2:-}"
[ $# -eq 2 ] || usage

# Reject anything that is not a plain uppercase identifier before it ever
# reaches awk — wildcards/globs here would turn this back into a bulk dump.
[[ "$name" =~ $NAME_RE ]] || {
  printf 'iwe-secret-read: invalid variable name\n' >&2
  exit 2
}

[ -r "$SECRET_FILE" ] || {
  printf 'iwe-secret-read: cannot read %s\n' "$SECRET_FILE" >&2
  exit 1
}

# Parsed as data (awk field split), never sourced/eval'd — a malformed or
# hostile line in the file cannot execute as shell.
value=$(awk -F'=' -v key="$name" '
  $1 == key { sub(/^[^=]*=/, ""); print; found=1; exit }
  END { if (!found) exit 1 }
' "$SECRET_FILE") || {
  printf 'iwe-secret-read: %s not found\n' "$name" >&2
  exit 1
}

printf '%s\n' "$value"
