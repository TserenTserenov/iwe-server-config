#!/usr/bin/env bash
# Read-only view of sessions whose authoritative semaphore is still .open.
# The append-only runtime journal is historical; closing a day must not prune it.
# This command writes the current view to stdout and never touches the shared
# governance checkout. Callers may save stdout in their own isolated worktree.
set -euo pipefail

[ "$#" -eq 0 ] || { echo 'open-log-snapshot: no arguments expected' >&2; exit 2; }
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"

python3 - "$SESSION_DIR" <<'PY'
import datetime
import glob
import os
import re
import sys


def field(record, name):
    values = [line[len(name) + 2:] for line in record.splitlines()
              if line.startswith(name + ': ')]
    if len(values) != 1:
        raise ValueError(f'{name}: expected exactly one value')
    value = values[0]
    if value == "''":
        value = ''
    return value


directory = sys.argv[1]
if not os.path.isdir(directory):
    raise SystemExit(0)

rows = []
for path in glob.glob(os.path.join(directory, '*.open')):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    except FileNotFoundError:
        continue  # close renamed this semaphore during the snapshot
    try:
        with os.fdopen(fd, encoding='utf-8') as source:
            record = source.read()
        agent = field(record, 'agent')
        if any(line.startswith('housekeeping: ') for line in record.splitlines()):
            reason = field(record, 'housekeeping')
            if os.path.basename(path) != f'{agent}-housekeeping-{reason}.open':
                raise ValueError('invalid housekeeping identity')
            continue  # internal maintenance is not a user work session
        session_id = field(record, 'session_id')
        wp = field(record, 'wp')
        task = field(record, 'task').replace('|', '¦')
        opened = datetime.datetime.fromisoformat(field(record, 'opened_at').replace('Z', '+00:00'))
        if not agent or not session_id or not re.fullmatch(r'[A-Za-z0-9._-]+', session_id):
            raise ValueError('invalid session identity')
        if not (re.fullmatch(r'WP-[1-9][0-9]*', wp) or wp in {'unknown', 'day-close'}) \
                or opened.tzinfo is None:
            raise ValueError('invalid work package or timestamp')
        if os.path.basename(path) != f'{agent}-{session_id}.open':
            raise ValueError('semaphore name differs from identity')
        # The ORZ filename and the legacy journal use the host's local date.
        opened = opened.astimezone()
        rows.append((opened, session_id,
                     f'{opened:%Y-%m-%d %H:%M} | {wp} | {agent} | {task} | session_id={session_id}'))
    except (OSError, UnicodeError, ValueError) as error:
        print(f'open-log-snapshot: invalid open semaphore {path}: {error}', file=sys.stderr)
        raise SystemExit(1)

for _opened, _session_id, row in sorted(rows):
    print(row)
PY
