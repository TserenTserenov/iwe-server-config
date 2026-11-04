# SPDX-License-Identifier: Apache-2.0
#
# modules/plan-bridge.nix — приёмник запросов плана на Цехе (WP-561 Ф55, К12).
#
# Что даёт при включении: служебный пользователь и группа записи, каталоги и
# права, конфиг хоста для адаптера моста, ключ службы (создаётся один раз при
# первом старте), код моста из хранилища Nix (владелец root, не пишется агентами)
# и службу приёмника на локальном сокете. Подготовка клонов и включение
# доставки в Git заданы раздельно: таймер включают после проверки готовности
# и утверждения версии правил (DR-06, п.5).
#
# Модель угроз (решение пилота 30.10, DR-06 п.5а): защита от ошибок и подмены
# имени между своими агентами. Умысел агента вне модели: у агентов на Цехе есть
# беспарольный sudo, общий ключ root и tseren, слияние в main применяется на
# сервер. Остаточные обходы перечислены в DR-06.
#
# Выключен по умолчанию: слияние файла без `enable = true` ничего не меняет на
# сервере. Включение — отдельный коммит и отдельное переключение.
#
# Связь: DS-my-strategy/inbox/WP-561/drr/DR-06-f55-bridge-contracts-archgate.md

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.planBridge;

  configDir = "/etc/iwe-plan-bridge";
  stateDir = "/var/lib/iwe-plan-bridge";
  keyPath = "${stateDir}/producer.key";
  githubKeyPath = "${stateDir}/github_ed25519";
  workspaceDir = "${stateDir}/workspace";
  readerRepo = "${workspaceDir}/DS-my-strategy";
  emptyGitTemplate = pkgs.runCommand "iwe-plan-bridge-git-template" { } ''
    mkdir -p $out
  '';
  githubKnownHosts = pkgs.writeText "iwe-plan-bridge-github-known-hosts" ''
    github.com ${cfg.github.hostKey}
  '';
  githubSsh = pkgs.writeShellScript "iwe-plan-bridge-git-ssh" ''
    exec ${pkgs.openssh}/bin/ssh -F /dev/null \
      -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
      -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 \
      -o UserKnownHostsFile=${githubKnownHosts} -o GlobalKnownHostsFile=/dev/null \
      -i ${githubKeyPath} "$@"
  '';

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ps.rfc8785 ]);

  # Копия кода моста в хранилище Nix: root-owned, только чтение; адаптер
  # проверяет, что код не принадлежит uid агентов, и сверяет файлы с Git.
  code = pkgs.runCommand "iwe-plan-bridge-code" { } ''
    mkdir -p $out
    cp -r ${cfg.codeSrc}/. $out/
  '';

  hostJson = builtins.toJSON {
    schema = "plan-bridge-host/1";
    host_id = cfg.hostId;
    key_path = keyPath;
    approved_rules_path = "${configDir}/approved_rules_version";
    agent_uids = [ cfg.agentUid ];
    rules_paths = cfg.rulesPaths;
    producers_path = cfg.producersPath;
    limits_path = cfg.limitsPath;
    intra_commit_order_trusted = cfg.intraCommitOrderTrusted;
    code_root = "${code}";
    code_paths = cfg.codePaths;
  };

  admitArgs = lib.concatMapStringsSep " " (id: "--admit ${lib.escapeShellArg id}") cfg.admit;

  keyScript = pkgs.writeShellScript "iwe-plan-bridge-key" ''
    set -eu
    umask 077
    if [ ! -s ${keyPath} ]; then
      ${pkgs.coreutils}/bin/head -c 32 /dev/urandom > ${keyPath}.new
      ${pkgs.coreutils}/bin/mv ${keyPath}.new ${keyPath}
    fi
  '';

  provisionScript = pkgs.writeShellScript "iwe-plan-bridge-provision" ''
    set -euo pipefail
    umask 077
    mkdir -p ${workspaceDir}
    exec 9>${stateDir}/.provision.lock
    flock -x 9
    prepare_clone() {
      local target="$1" status
      if [ ! -e "$target" ]; then
        git clone --template=${emptyGitTemplate} --branch main \
          ${lib.escapeShellArg cfg.delivery.repositoryUrl} "$target"
      fi
      test -d "$target/.git"
      test ! -L "$target"
      test ! -L "$target/.git"
      test "$(git -C "$target" remote get-url origin)" = ${lib.escapeShellArg cfg.delivery.repositoryUrl}
      test "$(git -C "$target" remote get-url --push --all origin)" = ${lib.escapeShellArg cfg.delivery.repositoryUrl}
      test "$(git -C "$target" branch --show-current)" = main
      test "$(git -C "$target" rev-parse --is-shallow-repository)" = false
      status=$(git -C "$target" status --porcelain=v1 --untracked-files=all)
      test -z "$status"
      # Повтор после прерванного clone/config должен завершать настройку.
      git -C "$target" config user.name "IWE plan bridge"
      git -C "$target" config user.email "plan-bridge@localhost"
    }
    # Один клон: мост читает план из origin и публикует туда же
    # атомарной сверкой ветки main (DR-06, вариант Д).
    prepare_clone ${readerRepo}
  '';

  deliveryEnvironment = {
    HOME = stateDir;
    GIT_CONFIG_NOSYSTEM = "1";
    GIT_CONFIG_GLOBAL = "/dev/null";
    GIT_SSH = "${configDir}/git-ssh";
    GIT_SSH_VARIANT = "ssh";
    PYTHONPYCACHEPREFIX = "/var/cache/iwe-plan-bridge";
  };
  deliveryPath = [
    pkgs.bash pkgs.coreutils pkgs.findutils pkgs.git pkgs.gnugrep
    pkgs.gnused pkgs.gawk pkgs.jq pkgs.util-linux pkgs.inetutils pkgs.procps python
  ];
in
{
  options.tsekh.planBridge = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Создать пользователя, каталоги, конфиг хоста и ключ службы приёмника.";
    };
    receiver.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Запустить службу приёмника на сокете (нужен enable = true).";
    };
    github = {
      enable = lib.mkEnableOption "отдельный GitHub-ключ службы, без запуска доставки";
      secretsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "SOPS-файл с github_private_key; закрытый ключ не попадает в Nix store.";
      };
      hostKey = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Проверенный публичный Ed25519-ключ SSH-сервера github.com.";
      };
    };
    delivery = {
      prepare = lib.mkEnableOption "собственные клоны и службу доставки без запуска таймера";
      enable = lib.mkEnableOption "доставку после проверки готовности и утверждения правил";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "SSH URL репозитория плана для отдельного ключа службы.";
      };
    };
    hostId = lib.mkOption {
      type = lib.types.str;
      description = "Имя хоста в доказательствах производителей (например tsekh).";
    };
    agentUser = lib.mkOption {
      type = lib.types.str;
      default = "tseren";
      description = "Пользователь, под которым работают агенты; входит в группу записи.";
    };
    agentUid = lib.mkOption {
      type = lib.types.int;
      default = config.users.users.${cfg.agentUser}.uid;
      defaultText = lib.literalExpression "config.users.users.\${cfg.agentUser}.uid";
      description = "uid агентов: служба с этим uid не стартует.";
    };
    codeSrc = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Каталог с копией кода моста (структура scripts/ как в DS-my-strategy).";
    };
    codePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Файлы кода (пути как в Git DS-my-strategy), которые сверяются с базой.";
    };
    rulesPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Файлы правил в Git (входят в хеш версии правил); включают codePaths, реестр и лимиты.";
    };
    producersPath = lib.mkOption {
      type = lib.types.str;
      default = "machine/plan-bridge/producers.json";
      description = "Реестр производителей в Git DS-my-strategy.";
    };
    limitsPath = lib.mkOption {
      type = lib.types.str;
      default = "machine/plan-bridge/limits.json";
      description = "Лимиты плана в Git DS-my-strategy.";
    };
    approvedRulesVersion = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Утверждённая пилотом версия правил; пусто — доставка закрыта.";
    };
    admit = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Производители, которых допускает канал приёмника.";
    };
    intraCommitOrderTrusted = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Доверять порядку внутри одного коммита; true — только после снятия прямого пути пробы (П6).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.delivery.prepare || (cfg.github.enable && cfg.delivery.repositoryUrl != "" && lib.elem "scripts/plan-event-bridge.py" cfg.codePaths);
        message = "tsekh.planBridge.delivery: подготовке нужны ключ, URL и проверяемый код доставки.";
      }
      {
        assertion = !cfg.delivery.enable || (cfg.delivery.prepare && cfg.receiver.enable && cfg.approvedRulesVersion != "");
        message = "tsekh.planBridge.delivery: включению нужны подготовка, приёмник и утверждённые правила.";
      }
      {
        assertion = !cfg.github.enable || (cfg.github.secretsFile != null && lib.hasPrefix "ssh-ed25519 " cfg.github.hostKey);
        message = "tsekh.planBridge.github: нужны зашифрованный secretsFile и проверенный hostKey.";
      }
      {
        assertion = cfg.codeSrc != null && cfg.codePaths != [ ];
        message = "tsekh.planBridge: нужны codeSrc и codePaths.";
      }
      {
        assertion = lib.all (p: lib.elem p cfg.rulesPaths) (cfg.codePaths ++ [ cfg.producersPath cfg.limitsPath ]);
        message = "tsekh.planBridge: codePaths, producersPath и limitsPath должны входить в rulesPaths.";
      }
      {
        assertion = !cfg.receiver.enable || (cfg.admit != [ ] && lib.all (id: id != "") cfg.admit);
        message = "tsekh.planBridge: приёмнику нужен непустой admit без пустых имён.";
      }
      {
        assertion = config.users.users ? ${cfg.agentUser};
        message = "tsekh.planBridge: пользователь agentUser не объявлен в users.users.";
      }
    ];

    # Две группы: основная у службы (владеет состоянием и ключом, агентов в ней
    # нет) и группа записи (владеет только каталогом сокета, в ней агенты).
    users.groups.iwe-plan-bridge = { };
    users.groups.iwe-plan-writers = { };
    users.users.iwe-plan-bridge = {
      isSystemUser = true;
      group = "iwe-plan-bridge";
      extraGroups = [ "iwe-plan-writers" ];
      home = stateDir;
      shell = "${pkgs.shadow}/bin/nologin";
      description = "Служба приёмника запросов плана (WP-561)";
    };
    users.users.${cfg.agentUser}.extraGroups = [ "iwe-plan-writers" ];

    # Приёмник может только запустить один проход доставки. Другие юниты,
    # остановка/перезапуск и изменение конфигурации этим правилом не разрешены.
    security.polkit.enable = lib.mkIf cfg.delivery.enable true;
    security.polkit.extraConfig = lib.mkIf cfg.delivery.enable ''
      polkit.addRule(function(action, subject) {
        if (subject.user === "iwe-plan-bridge" &&
            action.id === "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") === "plan-event-bridge.service" &&
            action.lookup("verb") === "start") {
          return polkit.Result.YES;
        }
      });
    '';

    sops.secrets."plan-bridge/github_private_key" = lib.mkIf cfg.github.enable {
      sopsFile = cfg.github.secretsFile;
      key = "github_private_key";
      path = githubKeyPath;
      owner = "iwe-plan-bridge";
      group = "iwe-plan-bridge";
      mode = "0600";
    };
    environment.etc."iwe-plan-bridge/git-ssh" = lib.mkIf cfg.github.enable {
      source = githubSsh;
      mode = "0555";
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 iwe-plan-bridge iwe-plan-bridge -"
      "d ${stateDir}/stream 0700 iwe-plan-bridge iwe-plan-bridge -"
    ];

    # Обычные файлы, не ссылки: адаптер отказывает на ссылках и на файлах с
    # открытой записью. Владелец root.
    environment.etc."iwe-plan-bridge/host.json" = {
      text = hostJson;
      mode = "0644";
      user = "root";
      group = "root";
    };
    environment.etc."iwe-plan-bridge/approved_rules_version" = {
      text = cfg.approvedRulesVersion + "\n";
      mode = "0644";
      user = "root";
      group = "root";
    };

    systemd.services.iwe-plan-bridge-key = {
      description = "Ключ службы приёмника запросов плана (создаётся один раз)";
      wantedBy = [ "multi-user.target" ];
      before = [ "iwe-plan-receiver.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "iwe-plan-bridge";
        Group = "iwe-plan-bridge";
        ExecStart = keyScript;
        ReadWritePaths = [ stateDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
      unitConfig.RequiresMountsFor = stateDir;
    };

    systemd.services.iwe-plan-receiver = lib.mkIf cfg.receiver.enable {
      description = "Приёмник запросов плана (WP-561 Ф55)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "iwe-plan-bridge-key.service" ];
      after = [ "iwe-plan-bridge-key.service" ];
      path = lib.optionals cfg.delivery.enable [ pkgs.systemd ];
      environment.PYTHONDONTWRITEBYTECODE = "1";
      # Отказ адаптера (код 2: хост не готов) не лечится перезапуском; прочие
      # сбои повторяются не более пяти раз за пять минут, затем юнит становится
      # failed и виден в мониторинге. Автоматический откат deploy-rs падение
      # приёмника не ловит (юнит Type=simple), поэтому видимый failed обязателен.
      unitConfig = {
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
      serviceConfig = {
        RestartPreventExitStatus = 2;
        User = "iwe-plan-bridge";
        Group = "iwe-plan-writers";
        RuntimeDirectory = "iwe-plan-bridge";
        RuntimeDirectoryMode = "0750";
        ExecStart = "${python}/bin/python ${code}/scripts/plan-event-receiver.py --stream-dir ${stateDir}/stream --socket /run/iwe-plan-bridge/receiver.sock --group iwe-plan-writers ${admitArgs}${lib.optionalString cfg.delivery.enable " --kick-unit plan-event-bridge.service"}";
        Restart = "on-failure";
        RestartSec = 5;
        ReadWritePaths = [ stateDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
      };
    };

    systemd.services.iwe-plan-bridge-provision = lib.mkIf cfg.delivery.prepare {
      description = "Собственные клоны репозитория для доставки плана";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "iwe-plan-bridge-key.service" ];
      requires = [ "iwe-plan-bridge-key.service" ];
      path = deliveryPath;
      environment = deliveryEnvironment;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "iwe-plan-bridge";
        Group = "iwe-plan-writers";
        UMask = "0077";
        CacheDirectory = "iwe-plan-bridge";
        CacheDirectoryMode = "0700";
        ExecStart = provisionScript;
        TimeoutStartSec = 600;
        ReadWritePaths = [ stateDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
      };
    };

    systemd.services.plan-event-bridge = lib.mkIf cfg.delivery.prepare {
      wants = [ "network-online.target" ];
      description = "Один проход доставки принятых запросов плана";
      after = [ "network-online.target" "iwe-plan-bridge-provision.service" ];
      requires = [ "iwe-plan-bridge-provision.service" ];
      path = deliveryPath;
      environment = deliveryEnvironment;
      serviceConfig = {
        Type = "oneshot";
        User = "iwe-plan-bridge";
        Group = "iwe-plan-writers";
        UMask = "0022";
        CacheDirectory = "iwe-plan-bridge";
        CacheDirectoryMode = "0700";
        ExecStart = "${python}/bin/python -I -X pycache_prefix=/var/cache/iwe-plan-bridge ${code}/scripts/plan-event-bridge.py --deliver-once --stream-dir ${stateDir}/stream --repository ${readerRepo}";
        TimeoutStartSec = 240;
        ReadWritePaths = [ stateDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
      };
    };

    systemd.timers.plan-event-bridge = lib.mkIf cfg.delivery.enable {
      description = "Повтор доставки плана, пока сервер доступен";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:*:00,25,50";
        AccuracySec = "1s";
        RandomizedDelaySec = 0;
        Persistent = true;
        Unit = "plan-event-bridge.service";
      };
    };
  };
}
