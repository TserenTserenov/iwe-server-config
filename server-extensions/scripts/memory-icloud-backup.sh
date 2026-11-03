#!/usr/bin/env bash
# memory-icloud-backup.sh — daily off-device copy of agent memory to iCloud Drive (Mac only).
#
# WP-539, pilot decision 03.11.2026 (peer-session 2026-11-03-12-wp539-sync-processes-audit):
# memory lives only on this Mac; the local bare repo .iwe-runtime/backups/memory.git sits on the
# same disk and protects nothing. Before this script the only off-device copy was the weekly
# IWE archive (backup-icloud.sh), i.e. up to 7 days of memory could be lost with the disk.
# Memory is NOT sent to GitHub: it holds personal data.
#
# Schedule: ~/Library/LaunchAgents/com.iwe.memory-icloud-backup.plist (daily). Keeps the newest
# MEMORY_BACKUP_KEEP archives (git history included, so every day is restorable).
set -euo pipefail

MEMORY_DIR="${MEMORY_DIR:-$HOME/.claude/projects/-Users-tserentserenov-IWE/memory}"
BACKUP_DIR="${MEMORY_BACKUP_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/IWE-backups/memory}"
KEEP="${MEMORY_BACKUP_KEEP:-14}"

log() { printf '[%s] [memory-icloud-backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

case "$KEEP" in '' | *[!0-9]*) log "FAIL: MEMORY_BACKUP_KEEP must be a positive integer, got '$KEEP'"; exit 1 ;; esac
[ "$KEEP" -ge 1 ] || { log "FAIL: MEMORY_BACKUP_KEEP must be >= 1"; exit 1; }

[ -d "$MEMORY_DIR" ] || { log "FAIL: memory directory not found: $MEMORY_DIR"; exit 1; }
# iCloud Drive not mounted -> fail loudly instead of silently writing to a local stub folder.
[ -d "$(dirname "$BACKUP_DIR")" ] || { log "FAIL: backup parent not found (iCloud Drive off?): $(dirname "$BACKUP_DIR")"; exit 1; }
mkdir -p "$BACKUP_DIR"

archive="$BACKUP_DIR/memory-$(date +%Y%m%d).tar.gz"
tmp="$archive.partial"
trap 'rm -f "$tmp"' EXIT
# Agents write memory all day: tar exit 1 ("file changed as we read it") still yields a usable
# archive, the listing check below decides. Exit >= 2 is a real failure.
tar_rc=0
tar -czf "$tmp" -C "$(dirname "$MEMORY_DIR")" "$(basename "$MEMORY_DIR")" || tar_rc=$?
[ "$tar_rc" -le 1 ] || { log "FAIL: tar exit $tar_rc"; exit 1; }
[ "$tar_rc" -eq 0 ] || log "WARN: files changed while archiving (tar exit 1), checking the archive"
tar -tzf "$tmp" >/dev/null  # an unreadable archive must not replace yesterday's good one
mv -f "$tmp" "$archive"
log "OK: $(basename "$archive") $(wc -c <"$archive" | tr -d ' ') bytes"

# Rotation: names sort by date; keep the newest $KEEP (BSD head has no negative -n).
old=$(ls -1 "$BACKUP_DIR"/memory-*.tar.gz 2>/dev/null | sort -r | tail -n "+$((KEEP + 1))" || true)
if [ -n "$old" ]; then
  while IFS= read -r f; do rm -f "$f" && log "rotated out: $(basename "$f")"; done <<<"$old"
fi
