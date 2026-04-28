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
      description = "SSH-ключи для root (текущий ключ Tseren + резервные)";
    };
    tserenSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "SSH-ключи для пользователя tseren";
    };
  };

  config = {
    # Mutable users отключены — все пользователи декларативны
    users.mutableUsers = false;

    users.users.root = {
      openssh.authorizedKeys.keys = cfg.rootSshKeys;
    };

    users.users.tseren = {
      isNormalUser = true;
      description = "Tseren Tserenov";
      extraGroups = [ "wheel" ]; # sudo
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = cfg.tserenSshKeys;
    };

    # sudo без пароля для wheel (только ключи и так)
    security.sudo.wheelNeedsPassword = false;
  };
}
