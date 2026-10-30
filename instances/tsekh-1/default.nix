# SPDX-License-Identifier: Apache-2.0
#
# instances/tsekh-1/default.nix — конкретный инстанс «Цех».
#
# Импортирует все модули и values.nix. При наполнении в Ф1-Ф5
# сюда добавляются ссылки на новые модули (бэкапы, systemd-таймеры,
# Claude Agent SDK).

{ config, lib, pkgs, ... }:

let
  values = import ./values.nix;
in
{
  imports = [
    ../../modules/disko-zfs-mirror.nix
    ../../modules/nixos-base.nix
    ../../modules/networking-hetzner.nix
    ../../modules/users.nix
    ../../modules/backup.nix
    ../../modules/monitoring.nix
    ../../modules/caddy.nix
    ../../modules/tailscale.nix
    # ../../modules/postgres-preprod.nix  # Ф3
    ../../modules/systemd-timers.nix
    ../../modules/claude-agents.nix
    ../../modules/code-server.nix
    ../../modules/iwe-extensions-sync.nix
    ../../modules/iwe-calendar-secrets.nix  # DOC3 — Google Calendar read-only creds
    ../../modules/claude-subscription-secret.nix  # WP-7 21.07 — OAuth-токен подписки для iwe-scheduler
    ../../modules/bitcoind-ots-verify.nix  # WP-455 Ф11 hardening 27.07 — независимая верификация OTS-якорей
    ../../modules/plan-bridge.nix  # WP-561 Ф55 — приёмник запросов плана (включён в блоке tsekh.planBridge)
    ./hardware-configuration.nix # генерируется при первой установке
  ];

  # Передача параметров в модули
  tsekh.disko = {
    diskA      = values.disks.a;
    diskB      = values.disks.b;
    swapSizeGB = values.swapSizeGB;
    encrypt    = values.encrypt;
  };

  tsekh.base = {
    hostName = values.hostName;
    hostId = values.hostId;
    timeZone = "Europe/Helsinki";
  };

  tsekh.network = {
    interface = values.interface;
    ipv4 = values.ipv4;
    ipv6 = values.ipv6;
  };

  # WP-561 Ф55: приёмник запросов плана (К12, решение пилота 30.10: защита от
  # ошибок и подмены имени между своими агентами, умысел агента вне модели).
  # Включены пользователь, каталоги, конфиг хоста, ключ и служба приёмника.
  # Доставка в Git НЕ включена: нет таймера и учётных данных публикации.
  # Копия кода — vendor/plan-bridge/code, происхождение — vendor/plan-bridge/SOURCE.
  tsekh.planBridge = let
    codePaths = [
      "scripts/lib/plan_allocation.py"
      "scripts/lib/plan_bridge_allocation.py"
      "scripts/lib/plan_bridge_decisions.py"
      "scripts/lib/plan_bridge_host.py"
      "scripts/lib/plan_bridge_receiver.py"
      "scripts/lib/plan_event_bridge.py"
      "scripts/lib/plan_event_intake.py"
      "scripts/lib/plan_event_wal.py"
      "scripts/plan-event-receiver.py"
    ];
    producersPath = "machine/plan-bridge/producers.json";
    limitsPath = "machine/plan-bridge/limits.json";
  in {
    enable = true;
    receiver.enable = true;
    hostId = values.hostName;
    codeSrc = ../../vendor/plan-bridge/code;
    inherit codePaths producersPath limitsPath;
    rulesPaths = codePaths ++ [ producersPath limitsPath ];
    admit = [ "tsekh-agent-channel" ];
  };

  # uid агентов закреплён явно: на сервере он уже 1000 (проверено 30.10, uid-map
  # NixOS держит то же значение), поэтому закрепление ничего не меняет, но даёт
  # модулю plan-bridge вычислимое значение agentUid.
  users.users.tseren.uid = 1000;

  tsekh.users = {
    rootSshKeys   = values.sshKeys.root;
    tserenSshKeys = values.sshKeys.tseren;
    teamRootKeys  = values.teamSshKeys.root;
  };

  tsekh.backup = {
    enable = true;
    b2Bucket = values.backup.b2Bucket;
    backupHeartbeatUrlFile = "/etc/monitoring/backup-heartbeat-url";
  };

  tsekh.monitoring = {
    enable = true;
  };

  tsekh.timers = {
    enable  = true;
    iweHome = values.iweHome;
  };

  # Health endpoint: GET http://95.216.75.148:8080/health → JSON статус таймеров
  # Для HTTPS добавить: tsekh.caddy.domain = "tsekh.example.com" (нужна A-запись)
  tsekh.caddy = {
    enable = true;
    port   = 8080;
    # domain = null;  # добавить домен когда будет A-запись
  };

  tsekh.claudeAgents = {
    enable = true;
  };

  # Браузерный VS Code (WP-488 Ф1 spike). Без домена пока — доступ по
  # https://95.216.75.148:8443 с самоподписанным сертификатом (см. code-server.nix).
  tsekh.codeServer = {
    enable        = true;
    workspacePath = values.iweHome;
    publicHost    = values.ipv4.address;
  };

  # Приватная сеть для доступа с телефона (WP-389) — первый вход интерактивный,
  # см. комментарий в modules/tailscale.nix.
  tsekh.tailscale = {
    enable = true;
  };

  tsekh.calendarSecrets = {
    enable = true;
  };

  tsekh.claudeSubscriptionSecret = {
    enable = true;
  };

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}
