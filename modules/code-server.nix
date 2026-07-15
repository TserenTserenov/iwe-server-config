# SPDX-License-Identifier: Apache-2.0
#
# modules/code-server.nix — браузерный VS Code (code-server) на tsekh-1.
#
# code-server слушает только 127.0.0.1 (не выставлен в интернет напрямую).
# Caddy проксирует HTTPS-порт publicPort → code-server, с самоподписанным
# сертификатом (`tls internal`), пока нет A-записи домена на этот сервер.
# Пароль — argon2-хэш через sops-nix (secrets/code-server.yaml), сам код-server
# читает его из EnvironmentFile, а не из значения в .nix (не хардкодить в репо).
#
# Связь: WP-488 Ф1 (spike), DS-my-strategy/inbox/WP-488/WP-488.md.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.codeServer;
  envFile = "/etc/code-server/env";
in
{
  options.tsekh.codeServer = {
    enable = lib.mkEnableOption "code-server (браузерный VS Code) на этом инстансе";

    user = lib.mkOption {
      type = lib.types.str;
      default = "tseren";
      description = "Linux-пользователь, от которого работает code-server (уже должен существовать).";
    };

    workspacePath = lib.mkOption {
      type = lib.types.str;
      description = "Папка, которую code-server открывает по умолчанию (например корень IWE на сервере).";
    };

    internalPort = lib.mkOption {
      type = lib.types.port;
      default = 4444;
      description = "Порт, на котором code-server слушает только 127.0.0.1 (наружу не открыт).";
    };

    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Публичный HTTPS-порт (Caddy, самоподписанный сертификат до появления домена).";
    };

    publicHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        IP или домен, на который вешается virtualHost code-server в Caddy.
        Должен быть конкретным хостом, НЕ голым ":port" — иначе Caddy
        трактует безымянный адрес как catch-all automation policy и
        конфликтует с другими hostless site-блоками (см. modules/caddy.nix,
        порт без домена = ":port" без tls). Обычно = публичный IPv4 инстанса.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.path;
      default = ../secrets/code-server.yaml;
      description = "Зашифрованный sops-файл с code-server/hashed_password.";
    };
  };

  config = lib.mkIf cfg.enable {

    sops.secrets."code-server/hashed_password" = {
      sopsFile = cfg.secretsFile;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    services.code-server = {
      enable = true;
      host = "127.0.0.1";
      port = cfg.internalPort;
      auth = "password";
      user = cfg.user;
      group = "users";
      disableTelemetry = true;
      disableUpdateCheck = true;
      extraArguments = [ cfg.workspacePath ];
    };

    # Модуль code-server из nixpkgs по умолчанию кладёт HASHED_PASSWORD="" в
    # Environment= (пустая строка при cfg.hashedPassword по умолчанию). Глушим
    # это и передаём хэш только через EnvironmentFile (root-only, не в Nix store).
    systemd.services.code-server = {
      environment = lib.mkForce { };
      serviceConfig.EnvironmentFile = [ envFile ];
    };

    system.activationScripts.codeServerEnv = {
      deps = [ "setupSecrets" ];
      text = ''
        mkdir -p "$(dirname ${envFile})"
        chmod 700 "$(dirname ${envFile})"
        HASH=$(cat /run/secrets/code-server/hashed_password 2>/dev/null || echo "")
        if [ -z "$HASH" ]; then
          echo "[code-server] WARN: hashed_password пуст — вход по паролю не пройдёт"
        fi
        printf 'HASHED_PASSWORD=%s\n' "$HASH" > "${envFile}"
        chmod 600 "${envFile}"
      '';
    };

    # Caddy уже включён модулем caddy.nix (tsekh.caddy.enable) — здесь просто
    # добавляем ещё один virtualHost на отдельном порту, без домена.
    services.caddy.enable = true;
    services.caddy.virtualHosts."${cfg.publicHost}:${toString cfg.publicPort}" = {
      extraConfig = ''
        tls internal
        reverse_proxy 127.0.0.1:${toString cfg.internalPort}
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
  };
}
