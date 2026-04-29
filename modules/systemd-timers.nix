# SPDX-License-Identifier: Apache-2.0
#
# modules/systemd-timers.nix — systemd-таймеры IWE (замена Mac launchd).
#
# Мигрирует 7 из 8 Mac launchd-задач на сервер.
# НЕ мигрируется: com.exocortex.pomodoro-alert (требует macOS GUI/notifications).
#
# Таймзона: Europe/Helsinki (UTC+3 летом = MSK) — все времена в МСК.
#
# Секреты (создать вручную на сервере, не в git):
#   /etc/iwe/env — ANTHROPIC_API_KEY=...
#                  TELEGRAM_BOT_TOKEN=...
#                  TELEGRAM_CHAT_ID=...
#
# IWE-репозитории должны быть склонированы под iweHome до первого запуска.
# Список репозиториев: docs/repos-to-clone.md (создать в Ф3).
#
# Связь: WP-138 Ф3. see DP.SC.019 (autonomous cloud runtime)

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.timers;
  iwe = cfg.iweHome;

  # caffeinate — macOS-специфичная команда (предотвращает сон).
  # На сервере не нужна: systemd сам не даёт процессам зависать.
  # Создаём no-op заглушку, чтобы scheduler.sh не падал с "command not found".
  caffeinate-stub = pkgs.writeShellScriptBin "caffeinate" ''
    # no-op: на Linux системный сон не применяется к серверу
    while [ $# -gt 0 ]; do
      case "$1" in
        -w) shift; shift ;;  # -w <PID> — ждём завершения PID, на сервере пропускаем
        -*) shift ;;
        *) break ;;
      esac
    done
  '';

  commonEnv = {
    HOME = "/home/tseren";
    # PATH не выставляем — NixOS systemd module инжектирует его автоматически
    # из system packages. Явный PATH конфликтует с auto-generated значением.
  };

  commonServiceConfig = {
    User            = "tseren";
    Type            = "oneshot";
    EnvironmentFile = "/etc/iwe/env";
    StandardOutput  = "journal";
    StandardError   = "journal";
  };
in
{
  options.tsekh.timers = {
    enable = lib.mkEnableOption "IWE systemd-таймеры (замена Mac launchd)";

    iweHome = lib.mkOption {
      type        = lib.types.str;
      default     = "/home/tseren/IWE";
      description = "Корневая директория IWE-репозиториев на сервере";
    };
  };

  config = lib.mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      git
      bash
      python3
      caffeinate-stub  # no-op для совместимости с Mac-скриптами
    ];

    systemd.tmpfiles.rules = [
      "d /etc/iwe                              0700 root   root   -"
      "d /home/tseren/logs/synchronizer        0755 tseren tseren -"
      "d /home/tseren/logs/rule-engine         0755 tseren tseren -"
      "d /home/tseren/.local/state/exocortex   0755 tseren tseren -"
      "d /home/tseren/.config/aist             0700 tseren tseren -"
    ];

    # =========================================================
    # 1. ГЛАВНЫЙ ДИСПЕТЧЕР — com.exocortex.scheduler
    # =========================================================
    # Запускает: strategist (morning/note-review/week-review),
    # extractor (inbox-check), code-scan, update.sh --all,
    # template-sync, consistency-check, daily-report,
    # unsatisfied-report, feedback-watchdog, agent-workspace-commit.
    # scheduler.sh dispatch читает config.yaml и проверяет маркеры —
    # не запустит задачу дважды в один день.

    systemd.services."iwe-scheduler" = {
      description = "IWE Scheduler — центральный диспетчер агентов";
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/DS-ai-systems/synchronizer/scripts/scheduler.sh dispatch";
        TimeoutSec = 1800;  # 30 мин — агентские задачи могут быть долгими
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-scheduler" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE Scheduler — 11 точек пробуждения (00:00–23:00 MSK)";
      timerConfig = {
        # Соответствует plist com.exocortex.scheduler:
        # 00:00 code-scan+update+week-review(Пн)+unsatisfied-report
        # 02:00 mcp-reindex
        # 03:00 подготовка к template-sync (03:30)
        # 04:00 strategist-morning + overnight-scout
        # 06:00 extractor + consistency-check
        # 09:00/12:00/15:00/18:00/21:00 extractor inbox-check
        # 23:00 note-review
        OnCalendar = [
          "*-*-* 00:00:00"
          "*-*-* 02:00:00"
          "*-*-* 03:00:00"
          "*-*-* 04:00:00"
          "*-*-* 06:00:00"
          "*-*-* 09:00:00"
          "*-*-* 12:00:00"
          "*-*-* 15:00:00"
          "*-*-* 18:00:00"
          "*-*-* 21:00:00"
          "*-*-* 23:00:00"
        ];
        Persistent = true;  # catch-up если сервер был недоступен
      };
    };

    # =========================================================
    # 2. SYNC FLEETING NOTES — com.exocortex.sync-fleeting-notes
    # =========================================================
    # git add + commit + push fleeting-notes.md каждые 2 минуты.
    # Обеспечивает, что заметки с других устройств (Telegram, телефон)
    # попадают в DS-my-strategy без задержки.

    systemd.services."iwe-sync-fleeting-notes" = {
      description = "IWE — git-синхронизация fleeting-notes.md (каждые 2 мин)";
      serviceConfig = commonServiceConfig // {
        ExecStart = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/DS-ai-systems/synchronizer/scripts/sync-files.sh ${iwe}/DS-my-strategy inbox/fleeting-notes.md";
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-sync-fleeting-notes" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE fleeting-notes sync — каждые 2 мин";
      timerConfig = {
        OnBootSec       = "2min";
        OnUnitActiveSec = "2min";
      };
    };

    # =========================================================
    # 3. ACTIVITY HUB SYNC LMS — com.iwe.activity-hub-sync
    # =========================================================
    # Синхронизация данных LMS → activity-hub БД.
    # 04:00 МСК (01:00 UTC; Helsinki UTC+3 летом → 04:00 local).

    systemd.services."iwe-activity-hub-sync" = {
      description = "IWE — синхронизация LMS → activity-hub";
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/activity-hub/scripts/sync-lms.sh";
        TimeoutSec = 600;
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-activity-hub-sync" = {
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
      };
    };

    # =========================================================
    # 4. ACTIVITY HUB SYNC IWE — com.iwe.activity-hub-sync-iwe
    # =========================================================
    # Синхронизация IWE-данных (активность, события) → activity-hub.
    # 23:00 МСК (20:00 UTC; Helsinki UTC+3 летом → 23:00 local).

    systemd.services."iwe-activity-hub-sync-iwe" = {
      description = "IWE — синхронизация IWE-событий → activity-hub";
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/activity-hub/scripts/sync-iwe.sh";
        TimeoutSec = 600;
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-activity-hub-sync-iwe" = {
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 23:00:00";
        Persistent = true;
      };
    };

    # =========================================================
    # 5. OVERNIGHT SCOUT — com.iwe.overnight-scout
    # =========================================================
    # Ночной разведчик: мировые события, отраслевые новости.
    # 04:00 МСК — тот же час, что strategist morning в scheduler.sh.
    # scheduler.sh тоже вызывает SCOUT_SH, но этот таймер запускает его
    # напрямую как fallback и для независимости от диспетчера.

    systemd.services."iwe-overnight-scout" = {
      description = "IWE — ночной разведчик (overnight-scout)";
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/DS-autonomous-agents/scripts/overnight-scout.sh";
        TimeoutSec = 1800;
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-overnight-scout" = {
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
      };
    };

    # =========================================================
    # 6. RULE CLASSIFIER (daily) — com.exocortex.rule-classifier
    # =========================================================
    # Классификация правил агента (AR.NNN → registry).
    # 23:55 — после note-review (23:00) и Day Close.

    systemd.services."iwe-rule-classifier" = {
      description = "IWE — классификатор правил агента (daily, 23:55)";
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.python3}/bin/python3 ${iwe}/.claude/scripts/rule-classifier.py";
        TimeoutSec = 300;
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-rule-classifier" = {
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 23:55:00";
        Persistent = true;
      };
    };

    # =========================================================
    # 7. RULE CLASSIFIER (hourly) — com.iwe.rule-classifier
    # =========================================================
    # Часовой запуск того же rule-classifier.py.
    # Возможно дубль daily-версии выше — проверить после Ф3:
    # если daily достаточно, этот таймер отключить (enable = false).

    systemd.services."iwe-rule-classifier-hourly" = {
      description = "IWE — классификатор правил агента (hourly)";
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.python3}/bin/python3 ${iwe}/.claude/scripts/rule-classifier.py";
        TimeoutSec = 300;
      };
      environment = commonEnv;
    };

    systemd.timers."iwe-rule-classifier-hourly" = {
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnBootSec       = "15min";  # первый запуск через 15 мин после boot
        OnUnitActiveSec = "1h";
      };
    };

    # =========================================================
    # НЕ МИГРИРОВАНО: com.exocortex.pomodoro-alert
    # =========================================================
    # pomodoro-alert.py использует macOS Notification Center / osascript.
    # Остаётся на Mac. Серверная альтернатива — Telegram-алерт (Ф5).

  };
}
