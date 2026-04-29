# SPDX-License-Identifier: Apache-2.0
#
# modules/nixos-base.nix — базовая конфигурация NixOS.
#
# Сюда попадает то, что нужно ВСЕМ инстансам IWE-сервера независимо от пилота:
#   - SSH (только ключи)
#   - Базовые пакеты для администрирования
#   - fail2ban + UFW (firewall на портах 22, 443, 80 для Caddy)
#   - timezone, locale
#   - Автоматические обновления безопасности
#   - journald настройки (хранить разумное время)
#
# Конкретные имена пользователей, IP, hostname — в instances/<name>/values.nix.
#
# Связь: WP-138 docs/architecture.md «Безопасность».

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.base;
in
{
  options.tsekh.base = {
    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Имя хоста (например tsekh-1)";
    };
    hostId = lib.mkOption {
      type = lib.types.str;
      description = "ZFS hostId (8 hex chars). Уникальный, фиксированный.";
      example = "deadbeef";
    };
    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "Europe/Helsinki";
      description = "Hetzner HEL1-DC2 = Финляндия";
    };
  };

  config = {
    # System identity
    networking.hostName = cfg.hostName;
    networking.hostId = cfg.hostId;
    time.timeZone = cfg.timeZone;

    # Locale
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_TIME = "ru_RU.UTF-8";
      LC_MEASUREMENT = "ru_RU.UTF-8";
    };
    i18n.supportedLocales = [
      "en_US.UTF-8/UTF-8"
      "ru_RU.UTF-8/UTF-8"
    ];

    # Console
    console.keyMap = "us";

    # SSH — только ключи, не пароль
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password"; # root доступ через ключ
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        X11Forwarding = false;
      };
      openFirewall = true;
    };

    # Firewall — открыты только нужные порты
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [
        22   # SSH
        80   # HTTP (Caddy → редирект на HTTPS)
        443  # HTTPS (Caddy)
      ];
    };

    # fail2ban — защита от brute-force на SSH
    services.fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "1h";
      bantime-increment = {
        enable = true;
        maxtime = "168h"; # неделя при повторных
      };
      jails.sshd.settings = {
        enabled = true;
        backend = "systemd";
        port = "ssh";
      };
    };

    # Автоматические обновления безопасности
    system.autoUpgrade = {
      enable = true;
      flake = "github:TserenTserenov/iwe-server-config";
      flags = [
        "--update-input" "nixpkgs"
        "--commit-lock-file"
        "-L" # detail logs
      ];
      dates = "weekly";
      randomizedDelaySec = "45min";
      allowReboot = false; # ручной перезагруз
    };

    # journald — разумные лимиты, чтоб не забивало диск
    services.journald.extraConfig = ''
      SystemMaxUse=2G
      SystemKeepFree=1G
      MaxRetentionSec=1month
    '';

    # Базовые пакеты администрирования
    environment.systemPackages = with pkgs; [
      # Редакторы
      vim
      # Сеть и диагностика
      curl
      wget
      dig
      mtr
      tcpdump
      iotop
      htop
      # Файлы
      tree
      file
      ripgrep
      jq
      # ZFS управление
      zfs
      # Git
      git
      # Tar/restic — для бэкапов и восстановления
      gnutar
      restic
    ];

    # Nix настройки
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    # /bin/bash совместимость — NixOS не создаёт /bin/bash по умолчанию,
    # но все IWE-скрипты используют #!/bin/bash shebang.
    system.activationScripts.binbash = {
      deps = [];
      text = ''
        mkdir -p /bin
        ln -sfn ${pkgs.bashInteractive}/bin/bash /bin/bash
      '';
    };

    # NixOS state version — фиксируется при первой установке
    system.stateVersion = "24.11";
  };
}
