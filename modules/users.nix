# SPDX-License-Identifier: Apache-2.0
#
# modules/users.nix — пользователи системы.
#
# По умолчанию создаётся root + tseren. Конкретные SSH-ключи — в instances/<name>/values.nix.
#
# Связь: WP-138 «Bus factor» — Андрей и Ильшат добавляются в Ф2 при необходимости.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.users;
in
{
  options.tsekh.users = {
    rootSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "SSH-ключи владельца для root (Tseren + резервные)";
    };
    tserenSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "SSH-ключи для пользователя tseren";
    };
    teamRootKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        SSH-ключи членов команды с root-доступом (bus factor).
        Добавлять только тем, кто умеет работать с NixOS и понимает recovery.md.
        Текущий список: instances/tsekh-1/values.nix → teamSshKeys.root
      '';
    };
  };

  config = {
    # Mutable users отключены — все пользователи декларативны
    users.mutableUsers = false;

    users.users.root = {
      openssh.authorizedKeys.keys = cfg.rootSshKeys ++ cfg.teamRootKeys;
    };

    users.users.tseren = {
      isNormalUser = true;
      description = "Tseren Tserenov";
      # wheel — sudo (без пароля, см. ниже); systemd-journal — чтение journalctl
      # сервисами под User=tseren (WP-486: iwe-backup-stress-test SC1 читает
      # journal restic-backups-neon-dbs.service; без группы журнал пуст → ложный FAIL).
      # Эскалации нет: wheel уже даёт passwordless sudo.
      extraGroups = [ "wheel" "systemd-journal" ];
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = cfg.tserenSshKeys;
    };

    # sudo без пароля для wheel (только ключи и так)
    security.sudo.wheelNeedsPassword = false;
  };
}
