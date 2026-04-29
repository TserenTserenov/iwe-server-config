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
    # ../../modules/caddy.nix          # Ф3
    # ../../modules/postgres-preprod.nix  # Ф3
    ../../modules/systemd-timers.nix
    # ../../modules/claude-agents.nix     # Ф4
    ./hardware-configuration.nix # генерируется при первой установке
  ];

  # Передача параметров в модули
  tsekh.disko = {
    diskA = values.disks.a;
    diskB = values.disks.b;
    swapSizeGB = values.swapSizeGB;
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

  tsekh.users = {
    rootSshKeys = values.sshKeys.root;
    tserenSshKeys = values.sshKeys.tseren;
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
}
