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
#                  TELEGRAM_CHAT_ID=...       (личный чат Tseren)
#                  TELEGRAM_TEAM_CHAT_ID=...  (командный канал, опционально)
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

  # Пакеты, доступные в PATH всех IWE-сервисов.
  # Используем опцию `path` (не environment.PATH) — NixOS-паттерн для systemd сервисов,
  # не конфликтует с auto-generated PATH от systemd module.
  # NixOS добавляет /bin и /sbin к КАЖДОМУ элементу path (и к пакетам, и к строкам).
  # Поэтому строку указываем как PREFIX ("/home/tseren/.npm-global"), не как готовый путь.
  # Результат: .npm-global/bin (claude CLI) и .npm-global/sbin (безвредно, не существует).
  # Python с зависимостями: pyyaml (rule-classifier), psycopg2 (dt-collect-neon).
  # Используется и в commonPath (чтобы python3 был доступен скриптам strategist/dt-collect),
  # и явно через ${pythonForIWE}/bin/python3 для rule-classifier.
  # asyncpg + aiohttp — для activity-hub sync-iwe (runner.py читает persona, пишет в learning).
  pythonForIWE = pkgs.python3.withPackages (ps: with ps; [ pyyaml psycopg2 cryptography asyncpg aiohttp ]);

  # postgresql — psql для unsatisfied-report.sh и других синхронизаторов.
  # nodejs — npx для knowledge-mcp/scripts/reindex.sh (mcp reindex task).
  # perl — используется в template-sync.sh (line 113, YAML парсинг).
  commonPath = with pkgs; [ git openssh bash curl jq gawk caffeinate-stub postgresql pythonForIWE nodejs perl gh ]
    ++ [ "/home/tseren/.npm-global" ];

  commonEnv = {
    HOME = "/home/tseren";
  };

  commonServiceConfig = {
    User            = "tseren";
    Type            = "oneshot";
    EnvironmentFile = "/etc/iwe/env";
    StandardOutput  = "journal";
    StandardError   = "journal";
  };

  # OnFailure → iwe-failure-alert@<full-unit-name>.service
  # %n = полное имя юнита включая суффикс (iwe-scheduler.service).
  # Внутри template %i = "iwe-scheduler.service" — валидно для journalctl -u.
  # НЕ %N: для не-шаблонных юнитов %N тоже включает .service → двойной суффикс.
  commonUnitConfig = {
    OnFailure = "iwe-failure-alert@%n.service";
  };

  # Pre-tick auto-pull репозиториев — закрывает дыру «GitHub ≠ сервер».
  # Запускается как ExecStartPre перед iwe-scheduler.service. Префикс `-` в ExecStartPre
  # → fail в pull НЕ блокирует ExecStart (scheduler стартует с тем кодом что есть).
  # WP-7 фаза S-A (7 мая 2026, см. inbox/WP-7-platform-tech-debt.md «Server (sync infra)»).
  #
  # Стратегия:
  #   - --ff-only (без rebase, divergent → fail-fast → TG-алерт)
  #   - timeout 60s per repo (защита от network hang)
  #   - GIT_TERMINAL_PROMPT=0 + BatchMode=yes (детерминированный fail без password prompt)
  #   - skip dirty репо (защита локальных правок) + grace-период 30s + retry,
  #     чтобы не алертить на транзиентный dirty от фоновых синхронизаторов
  #     (synchronizer пишет sync-hashes/pulse state, knowledge-mcp reindex и т.п.)
  #   - exit 0 always (не блокирует scheduler tick)
  #
  # Исключения:
  #   - DS-my-strategy: dirty почти всегда из-за iwe-sync-fleeting-notes (точечный sync inbox/fleeting-notes.md)
  #     → отдельная задача расширить sync-files.sh для inbox/WP-*.md и current/
  #   - FMT-exocortex-template: на сервере не git-репо (runtime-копия)
  # Все 8 PACK склонированы 7 мая в S-E (PACK-digital-platform склонирован в S-B).
  pullScript = pkgs.writeShellScript "iwe-pull-repos" ''
    set -uo pipefail
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

    repos=(
      "DS-IT-systems/DS-ai-systems"
      "DS-IT-systems/activity-hub"
      "DS-MCP/knowledge-mcp"
      "DS-agent-workspace"
      "DS-autonomous-agents"
      "DS-ecosystem-development"
      "DS-Knowledge-Index-Tseren"
      "PACK-MIM"
      "PACK-agent-rules"
      "PACK-autonomous-agents"
      "PACK-digital-platform"
      "PACK-ecosystem"
      "PACK-education"
      "PACK-personal"
      "PACK-verification"
    )

    failed=()
    for repo in "''${repos[@]}"; do
      dir="${iwe}/$repo"
      if [ ! -d "$dir/.git" ]; then
        echo "SKIP: $repo (не клонирован)"
        continue
      fi
      cd "$dir" || { failed+=("$repo (cd failed)"); continue; }
      if [ -n "$(${pkgs.git}/bin/git status --porcelain 2>/dev/null)" ]; then
        # Grace-период: фоновые синхронизаторы (DS-ai-systems synchronizer auto-commits,
        # knowledge-mcp reindex и т.п.) могут оставлять untracked/modified файлы на
        # секунды до собственного коммита. Ждём 30s и проверяем повторно — если всё
        # ещё dirty, считаем настоящим локальным изменением и алертим.
        echo "DIRTY: $repo (transient? grace 30s)"
        ${pkgs.coreutils}/bin/sleep 30
        if [ -n "$(${pkgs.git}/bin/git status --porcelain 2>/dev/null)" ]; then
          echo "DIRTY: $repo (uncommitted changes — пропускаю pull)"
          failed+=("$repo (dirty)")
          continue
        fi
        echo "RECOVERED: $repo (был транзиентный dirty, продолжаю pull)"
      fi
      if ${pkgs.coreutils}/bin/timeout 60s ${pkgs.git}/bin/git pull --ff-only 2>&1; then
        echo "OK: $repo"
      else
        echo "FAIL: $repo"
        failed+=("$repo (pull failed)")
      fi
    done

    # TG-алерт при ошибках. exit 0 always — не блокируем scheduler tick.
    if [ "''${#failed[@]}" -gt 0 ]; then
      msg="⚠️ IWE pull-repos warnings (tsekh-1, $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M')): ''${failed[*]}"
      ${pkgs.curl}/bin/curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=''${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$msg" \
        > /dev/null || true
    fi

    exit 0
  '';

  # Скрипт TG-алерта.
  # TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID — из EnvironmentFile /etc/iwe/env (личный чат).
  # TELEGRAM_TEAM_CHAT_ID — опционально; если задан, алерт дублируется в командный канал.
  # Вызывается как: iwe-alert <unit-name>  (без суффикса .service)
  alertScript = pkgs.writeShellScript "iwe-alert" ''
    set -euo pipefail
    unit="$1"
    host="tsekh-1"
    ts=$(${pkgs.coreutils}/bin/date -Iseconds)
    msg=$(${pkgs.coreutils}/bin/printf \
      "Сбой IWE на %s\nСервис: %s\nВремя: %s\nЛог: journalctl -u %s --since -1h" \
      "$host" "$unit" "$ts" "$unit")
    send_tg() {
      ${pkgs.curl}/bin/curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=$1" \
        --data-urlencode "text=$msg" \
        > /dev/null
    }
    send_tg "''${TELEGRAM_CHAT_ID}"
    # Командный канал — дублируем если задан
    if [ -n "''${TELEGRAM_TEAM_CHAT_ID:-}" ]; then
      send_tg "''${TELEGRAM_TEAM_CHAT_ID}"
    fi
  '';
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
      "d /home/tseren/logs/render-pilot-guides 0755 tseren tseren -"
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
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        # WP-7 S-A: pre-tick git pull для 7 IWE-репо. Префикс `-` → fail не блокирует ExecStart.
        ExecStartPre = "-${pullScript}";
        ExecStart    = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/DS-ai-systems/synchronizer/scripts/scheduler.sh dispatch";
        TimeoutSec   = 1800;  # 30 мин — включая pre-tick pull (worst-case 14×60s=14 мин)
      };
      path = commonPath;
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
        # 06:00 strategist-morning (штатно) + extractor + consistency-check
        # 08:00 strategist-morning (единственный catch-up, если 06:00 упал)
        # 09:00/12:00/15:00/18:00/21:00 extractor inbox-check
        # 23:00 note-review + autonomous day-close
        OnCalendar = [
          "*-*-* 00:00:00"
          "*-*-* 02:00:00"
          "*-*-* 03:00:00"
          "*-*-* 06:00:00"
          "*-*-* 08:00:00"
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
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/DS-ai-systems/synchronizer/scripts/sync-files.sh ${iwe}/DS-my-strategy inbox/fleeting-notes.md";
      };
      path = commonPath;
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
    # 2b. SYNC STRATEGY FILES — WP-WP-files + current/* + MEMORY.md
    # =========================================================
    # WP-7 S-C (7 мая 2026). Точечный pull WP-карточек и плана недели для DS-my-strategy.
    # Не делает full git pull (DS-my-strategy почти всегда dirty из-за iwe-sync-fleeting-notes).
    # Запускается реже чем fleeting-notes (каждые 10 мин).

    systemd.services."iwe-sync-strategy-files" = {
      description = "IWE — sync inbox/WP-*.md + current/*.md в DS-my-strategy (каждые 10 мин)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart = "${pkgs.bash}/bin/bash ${iwe}/scripts/sync-strategy-files.sh ${iwe}/DS-my-strategy";
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-sync-strategy-files" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE strategy-files sync — каждые 10 мин";
      timerConfig = {
        OnBootSec       = "5min";
        OnUnitActiveSec = "10min";
      };
    };

    # =========================================================
    # 3. ACTIVITY HUB SYNC — ДЕАКТИВИРОВАН (WP-268 Ф-migration, 2 мая 2026)
    # =========================================================
    # sync-lms и sync-iwe заменены новой архитектурой:
    #   - LMS уроки → bridge-2-lms-poller → learning.domain_event (102K+ событий)
    #   - IWE коммиты/события → event-gateway (iwe source) → learning.domain_event
    # Запускать дублирующие sync-скрипты против несуществующей БД platform нет смысла.
    # Код в DS-IT-systems/activity-hub/ сохранён для истории/109-Ф9 рефакторинга.

    # =========================================================
    # 5. OVERNIGHT SCOUT — com.iwe.overnight-scout
    # =========================================================
    # Ночной разведчик: мировые события, отраслевые новости.
    # 04:00 МСК — тот же час, что strategist morning в scheduler.sh.
    # scheduler.sh тоже вызывает SCOUT_SH, но этот таймер запускает его
    # напрямую как fallback и для независимости от диспетчера.

    systemd.services."iwe-overnight-scout" = {
      description = "IWE — ночной разведчик (overnight-scout)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-autonomous-agents/scripts/overnight-scout.sh";
        TimeoutSec = 1800;
      };
      path = commonPath;
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
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/.claude/scripts/rule-classifier.py";
        TimeoutSec = 300;
      };
      path = commonPath;
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
    # =========================================================
    # 7. RULE CLASSIFIER (hourly) — ОТКЛЮЧЁН (дубль daily 23:55)
    # =========================================================
    # daily (23:55) достаточно — hourly не несёт пользы при текущем объёме журналов.
    # Оставлен как unit для будущего включения через timerConfig.enable если нужно.

    systemd.services."iwe-rule-classifier-hourly" = {
      description = "IWE — классификатор правил агента (hourly, резерв)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/.claude/scripts/rule-classifier.py";
        TimeoutSec = 300;
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-rule-classifier-hourly" = {
      # wantedBy НЕ задан → таймер не запускается автоматически.
      # Для включения добавить: wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec       = "15min";
        OnUnitActiveSec = "1h";
      };
    };

    # =========================================================
    # 8. RENDER PILOT GUIDES — weekly (WP-149 Ф12, WP-245 Ф28.7)
    # =========================================================
    # Полный рендер всех 6 файлов персонального руководства каждому пилоту.
    # Понедельник 05:00 МСК — перед рабочей неделей.

    systemd.services."iwe-render-pilot-guides-weekly" = {
      description = "IWE — рендер руководств пилотов (weekly, Пн 05:00)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/DS-autonomous-agents/scripts/render-pilot-guides.py";
        TimeoutSec = 1800;
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-render-pilot-guides-weekly" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE рендер руководств — Пн 05:00 МСК";
      timerConfig = {
        OnCalendar = "Mon *-*-* 05:00:00";
        Persistent = true;
      };
    };

    # =========================================================
    # 9. RENDER PILOT GUIDES — daily (WP-149 Ф12, WP-245 Ф28.7)
    # =========================================================
    # Только новый daily/YYYY-MM-DD.md — вт–вс 06:00 МСК.
    # В понедельник не нужен: weekly (#8) уже делает полный рендер.

    systemd.services."iwe-render-pilot-guides-daily" = {
      description = "IWE — рендер руководств пилотов (daily, вт–вс 06:00)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/DS-autonomous-agents/scripts/render-pilot-guides.py --daily";
        TimeoutSec = 600;
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-render-pilot-guides-daily" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE рендер руководств (daily) — вт–вс 06:00 МСК";
      timerConfig = {
        OnCalendar = [
          "Tue *-*-* 06:00:00"
          "Wed *-*-* 06:00:00"
          "Thu *-*-* 06:00:00"
          "Fri *-*-* 06:00:00"
          "Sat *-*-* 06:00:00"
          "Sun *-*-* 06:00:00"
        ];
        Persistent = true;
      };
    };

    # =========================================================
    # 9.5 RENDER PILOT GUIDES — queue processor (WP-309 Ф7)
    # =========================================================
    # Обрабатывает pending-строки в learning.guide_render_queue каждые 10 мин.
    # Триггеры: repo_created (gateway), stage_transition (listener), manual.
    # Зависимости: NEON_KNOWLEDGE_URL, PERSONA_URL, ANTHROPIC_API_KEY, GITHUB_TOKEN.

    systemd.services."iwe-render-pilot-guides-queue" = {
      description = "IWE — рендер очереди персональных руководств (queue, каждые 10 мин)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/DS-autonomous-agents/scripts/render-pilot-guides.py --queue-only";
        TimeoutSec = 900;  # LIMIT=3 x 2 пути x 1x120с = 720с (weekly); LIMIT=3 x 225с = 675с (daily)
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-render-pilot-guides-queue" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE рендер очереди руководств — каждые 10 мин";
      timerConfig = {
        OnBootSec       = "2min";
        OnUnitActiveSec = "10min";
        Persistent      = false;
      };
    };

    # =========================================================
    # 10. PROFILER (daily) — recalculate_derived.py
    # =========================================================
    # Запускает R28 Профилировщик (AISYS.018) ежедневно в 04:30 МСК.
    # Читает 2_collected из digital_twins → пишет 3_derived в:
    #   - indicators.calculated_profile (F2 dual-write, всегда)
    #   - event-gateway → projection-worker (F1.A, если EVENT_GATEWAY_URL задан)
    # Зависимости: ~/.secrets/neon (INDICATORS_DIRECT, LEARNING_DIRECT, EVENT_GATEWAY_URL)
    # Связь: WP-253 Ф9.6, system.yaml AISYS.018

    systemd.services."iwe-profiler" = {
      description = "IWE — Профилировщик (recalculate_derived, 04:30 МСК)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-IT-systems/DS-ai-systems/synchronizer/scripts/recalculate.sh";
        TimeoutSec = 600;  # 10 мин — 7 пользователей × ~1 мин каждый
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-profiler" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE Профилировщик — ежедн 04:30 МСК";
      timerConfig = {
        OnCalendar = "*-*-* 04:30:00";
        Persistent = true;  # catch-up если сервер был недоступен
      };
    };

    # =========================================================
    # 10b. STAGE EVALUATOR — SR.001-SR.004 transitions (WP-253 Блок 2 Ф2.4)
    # =========================================================
    # Запускается после profiler в 04:35 МСК. Читает learning.domain_event +
    # learning.w_reflections для opt-in пилотов, INSERT'ит learning.stage_transitions
    # при изменении ступени мастерства (FORM.089 §5).
    # Env vars (требуются в /etc/iwe/env): LEARNING_URL (или DATABASE_URL_STAGE_EVALUATOR).
    # see DP.SC.020, B7.3.6 privacy spec, миграции 109/110/111.

    systemd.services."iwe-stage-evaluator" = {
      description = "IWE — Stage Evaluator (FORM.089 §5, 04:35 МСК)";
      unitConfig  = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/DS-IT-systems/activity-hub/runner.py stage-evaluator";
        WorkingDirectory = "${iwe}/DS-IT-systems/activity-hub";
        TimeoutSec = 300;  # 5 мин — небольшой объём opt-in пилотов
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-stage-evaluator" = {
      wantedBy    = [ "timers.target" ];
      description = "Stage Evaluator — ежедн 04:35 МСК (после profiler)";
      timerConfig = {
        OnCalendar = "*-*-* 04:35:00 Europe/Moscow";
        Persistent = true;
      };
    };

    # =========================================================
    # 10c. IWE STAGE CONTROLLER — двумерная карта мастерства IWE (WP-326 Ф3)
    # =========================================================
    # Service Clause: DP.SC.139, Role: DP.ROLE.046, Pack: PD.FORM.089 §6.3
    # Запускается после profiler+stage_evaluator (04:30/04:35) — в 05:30 МСК — чтобы видеть
    # свежие stage_transitions и не пересечься с render-pilot-guides (05:00 Пн / 06:00 daily).
    # render-pilot-guides-queue (каждые 10 мин) подхватит enqueued render-задачи.
    # Env vars (требуются в /etc/iwe/env): IWE_STAGE_CONTROLLER_URL — DSN роли iwe_stage_controller
    # на learning DB (создана миграциями 219/220).

    systemd.services."iwe-stage-controller" = {
      description = "IWE — Stage Controller (cp.iwe × cp.cre, ежедн 05:30 МСК)";
      unitConfig  = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/DS-autonomous-agents/scripts/iwe-stage-controller.py";
        TimeoutSec = 300;  # 5 мин — небольшой объём opt-in (9 пилотов на 17 мая, рост ожидается)
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-stage-controller" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE Stage Controller — ежедн 05:30 МСК (между stage_evaluator и render)";
      timerConfig = {
        OnCalendar = "*-*-* 05:30:00 Europe/Moscow";
        Persistent = true;
      };
    };

    # =========================================================
    # 11. ACTIVITY HUB — sync IWE engagement (GitHub + WakaTime → Neon learning)
    # =========================================================
    # Заменяет Mac launchd com.iwe.activity-hub-sync-iwe (23:00 МСК).
    # runner.py sync-iwe тянет коммиты GitHub и активность WakaTime пилотов,
    # пишет в learning.public.domain_event. Читает OAuth-токены из persona DB.
    # Env vars: LEARNING_URL, PERSONA_URL, GITHUB_TOKEN_ENCRYPTION_KEY (в /etc/iwe/env).

    systemd.services."iwe-activity-hub-sync" = {
      description = "IWE Activity Hub — sync IWE→Neon (GitHub + WakaTime, 23:00 МСК)";
      unitConfig  = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pythonForIWE}/bin/python3 ${iwe}/DS-IT-systems/activity-hub/runner.py sync-iwe";
        WorkingDirectory = "${iwe}/DS-IT-systems/activity-hub";
        TimeoutSec = 1800;  # 30 min — GitHub/WakaTime API могут быть медленными
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-activity-hub-sync" = {
      wantedBy    = [ "timers.target" ];
      description = "Activity Hub sync — ежедн 23:00 МСК";
      timerConfig = {
        # Явный TZ → детерминированно МСК круглый год.
        # Без него systemd использует Europe/Helsinki: летом EEST=MSK, зимой EET=MSK-1h.
        OnCalendar = "*-*-* 23:00:00 Europe/Moscow";
        Persistent = true;
      };
    };

    # =========================================================
    # 4. OVERNIGHT AUDITOR — R24 Аудитор безопасности (daily B7.4)
    # =========================================================
    # Запускает VR.R.002 Аудитор в headless-режиме.
    # 04:45 МСК — после strategist morning (04:00) и profiler (04:30).
    # Таймер: ежедневно, Persistent=true.

    systemd.services."iwe-overnight-auditor" = {
      description = "IWE — R24 Аудитор безопасности (daily B7.4 audit)";
      unitConfig   = commonUnitConfig;
      serviceConfig = commonServiceConfig // {
        ExecStart  = "${pkgs.bash}/bin/bash ${iwe}/DS-autonomous-agents/scripts/overnight-auditor.sh";
        TimeoutSec = 1200;
      };
      path = commonPath;
      environment = commonEnv;
    };

    systemd.timers."iwe-overnight-auditor" = {
      wantedBy    = [ "timers.target" ];
      description = "IWE Аудитор — ежедн 04:45 МСК";
      timerConfig = {
        OnCalendar = "*-*-* 04:45:00";
        Persistent = true;
      };
    };

    # =========================================================
    # FAILURE ALERT — template service (iwe-failure-alert@.service)
    # =========================================================
    # Вызывается через OnFailure=iwe-failure-alert@%N.service от каждого IWE-сервиса.
    # %N = имя упавшего юнита без суффикса (iwe-scheduler, iwe-sync-fleeting-notes, …).
    # Отправляет TG-сообщение через TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID из /etc/iwe/env.

    systemd.services."iwe-failure-alert@" = {
      description = "IWE — TG-алерт при сбое %i";
      serviceConfig = {
        User           = "tseren";   # как все остальные IWE-сервисы
        Type           = "oneshot";
        EnvironmentFile = "/etc/iwe/env";  # читается systemd (root) до смены User
        ExecStart      = "${alertScript} %i";
        StandardOutput = "journal";
        StandardError  = "journal";
      };
      path = [ pkgs.curl pkgs.coreutils ];
    };

    # =========================================================
    # НЕ МИГРИРОВАНО: com.exocortex.pomodoro-alert
    # =========================================================
    # pomodoro-alert.py использует macOS Notification Center / osascript.
    # Остаётся на Mac. Серверная альтернатива — Telegram-алерт (Ф5).

  };
}
