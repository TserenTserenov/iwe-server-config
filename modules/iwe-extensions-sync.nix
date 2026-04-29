# SPDX-License-Identifier: Apache-2.0
#
# modules/iwe-extensions-sync.nix — копирование IWE extensions/scripts/skills/memory
# на сервер при каждом nixos-rebuild.
#
# Контекст: ~/IWE/.claude/, ~/IWE/extensions/, ~/IWE/scripts/ на Mac хранятся
# как локальные файлы (не в git как отдельный repo). Чтобы tsekh-1 мог запускать
# полный Day Open / extractor / scout — эти файлы должны быть на сервере.
#
# Решение: положить файлы в `server-extensions/` этого репо, при nixos-rebuild
# они копируются в ~/IWE и ~/.claude. Источник истины — Mac пользователя,
# обновление через `bash scripts/sync-extensions.sh` + git push (см. README).
#
# Связь: WP-138 follow-up (29 апр), системное решение тех-долга после ручного rsync.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.extensions;
  src = ../server-extensions;
in
{
  options.tsekh.extensions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Включить синхронизацию IWE extensions/scripts/skills/memory.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "tseren";
      description = "Пользователь-владелец синхронизируемых файлов.";
    };
  };

  config = lib.mkIf cfg.enable {
    # systemd-tmpfiles создаёт нужные директории до activation
    systemd.tmpfiles.rules = [
      "d /home/${cfg.user}/IWE/.claude 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/.claude/skills 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/.claude/scripts 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/extensions 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/scripts 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.claude/projects/-Users-${cfg.user}-IWE/memory 0755 ${cfg.user} users -"
    ];

    # Activation script: копирование файлов из nix store в /home/tseren/IWE
    # rsync с --delete: removed-files тоже удаляются (декларативное состояние).
    system.activationScripts.iweExtensionsSync = {
      deps = [ "users" "groups" ];
      text = ''
        echo "[iwe-ext-sync] копирую IWE extensions из nix store..."

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/scripts/ \
          /home/${cfg.user}/IWE/scripts/

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/extensions/ \
          /home/${cfg.user}/IWE/extensions/

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/claude-skills/day-open/ \
          /home/${cfg.user}/IWE/.claude/skills/day-open/

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/claude-scripts/ \
          /home/${cfg.user}/IWE/.claude/scripts/

        ${pkgs.rsync}/bin/rsync -a \
          ${src}/memory/ \
          /home/${cfg.user}/.claude/projects/-Users-${cfg.user}-IWE/memory/

        # Восстановить права (rsync из nix store даёт root, нужно tseren)
        chown -R ${cfg.user}:users \
          /home/${cfg.user}/IWE/scripts \
          /home/${cfg.user}/IWE/extensions \
          /home/${cfg.user}/IWE/.claude \
          /home/${cfg.user}/.claude/projects/-Users-${cfg.user}-IWE/memory

        # Скрипты должны быть executable
        find /home/${cfg.user}/IWE/scripts /home/${cfg.user}/IWE/.claude/scripts \
          -name "*.sh" -exec chmod +x {} \;

        echo "[iwe-ext-sync] sync done"
      '';
    };
  };
}
