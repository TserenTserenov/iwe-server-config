# SPDX-License-Identifier: Apache-2.0
#
# modules/iwe-calendar-secrets.nix — Google Calendar read-only credentials на tsekh-1
#
# Деплоит зашифрованный secrets/google-calendar.yaml через sops-nix в файл
# ~/.secrets/google-calendar, который читает server-calendar.sh.
#
# Связь: WP-7 Block DOC (DOC3, вариант A), 2026-06-06.
#
# Использование:
#   1. Пилот создаёт Google OAuth2 refresh_token (scope calendar.readonly).
#   2. Шифрует через sops: `sops secrets/google-calendar.yaml`
#   3. Коммитит зашифрованный файл.
#   4. nixos-rebuild деплоит на сервер.
#
# Полный гайд: docs/setup-google-calendar.md

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.calendarSecrets;
in
{
  options.tsekh.calendarSecrets = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Включить деплой Google Calendar credentials через sops-nix.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "tseren";
      description = "Пользователь-владелец файла credentials.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.path;
      default = ../secrets/google-calendar.yaml;
      description = "Путь к зашифрованному sops-файлу с credentials.";
    };
  };

  config = lib.mkIf cfg.enable {
    # sops.secrets — декларирует секрет, sops-nix расшифровывает при активации
    sops.secrets."google-calendar/refresh_token" = {
      sopsFile = cfg.secretsFile;
      owner = cfg.user;
      group = "users";
      mode = "0600";
    };
    sops.secrets."google-calendar/client_id" = {
      sopsFile = cfg.secretsFile;
      owner = cfg.user;
      group = "users";
      mode = "0600";
    };
    sops.secrets."google-calendar/client_secret" = {
      sopsFile = cfg.secretsFile;
      owner = cfg.user;
      group = "users";
      mode = "0600";
    };

    # Activation script: собрать credentials в один KEY=VALUE файл
    # который читает server-calendar.sh (SECRETS_FILE=~/.secrets/google-calendar)
    system.activationScripts.iweCalendarSecrets = {
      deps = [ "setupSecrets" "users" "groups" ];
      text = ''
        SECRETS_DIR="/home/${cfg.user}/.secrets"
        CRED_FILE="$SECRETS_DIR/google-calendar"

        mkdir -p "$SECRETS_DIR"
        chmod 700 "$SECRETS_DIR"
        chown ${cfg.user}:users "$SECRETS_DIR"

        REFRESH_TOKEN=$(cat /run/secrets/google-calendar/refresh_token 2>/dev/null || echo "")
        CLIENT_ID=$(cat /run/secrets/google-calendar/client_id 2>/dev/null || echo "")
        CLIENT_SECRET=$(cat /run/secrets/google-calendar/client_secret 2>/dev/null || echo "")

        if [ -n "$REFRESH_TOKEN" ]; then
          printf 'GOOGLE_REFRESH_TOKEN=%s\nGOOGLE_CLIENT_ID=%s\nGOOGLE_CLIENT_SECRET=%s\n' \
            "$REFRESH_TOKEN" "$CLIENT_ID" "$CLIENT_SECRET" > "$CRED_FILE"
          chmod 600 "$CRED_FILE"
          chown ${cfg.user}:users "$CRED_FILE"
          echo "[iwe-calendar] credentials задеплоены → $CRED_FILE"
        else
          echo "[iwe-calendar] WARN: refresh_token пустой — credentials не записаны"
        fi
      '';
    };
  };
}
