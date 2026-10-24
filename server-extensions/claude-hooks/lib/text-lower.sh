# text-lower.sh -- sourced by hooks; lower_text lowercases stdin to stdout, line by line.
# GNU tr folds only single-byte characters, so on Linux `tr '[:upper:]' '[:lower:]'`
# leaves Cyrillic as is ("Закрывай" stays capitalised) while BSD tr on macOS folds
# it: the same hook matched a phrase on the Mac and missed it on the server
# (WP-568, 24.10). Python decodes UTF-8 itself and does not depend on the locale;
# invalid bytes become U+FFFD (hooks only match words in this text).
# Callers source it as "${BASH_SOURCE[0]%/*}/lib/text-lower.sh": settings.json runs
# hooks by absolute path, so BASH_SOURCE always carries the directory.
lower_text() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys
for line in sys.stdin.buffer:
    sys.stdout.buffer.write(line.decode("utf-8", "replace").lower().encode("utf-8"))'
  else
    tr '[:upper:]' '[:lower:]'
  fi
}
