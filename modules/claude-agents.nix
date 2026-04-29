# SPDX-License-Identifier: Apache-2.0
#
# modules/claude-agents.nix — установка Claude CLI для IWE-агентов (Ф4).
#
# Устанавливает @anthropic-ai/claude-code через npm в /home/tseren/.npm-global
# при первом запуске (RemainAfterExit=yes — повторный boot пропускает установку).
#
# После активации claude доступен в PATH всех IWE-сервисов (через systemd-timers.nix).
# Требует ANTHROPIC_API_KEY в /etc/iwe/env (уже настроен в Ф3).
#
# Связь: WP-138 Ф4. see DP.SC.019 (autonomous cloud runtime)

{ config, lib, pkgs, ... }:

let
  cfg        = config.tsekh.claudeAgents;
  npmGlobal  = "/home/tseren/.npm-global";
  claudeBin  = "${npmGlobal}/bin/claude";
in
{
  options.tsekh.claudeAgents = {
    enable = lib.mkEnableOption "Claude CLI для IWE-агентов (Ф4)";

    nodePackage = lib.mkOption {
      type        = lib.types.package;
      default     = pkgs.nodejs_22;
      description = "Пакет Node.js для npm install";
    };
  };

  config = lib.mkIf cfg.enable {

    # nix-ld: совместимость с dynamically linked binaries из npm/pip/etc.
    # Предоставляет /lib64/ld-linux-x86-64.so.2 и стандартные библиотеки.
    # Без него claude (скачанный через npm) падает с "Could not start dynamically linked executable".
    programs.nix-ld.enable = true;

    environment.systemPackages = [ cfg.nodePackage ];

    systemd.tmpfiles.rules = [
      "d ${npmGlobal} 0755 tseren tseren -"
    ];

    # Одноразовая установка Claude CLI.
    # Условие: если ${claudeBin} не существует — запускает npm install -g.
    # RemainAfterExit=yes: после успеха systemd помечает сервис как active(exited),
    # следующий boot даёт "already active" и пропускает установку.
    systemd.services."iwe-install-claude" = {
      description = "IWE — установка Claude CLI (однократно при первом boot)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      # pkgs.bash нужен: npm postinstall вызывает `sh` по имени, в Nix-PATH нет /bin/sh.
      # pkgs.bash предоставляет и bash, и sh в ${pkgs.bash}/bin/.
      path = [ cfg.nodePackage pkgs.bash pkgs.coreutils ];
      serviceConfig = {
        Type             = "oneshot";
        RemainAfterExit  = true;
        User             = "tseren";
        StandardOutput   = "journal";
        StandardError    = "journal";
        ExecStart        = pkgs.writeShellScript "install-claude-cli" ''
          set -euo pipefail
          export HOME="/home/tseren"
          export NPM_CONFIG_PREFIX="${npmGlobal}"
          if [ -f "${claudeBin}" ]; then
            echo "Claude CLI уже установлен: $(${claudeBin} --version 2>&1 | head -1)"
            exit 0
          fi
          echo "Устанавливаю @anthropic-ai/claude-code..."
          npm install -g @anthropic-ai/claude-code 2>&1
          echo "Готово: $(${claudeBin} --version 2>&1 | head -1)"
        '';
      };
    };

  };
}
