#!/usr/bin/env bash
# Зашифровать Google Calendar credentials через sops-nix.
# Запускать один раз после получения refresh_token.
# Связь: DOC3 (WP-7), docs/setup-google-calendar.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Вставь значения из Google Cloud Console / OAuth-flow:
CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN:-}"

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" || -z "$REFRESH_TOKEN" ]]; then
  echo "Использование:"
  echo "  GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... GOOGLE_REFRESH_TOKEN=... bash $0"
  exit 1
fi

PLAIN=$(mktemp)
trap 'rm -f "$PLAIN"' EXIT

cat > "$PLAIN" <<EOF
google-calendar:
    refresh_token: "$REFRESH_TOKEN"
    client_id: "$CLIENT_ID"
    client_secret: "$CLIENT_SECRET"
EOF

export SOPS_AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"

nix shell nixpkgs#sops --command \
  sops --encrypt \
  --config "$REPO_ROOT/.sops.yaml" \
  "$PLAIN" > "$REPO_ROOT/secrets/google-calendar.yaml"

echo "Зашифровано → secrets/google-calendar.yaml"
echo "Проверка (должны быть зашифрованные данные):"
head -5 "$REPO_ROOT/secrets/google-calendar.yaml"
