#!/usr/bin/env bash
# with-aist-env.sh — run a command with ~/.config/aist/env exported.
#
# The sanctioned path that secret-leak-block.sh points to: the credential file
# is sourced HERE, inside the wrapper, so its path never appears on the agent's
# Bash command line (which is what the guard scans and denies). Before this
# script existed the guard's message referred to a "штатный wrapper" that did
# not exist — every script re-implemented `set -a; source ...` on its own, and
# an agent that hit the guard had no working pattern to switch to (WP-544,
# peer-session 2026-09-02-22, fifth recurrence of the "no access" claim).
#
# Usage:
#   scripts/with-aist-env.sh <command> [args...]
#   scripts/with-aist-env.sh python3 probe.py        # probe.py reads os.environ
#
# Read the variables INSIDE the program you run (os.environ, $VAR in a script
# file). Do not try to pass "$NEON_REFERENCE_URL" as an argument: with double
# quotes the parent shell expands it before this wrapper has loaded the file
# (empty, or worse — into argv); with single quotes nothing expands at all,
# because exec does not run a shell (Codex, review 02.09).
#
# Leak model (Codex, review 02.09): the child gets EVERY exported secret. This
# wrapper is not a leak *preventer* — it only keeps the file path off the
# agent's command line so the guard can allow the call. Never run through it
# anything that prints its environment (env, printenv, set, debug dumps).
#
# Env:
#   AIST_ENV_FILE  — override the env file location (default ~/.config/aist/env).
#   AIST_ENV_ALLOW — optional comma-separated allowlist of variable NAMES to
#                    export (e.g. "NEON_REFERENCE_URL,NEON_LEARNING_URL"). When
#                    set, everything else from the file stays out of the child's
#                    environment — the narrow-blast-radius mode Codex asked for
#                    (review 02.09): give a probe the one URL it needs, not the
#                    whole key ring. Unknown names are a hard error (67), not a
#                    silent no-op — a typo must not become "ran without creds".
#
# Exit codes: 64 usage; 66 env file missing; 67 allowlisted name absent in file;
#             otherwise the command's own.
set -euo pipefail

ENV_FILE="${AIST_ENV_FILE:-$HOME/.config/aist/env}"
ALLOW="${AIST_ENV_ALLOW:-}"

if [ "$#" -lt 1 ]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  exit 64
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "with-aist-env: env file not found: $ENV_FILE" >&2
  exit 66
fi

if [ -z "$ALLOW" ]; then
  # Default: export everything the file defines.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  # Allowlist. The file itself may say `export VAR=...` (ours does), so merely
  # sourcing without set -a is not enough — found by the smoke test 02.09: the
  # non-listed URL was still visible to the child. Source it, then unset every
  # name the file defines that is not on the list; export the listed ones.
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  IFS=',' read -r -a names <<< "$ALLOW"
  keep=" "
  for name in "${names[@]}"; do
    name="${name// /}"
    [ -n "$name" ] || continue
    if [ -z "${!name+x}" ]; then
      echo "with-aist-env: allowlisted variable not defined in env file: $name" >&2
      exit 67
    fi
    export "${name?}"
    keep="$keep$name "
  done
  while IFS= read -r defined; do
    case "$keep" in
      *" $defined "*) ;;
      *) unset "$defined" ;;
    esac
  done < <(sed -nE 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$ENV_FILE")
fi

# exec, not "$@": replace this shell so the target gets the caller's signals
# and exit code directly, with no extra wrapper process left behind. exec does
# no shell evaluation of its arguments (Kimi/Codex, review 02.09).
exec "$@"
