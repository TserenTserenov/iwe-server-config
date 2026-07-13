# SPDX-License-Identifier: Apache-2.0
#
# modules/backup.nix — декларативные резервные копии через restic → B2.
#
# Два задания:
#   neon-dbs  — pg_dump всех Neon БД (список URL в /etc/restic/neon-connections)
#   local     — /home/tseren + /etc/restic (сами конфиги секретов)
#
# Секреты (создаются вручную на сервере, не в git):
#   /etc/restic/password          — пароль шифрования restic (одна строка)
#   /etc/restic/b2-env            — B2_ACCOUNT_ID=xxx / B2_ACCOUNT_KEY=xxx
#   /etc/restic/neon-connections  — одна строка = один PostgreSQL URL
#
# Формат neon-connections:
#   # комментарии игнорируются
#   postgresql://user:pass@ep-xxx.neon.tech/dbname?sslmode=require
#
# Связь: WP-138 Ф2.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.backup;

  # Скрипт дампа всех БД из файла с URL
  pgDumpScript = pkgs.writeShellScript "restic-neon-dump" ''
    set -uo pipefail
    mkdir -p /tmp/restic-neon
    echo "Начало дампа Neon БД $(date -Is)"
    fail_count=0
    ok_count=0

    while IFS= read -r url; do
      # пропускаем пустые строки и комментарии
      [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue

      # имя БД — последний сегмент пути до символа '?'
      dbname=$(echo "$url" | sed 's/.*\///' | sed 's/?.*//')
      echo "  Дамп: $dbname"
      if ${pkgs.postgresql_17}/bin/pg_dump \
          --format=custom \
          --compress=0 \
          --no-password \
          "$url" \
          > /tmp/restic-neon/"$dbname".dump 2>/tmp/restic-neon/"$dbname".err; then
        echo "  OK: $dbname"
        ok_count=$((ok_count+1))
      else
        echo "  ОШИБКА: $dbname — $(cat /tmp/restic-neon/$dbname.err 2>/dev/null | tail -1)" >&2
        fail_count=$((fail_count+1))
      fi
    done < /etc/restic/neon-connections

    echo "Дамп завершён $(date -Is): OK=$ok_count ОШИБКА=$fail_count"
    # Записываем статус для heartbeat-скрипта
    echo "$fail_count" > /tmp/restic-neon-fail-count
    # Всегда exit 0 — restic должен сохранить то, что успело задампиться
    exit 0
  '';
in
{
  options.tsekh.backup = {
    enable = lib.mkEnableOption "резервное копирование через restic → B2";

    b2Bucket = lib.mkOption {
      type = lib.types.str;
      description = "Имя B2 бакета (без префикса b2:)";
      example = "tsekh-backups";
    };

    onCalendarNeon = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
      description = "Время запуска бэкапа Neon БД (systemd calendar, Helsinki UTC+3)";
    };

    onCalendarLocal = lib.mkOption {
      type = lib.types.str;
      default = "03:30";
      description = "Время запуска локального бэкапа";
    };

    backupHeartbeatUrlFile = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Путь к файлу с URL backup-heartbeat для Better Stack (одна строка).
        null = не пинговать. Пинг отправляется только после успешного бэкапа БД.
        Файл создать вручную: echo "https://uptime.betterstack.com/api/v1/heartbeat/XXX" > /etc/monitoring/backup-heartbeat-url
      '';
      example = "/etc/monitoring/backup-heartbeat-url";
    };
  };

  config = lib.mkIf cfg.enable {
    # postgresql_17 — Neon сервер v17, pg_dump требует версию >= сервера
    environment.systemPackages = with pkgs; [ restic postgresql_17 ];

    # ===== Neon БД → B2 =====
    services.restic.backups.neon-dbs = {
      initialize = true;
      repository = "b2:${cfg.b2Bucket}:neon-dbs";
      passwordFile = "/etc/restic/password";
      environmentFile = "/etc/restic/b2-env";

      backupPrepareCommand = "${pgDumpScript}";
      paths = [ "/tmp/restic-neon" ];
      backupCleanupCommand = "rm -rf /tmp/restic-neon";

      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 12"
      ];

      timerConfig = {
        OnCalendar = cfg.onCalendarNeon;
        Persistent = true;
      };
    };

    # ===== Локальные файлы → B2 =====
    services.restic.backups.local-files = {
      initialize = true;
      repository = "b2:${cfg.b2Bucket}:local";
      passwordFile = "/etc/restic/password";
      environmentFile = "/etc/restic/b2-env";

      paths = [
        "/home/tseren"
        "/etc/restic"  # секреты — чтобы не потерять при переустановке
      ];

      exclude = [
        "/home/tseren/.cache"
        "*.tmp"
        "*.log"
        "node_modules"
        ".git"
        "__pycache__"
        "*.pyc"
        ".venv"
        "venv"
        "dist"
        "build"
      ];

      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 3"
      ];

      timerConfig = {
        OnCalendar = cfg.onCalendarLocal;
        Persistent = true;
      };
    };

    # Backup heartbeat — пинг после успешного бэкапа Neon БД.
    # ExecStartPost выполняется только если основной ExecStart (restic backup) завершился успешно.
    # Решает проблему: uptime-монитор (каждые 5 мин) ≠ backup-монитор (раз в сутки).
    systemd.services."restic-backups-neon-dbs" = lib.mkIf (cfg.backupHeartbeatUrlFile != null) {
      serviceConfig.ExecStartPost = pkgs.writeShellScript "backup-heartbeat-ping" ''
        # Проверяем статус pg_dump: пинговать только если ВСЕ БД задампились успешно
        fail_count_file="/tmp/restic-neon-fail-count"
        if [ -f "$fail_count_file" ]; then
          fail_count=$(cat "$fail_count_file" | tr -d '[:space:]')
          if [ "$fail_count" != "0" ]; then
            echo "Backup heartbeat: пропускаю — $fail_count БД с ошибками" >&2
            exit 0
          fi
        else
          echo "Backup heartbeat: файл статуса не найден, пропускаю" >&2
          exit 0
        fi

        url_file="${cfg.backupHeartbeatUrlFile}"
        if [ ! -f "$url_file" ]; then
          echo "Backup heartbeat: файл $url_file не найден, пропускаю" >&2
          exit 0
        fi
        url=$(tr -d '[:space:]' < "$url_file")
        if [ -z "$url" ]; then
          echo "Backup heartbeat: пустой URL, пропускаю" >&2
          exit 0
        fi
        ${pkgs.curl}/bin/curl \
          --silent --show-error \
          --max-time 10 --retry 3 --retry-delay 5 \
          "$url" > /dev/null \
          && echo "Backup heartbeat OK (все БД в норме)" \
          || echo "Backup heartbeat FAIL (не критично)" >&2
      '';
    };

    # Директория для секретов (права только root)
    systemd.tmpfiles.rules = [
      "d /etc/restic 0700 root root -"
    ];
  };
}
