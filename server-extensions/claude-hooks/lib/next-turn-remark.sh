#!/usr/bin/env bash
# next-turn-remark.sh — deferred remarks from Stop hooks to the agent's next turn
# (WP-605, 25.11.2026, pilot's permission "переделай проверки при остановке").
#
# Why: a Stop hook that returns {"decision":"block"} after the answer is already
# shown makes the agent write a second visible message to the pilot, answering
# the hook. A remark that only corrects style does not need the current turn:
# it is stored here and the UserPromptSubmit hook (inject-communication-style.sh)
# hands it to the agent at the start of the next turn; the pilot never sees it.
# Guards that must keep the agent working (unfinished close, permission question
# instead of the action, an exact "no access" phrase) still block and do not use
# this channel.
#
# Storage: one file per conversation, $STATE_DIR/next-turn-remarks-<session_id>.
# One remark per line, each cut to NEXT_TURN_REMARK_MAX_CHARS characters, at most
# NEXT_TURN_REMARK_MAX_LINES lines kept (newest win): the whole file then fits the
# 7000-character hook output together with the main style line. The reader deletes
# the file, so a remark is delivered once. Remarks older than a day are dropped.
# Several Stop hooks append in parallel: appends of one short line are atomic, the
# file is rewritten only when it overflows (a rare, accepted race).

NEXT_TURN_REMARK_MAX_LINES=4
NEXT_TURN_REMARK_MAX_CHARS=1000

# $1 session id -> safe file-name part ("unknown" when nothing is left).
_next_turn_remark_sid() {
  local sid
  sid=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')
  printf '%s' "${sid:-unknown}"
}

# $1 state dir, $2 session id; prints the file path.
next_turn_remark_file() {
  printf '%s/next-turn-remarks-%s' "$1" "$(_next_turn_remark_sid "$2")"
}

# $1 state dir, $2 session id, $3 remark text (newlines are folded into spaces).
# Returns 0 when stored, 1 otherwise; never prints to stdout (Stop hooks must
# keep their stdout valid JSON).
next_turn_remark_add() {
  local file text tmp
  [ "$(_next_turn_remark_sid "$2")" = unknown ] && return 1
  file=$(next_turn_remark_file "$1" "$2")
  # Cut by characters, not bytes: Cyrillic is two bytes per character.
  text=$(printf '%s' "$3" | tr '\n' ' ' | python3 -c \
    'import sys; sys.stdout.write(sys.stdin.read()[:int(sys.argv[1])])' "$NEXT_TURN_REMARK_MAX_CHARS" 2>/dev/null) \
    || return 1
  [ -n "$text" ] || return 1
  mkdir -p "$1" 2>/dev/null || return 1
  printf '%s\n' "$text" >> "$file" 2>/dev/null || return 1
  if [ "$(wc -l < "$file")" -gt "$NEXT_TURN_REMARK_MAX_LINES" ]; then
    tmp="$file.tmp.$$"
    if tail -n "$NEXT_TURN_REMARK_MAX_LINES" "$file" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  return 0
}

# $1 state dir, $2 session id; prints the pending remarks (if fresh) and deletes
# the file. Prints nothing when there is no file or it is older than a day.
next_turn_remark_take() {
  local file
  file=$(next_turn_remark_file "$1" "$2")
  [ -f "$file" ] || return 0
  if [ -n "$(find "$file" -mmin -1440 2>/dev/null)" ]; then
    cat "$file" 2>/dev/null
  fi
  rm -f "$file"
}
