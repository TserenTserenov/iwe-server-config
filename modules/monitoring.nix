# SPDX-License-Identifier: Apache-2.0
#
# modules/monitoring.nix — базовый мониторинг и heartbeats.
#
# Создаёт systemd-таймер для Better Stack heartbeat каждые 5 минут.
# URL берётся из файла на сервере (не в git).
#
# Секреты (создаются вручную на сервере):
#   /etc/monitoring/heartbeat-url  — URL Better Stack heartbeat (одна строка)
#
# Связь: WP-138 Ф2.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.monitoring;

  heartbeatScript = pkgs.writeShellScript "better-stack-heartbeat" ''
    url_file="/etc/monitoring/heartbeat-url"
    if [ ! -f "$url_file" ]; then
      echo "Heartbeat: файл $url_file не найден, пропускаю" >&2
      exit 0
    fi
    url=$(tr -d '[:space:]' < "$url_file")
    if [ -z "$url" ]; then
      echo "Heartbeat: пустой URL, пропускаю" >&2
      exit 0
    fi
    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --max-time 10 \
      --retry 3 \
      --retry-delay 5 \
      "$url" > /dev/null
  '';
in
{
  options.tsekh.monitoring = {
    enable = lib.mkEnableOption "мониторинг через Better Stack heartbeat";

    heartbeatIntervalMin = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Интервал heartbeat в минутах";
    };
  };

  config = lib.mkIf cfg.enable {
    # Better Stack heartbeat каждые N минут
    systemd.services.better-stack-heartbeat = {
      description = "Better Stack heartbeat ping";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = heartbeatScript;
        # Если curl упал — не считать сбоем всего сервиса
        SuccessExitStatus = [ 0 1 ];
      };
    };

    systemd.timers.better-stack-heartbeat = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "${toString cfg.heartbeatIntervalMin}min";
        Unit = "better-stack-heartbeat.service";
      };
    };

    # Директория для URL (права только root)
    systemd.tmpfiles.rules = [
      "d /etc/monitoring 0700 root root -"
    ];
  };
}
