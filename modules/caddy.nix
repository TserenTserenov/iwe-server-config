# SPDX-License-Identifier: Apache-2.0
#
# modules/caddy.nix — HTTP health endpoint + опциональный HTTPS через ACME.
#
# По умолчанию: HTTP на порту 8080, без домена, без TLS.
# С доменом: ACME/Let's Encrypt автоматически (нужен A-запись → 95.216.75.148).
#
# Endpoints:
#   GET /health   → JSON со статусом таймеров + последнего бэкапа
#   GET /ping     → "pong" (liverness probe)
#
# Статус обновляется каждые 2 минуты systemd-таймером iwe-health-update.
#
# Секреты не нужны. Данные из journalctl (read-only для root).
#
# Связь: WP-138 Ф3.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.caddy;
  healthDir = "/var/lib/iwe-health";

  # Скрипт, который собирает статус IWE-таймеров и пишет JSON в healthDir.
  # Запускается системным таймером каждые 2 мин (не per-request).
  healthUpdateScript = pkgs.writeShellScript "iwe-health-update" ''
    set -euo pipefail
    mkdir -p "${healthDir}"

    # Статус каждого IWE-таймера через systemctl show
    timers_json="["
    sep=""
    for unit in iwe-scheduler iwe-sync-fleeting-notes iwe-activity-hub-sync \
                iwe-activity-hub-sync-iwe iwe-overnight-scout \
                iwe-rule-classifier iwe-rule-classifier-hourly; do
      active=$(${pkgs.systemd}/bin/systemctl is-active "$unit.service" 2>/dev/null || true)
      last=$(${pkgs.systemd}/bin/systemctl show "$unit.service" \
               --property=ActiveEnterTimestamp --value 2>/dev/null || echo "never")
      result=$(${pkgs.systemd}/bin/systemctl show "$unit.service" \
               --property=Result --value 2>/dev/null || echo "unknown")
      timers_json+="$sep{\"unit\":\"$unit\",\"active\":\"$active\",\"last_run\":\"$last\",\"result\":\"$result\"}"
      sep=","
    done
    timers_json+="]"

    # Последний успешный бэкап
    last_backup=$(${pkgs.systemd}/bin/systemctl show restic-backups-neon-dbs.service \
                    --property=ActiveEnterTimestamp --value 2>/dev/null || echo "never")
    last_backup_result=$(${pkgs.systemd}/bin/systemctl show restic-backups-neon-dbs.service \
                    --property=Result --value 2>/dev/null || echo "unknown")

    # Uptime с момента загрузки
    boot_time=$(${pkgs.systemd}/bin/systemctl show basic.target \
                  --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")

    ${pkgs.jq}/bin/jq -n \
      --arg host    "tsekh-1" \
      --arg ts      "$(${pkgs.coreutils}/bin/date -Iseconds)" \
      --arg boot    "$boot_time" \
      --arg backup  "$last_backup" \
      --arg br      "$last_backup_result" \
      --argjson timers "$timers_json" \
      '{
        status: "ok",
        host: $host,
        timestamp: $ts,
        boot_time: $boot,
        backup: { last_run: $backup, result: $br },
        timers: $timers
      }' > "${healthDir}/status.json.tmp"

    # Атомарная замена (mv идемпотентен)
    mv "${healthDir}/status.json.tmp" "${healthDir}/status.json"
  '';

in
{
  options.tsekh.caddy = {
    enable = lib.mkEnableOption "Caddy HTTP server — health endpoint";

    port = lib.mkOption {
      type    = lib.types.port;
      default = 8080;
      description = "Порт HTTP (без домена). Игнорируется если задан domain.";
    };

    domain = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Домен для HTTPS через ACME (Let's Encrypt).
        null = только HTTP на port.
        Требует A-запись домена → IP сервера + открытые порты 80/443.
        Пример: "tsekh.example.com"
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    services.caddy = {
      enable = true;
      virtualHosts =
        let
          # Общий Caddyfile: /health → JSON из healthDir, /ping → liverness
          caddyConfig = ''
            handle /health {
              header Content-Type application/json
              root * ${healthDir}
              rewrite * /status.json
              file_server
            }
            respond /ping "pong" 200
          '';
        in
        if cfg.domain != null
        then { "${cfg.domain}"         = { extraConfig = caddyConfig; }; }
        else { ":${toString cfg.port}" = { extraConfig = caddyConfig; }; };
    };

    # systemd-таймер: обновление health JSON каждые 2 мин
    systemd.services."iwe-health-update" = {
      description = "IWE — обновление health status JSON";
      path        = with pkgs; [ systemd jq coreutils ];
      serviceConfig = {
        Type           = "oneshot";
        ExecStart      = healthUpdateScript;
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };

    systemd.timers."iwe-health-update" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE health status update — каждые 2 мин";
      timerConfig = {
        OnBootSec       = "30s";
        OnUnitActiveSec = "2min";
      };
    };

    # Директория для health JSON.
    # Владелец root (скрипт пишет как root), права 0755 (caddy читает как other).
    systemd.tmpfiles.rules = [
      "d ${healthDir} 0755 root root -"
    ];

    # Firewall: открыть нужные порты
    networking.firewall.allowedTCPPorts =
      if cfg.domain != null
      then [ 80 443 ]
      else [ cfg.port ];
  };
}
