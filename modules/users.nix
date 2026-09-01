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

    # WP-544 D27/Vg2 (2026-09-01): P0-барьер против bulk-чтения секретного
    # файла окружения через sudo. NixOS не использует /etc/sudoers.d — все
    # правила деклаpируются здесь и попадают в единый сгенерированный
    # /etc/sudoers (правка руками стирается следующим nixos-rebuild, см.
    # CLAUDE.md «Антипаттерны»). extraConfig дописывается в конец файла,
    # поэтому при совпадении команды побеждает эта запись, а не более ранняя
    # групповая %wheel NOPASSWD: ALL — sudo применяет последнее совпадение,
    # не более специфичное. Известный остаток (awk/python3/symlink на тот
    # же файл всё ещё проходят) задокументирован и принят как P0, не P1.
    security.sudo.extraConfig = ''
      Cmnd_Alias IWE_SECRET_DENY = \
          /bin/cat /etc/iwe/env, /usr/bin/cat /etc/iwe/env, \
          /bin/less /etc/iwe/env, /usr/bin/less /etc/iwe/env, \
          /bin/more /etc/iwe/env, /usr/bin/more /etc/iwe/env, \
          /bin/head /etc/iwe/env, /usr/bin/head /etc/iwe/env, \
          /bin/tail /etc/iwe/env, /usr/bin/tail /etc/iwe/env, \
          /bin/cp /etc/iwe/env *, /usr/bin/cp /etc/iwe/env *, \
          /usr/bin/scp /etc/iwe/env *
      tseren ALL=(ALL:ALL) NOPASSWD: ALL, !IWE_SECRET_DENY
    '';
  };
}
