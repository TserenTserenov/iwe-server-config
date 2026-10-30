# SPDX-License-Identifier: Apache-2.0
#
# modules/plan-bridge.nix — приёмник запросов плана на Цехе (WP-561 Ф55, К12).
#
# Что даёт при включении: служебный пользователь и группа записи, каталоги и
# права, конфиг хоста для адаптера моста, ключ службы (создаётся один раз при
# первом старте), код моста из хранилища Nix (владелец root, не пишется агентами)
# и службу приёмника на локальном сокете. Доставка в Git (мост, таймер) здесь
# НЕ определена: учётные данные публикации ещё не решены (DR-06, п.5).
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
      environment.PYTHONDONTWRITEBYTECODE = "1";
      serviceConfig = {
        User = "iwe-plan-bridge";
        Group = "iwe-plan-writers";
        RuntimeDirectory = "iwe-plan-bridge";
        RuntimeDirectoryMode = "0750";
        ExecStart = "${python}/bin/python ${code}/scripts/plan-event-receiver.py --stream-dir ${stateDir}/stream --socket /run/iwe-plan-bridge/receiver.sock --group iwe-plan-writers ${admitArgs}";
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
  };
}
