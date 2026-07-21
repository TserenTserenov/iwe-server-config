# SPDX-License-Identifier: Apache-2.0
#
# modules/claude-subscription-secret.nix — OAuth-токен подписки Claude на tsekh-1
#
# Деплоит зашифрованный secrets/claude-subscription.yaml через sops-nix в
# EnvironmentFile, который подключается к iwe-scheduler.service — переводит
# автоматический диспетчер-стратег с платного ANTHROPIC_API_KEY/OpenRouter-
# ключа (общий /etc/iwe/env) на личную подписку Claude, без правки самого
# /etc/iwe/env (тот общий для многих сервисов, включая те, что должны
# остаться на API-ключе — например iwe-llm-health probe).
#
# Связь: WP-7 (2026-07-21), диагностика скачка расхода OpenRouter-ключа —
# session-prep ретраился без порога попыток, дал $30 за одну ночь.
#
# Использование:
#   1. Пилот: `claude setup-token` в своём терминале (интерактивный OAuth,
#      требует Claude subscription — Pro/Max/Team/Enterprise).
#   2. Токен → secrets/claude-subscription.yaml, ключ oauth_token.
#   3. Шифрует через sops: `sops secrets/claude-subscription.yaml`.
#   4. Коммитит зашифрованный файл, nixos-rebuild деплоит на сервер.
#
# Срок жизни токена — 1 год (официально не задокументировано поведение
# истечения для systemd-автоматизации; CLI вернёт явную ошибку авторизации,
# не тихий сбой — iwe-scheduler уже шлёт TG-алерт на любой падающий сценарий).

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.claudeSubscriptionSecret;
in
{
  options.tsekh.claudeSubscriptionSecret = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Включить деплой OAuth-токена подписки Claude через sops-nix.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "tseren";
      description = "Пользователь-владелец файла с токеном.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.path;
      default = ../secrets/claude-subscription.yaml;
      description = "Путь к зашифрованному sops-файлу с OAuth-токеном.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."claude-subscription/oauth_token" = {
      sopsFile = cfg.secretsFile;
      owner = cfg.user;
      group = "users";
      mode = "0600";
    };

    # EnvironmentFile-совместимый файл (KEY=VALUE) — читает iwe-scheduler.service.
    system.activationScripts.claudeSubscriptionSecret = {
      deps = [ "setupSecrets" "users" "groups" ];
      text = ''
        SECRETS_DIR="/home/${cfg.user}/.secrets"
        CRED_FILE="$SECRETS_DIR/claude-subscription"

        mkdir -p "$SECRETS_DIR"
        chmod 700 "$SECRETS_DIR"
        chown ${cfg.user}:users "$SECRETS_DIR"

        OAUTH_TOKEN=$(cat /run/secrets/claude-subscription/oauth_token 2>/dev/null || echo "")

        if [ -n "$OAUTH_TOKEN" ]; then
          printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$OAUTH_TOKEN" > "$CRED_FILE"
          chmod 600 "$CRED_FILE"
          chown ${cfg.user}:users "$CRED_FILE"
          echo "[claude-subscription] токен задеплоен → $CRED_FILE"
        else
          echo "[claude-subscription] WARN: oauth_token пустой — файл не записан"
        fi
      '';
    };
  };
}
