# SPDX-License-Identifier: Apache-2.0
#
# modules/disko-zfs-mirror.nix — параметризованная разметка ZFS-зеркала.
#
# Принимает на вход параметры через `config.cehSecurity.disko`:
#   diskA, diskB — два диска (пути by-id)
#   swapSizeGB   — размер swap (zvol)
#
# Создаёт на каждом диске:
#   1. BIOS boot partition (1MB) — для GRUB на BIOS legacy
#   2. /boot ext4 (1GB) — текущее решение, не дублировано через mdadm
#       (на двух дисках одинаковая копия через GRUB install на оба)
#   3. ZFS partition (остальное) — попадает в pool `rpool`
#
# ZFS pool `rpool`:
#   - mirror двух дисков
#   - datasets: root, nix, home, var, var/log
#   - zvol: swap
#   - compression=zstd, atime=off, xattr=sa, acltype=posixacl
#
# Связь: WP-138 docs/architecture.md (решение ZFS-зеркало).

{ config, lib, ... }:

let
  cfg = config.tsekh.disko;
in
{
  options.tsekh.disko = {
    diskA = lib.mkOption {
      type = lib.types.str;
      description = "Путь by-id первого NVMe диска";
      example = "/dev/disk/by-id/nvme-eui.000000000000001000080d0200461107";
    };
    diskB = lib.mkOption {
      type = lib.types.str;
      description = "Путь by-id второго NVMe диска";
      example = "/dev/disk/by-id/nvme-eui.000000000000001000080d02004611c6";
    };
    swapSizeGB = lib.mkOption {
      type = lib.types.int;
      default = 32;
      description = "Размер swap zvol в гигабайтах";
    };
    encrypt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        ZFS native encryption (aes-256-gcm) на пуле rpool.

        ТРЕБУЕТ ПЕРЕУСТАНОВКИ: encryption задаётся при создании пула (zpool create).
        Применить к существующему пулу без переустановки через nixos-anywhere невозможно.

        Когда encrypt = true:
          - rootFsOptions получают encryption=aes-256-gcm, keyformat=hex.
          - Ключ хранится в /boot/zfs.key (на нешифрованном /boot-разделе).
          - Защита: ZFS-данные нечитаемы без ключа (защита от кражи дисков).
          - /boot и GRUB не шифруются — ключ физически доступен на /boot,
            поэтому шифрование защищает только от извлечения дисков без /boot.

        Перед переустановкой:
          1. Сгенерировать ключ: dd if=/dev/urandom of=/tmp/zfs.key bs=32 count=1
          2. Сохранить ключ в 1Password (сейф tseren-knowledge, запись «ZFS key tsekh-1»)
          3. При nixos-anywhere файл /tmp/zfs.key передаётся в /boot/zfs.key
             через extra-files или postInstallCommands.
      '';
    };
  };

  config = {
    disko.devices = {
      disk = {
        a = {
          type = "disk";
          device = cfg.diskA;
          content = {
            type = "gpt";
            partitions = {
              boot-bios = {
                size = "1M";
                type = "EF02"; # BIOS boot для GRUB
              };
              boot-efi = {
                size = "1G";
                type = "8300";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/boot";
                  mountOptions = [ "nofail" ];
                };
              };
              zfs = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "rpool";
                };
              };
            };
          };
        };
        b = {
          type = "disk";
          device = cfg.diskB;
          content = {
            type = "gpt";
            partitions = {
              boot-bios = {
                size = "1M";
                type = "EF02";
              };
              # На втором диске /boot не монтируется (одна копия достаточно;
              # GRUB ставится на оба диска для загрузки при сбое одного).
              # Если первый диск физически утрачен — Hetzner меняет, /boot
              # пересоздаётся через nixos-rebuild.
              zfs = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "rpool";
                };
              };
            };
          };
        };
      };
      zpool.rpool = {
        type = "zpool";
        mode = "mirror";
        # rootFsOptions применяется к корневому датасету
        rootFsOptions = {
          compression = "zstd";
          "com.sun:auto-snapshot" = "false";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          mountpoint = "none"; # отдельные dataset'ы монтируются явно
        } // lib.optionalAttrs cfg.encrypt {
          encryption   = "aes-256-gcm";
          keyformat    = "hex";
          keylocation  = "file:///boot/zfs.key";
        };
        options.ashift = "12"; # 4K сектор для NVMe

        datasets = {
          "root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options."com.sun:auto-snapshot" = "true";
          };
          "nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              atime = "off";
              "com.sun:auto-snapshot" = "false";
            };
          };
          "home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options."com.sun:auto-snapshot" = "true";
          };
          "var" = {
            type = "zfs_fs";
            mountpoint = "/var";
            options."com.sun:auto-snapshot" = "false";
          };
          "var/log" = {
            type = "zfs_fs";
            mountpoint = "/var/log";
            options."com.sun:auto-snapshot" = "false";
          };
          "swap" = {
            type = "zfs_volume";
            size = "${toString cfg.swapSizeGB}G";
            content = {
              type = "swap";
              discardPolicy = "both";
              resumeDevice = false;
            };
          };
        };
      };
    };

    # ZFS требует hostId — задаётся в instances/<name>/values.nix.
    # Boot loader — GRUB BIOS legacy, ставится на оба диска.
    # lib.mkForce: disko тоже генерирует grub.devices из EF02-разделов;
    # без Force два определения конкатенируются → дубли → assertion fail.
    boot.loader.grub = {
      enable = lib.mkDefault true;
      devices = lib.mkForce [ cfg.diskA cfg.diskB ];
      efiSupport = lib.mkForce false;
    };

    # ZFS поддержка
    boot.supportedFilesystems = [ "zfs" ];
    # nixos-anywhere не делает zpool export перед перезагрузкой →
    # пул хранит hostId установщика, не наш → без force первый boot зависает.
    boot.zfs.forceImportRoot = true;
    services.zfs.autoScrub.enable = true;
    services.zfs.autoSnapshot = {
      enable = true;
      frequent = 4;   # каждые 15 минут, держим 4
      hourly = 24;    # 24 часа
      daily = 7;      # 7 дней
      weekly = 4;     # 4 недели
      monthly = 12;   # 12 месяцев
    };
  };
}
