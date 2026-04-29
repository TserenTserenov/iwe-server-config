# SPDX-License-Identifier: Apache-2.0
#
# instances/tsekh-1/values.nix — мои константы для «Цеха».
#
# При извлечении шаблона T5 в Q3-Q4 этот файл становится примером —
# каждый пилот заполняет свой values.nix под своё железо.
#
# Источники значений:
#   - hardware (диски, NIC) — снято с текущего Ubuntu 28 апр (snapshot 00-system-info.txt)
#   - сеть — Hetzner Robot для этого сервера
#   - SSH-ключи — из 1Password сейф `tseren-knowledge`

{
  # Hostname и ZFS hostId
  hostName = "tsekh-1";
  hostId = "f27da647";  # стабильный 8-hex hostId; не менять (ZFS импорт сломается)

  # Сетевой интерфейс (Hetzner Xeon E3 = enp0s31f6, Intel I219-LM)
  interface = "enp0s31f6";

  # IPv4 — Hetzner /32 point-to-point
  ipv4 = {
    address = "95.216.75.148";
    prefixLength = 32;
    gateway = "95.216.75.129";
  };

  # IPv6 — /64 от Hetzner, link-local gateway
  ipv6 = {
    address = "2a01:4f9:2b:bc3::2";
    prefixLength = 64;
    gateway = "fe80::1";
  };

  # Диски (by-id, не by-path — устойчиво к переупорядочиванию)
  # Диски — два Toshiba KXG50ZNV512G NVMe
  disks = {
    a = "/dev/disk/by-id/nvme-eui.000000000000001000080d0200461107";
    b = "/dev/disk/by-id/nvme-eui.000000000000001000080d02004611c6";
  };

  # Swap размер (zvol) — 32GB как сейчас на mdadm
  swapSizeGB = 32;

  # ZFS native encryption — включить при следующей переустановке через nixos-anywhere.
  # false = текущий живой пул rpool создан без шифрования (28 апр 2026).
  # Для включения: сгенерировать ключ, сохранить в 1Password, переустановить через nixos-anywhere.
  # Инструкция: modules/disko-zfs-mirror.nix → options.tsekh.disko.encrypt (описание).
  encrypt = false;

  # SSH-ключи — добавятся при первом запуске Ф1.
  # Сейчас плейсхолдеры. Перед `nixos-anywhere` подменяем на реальные
  # из ~/.ssh/authorized_keys на сервере + 1Password.
  # SSH-ключи — публичные, можно держать в git.
  # Текущий ключ снят с активного root@95.216.75.148 28 апр.
  # Дополнительные ключи (резервный, ноутбук, Андрей-collaborator)
  # добавляются по мере появления — обновлять только этот файл.
  # Резервное копирование (Ф2)
  # b2Bucket — имя B2 бакета (без b2:). Найти в 1Password «tseren-knowledge»
  # или посмотреть в настройках старого Ubuntu restic (pre-nixos-snapshot → /etc/hetzner-backstage/env)
  backup = {
    b2Bucket = "aisystant-neon-backup";
  };

  # Корневая директория IWE-репозиториев на сервере
  iweHome = "/home/tseren/IWE";

  sshKeys = {
    root = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM4q8Z+S8CK16KKRRTyr8X6/OP3WFtew+2pud2tUO9DX tserenov1972@gmail.com"
      # Deploy key для GitHub Actions CD (приватный ключ — в SSH_PRIVATE_KEY secret).
      # Используется для git pull + nixos-rebuild + post-deploy health checks + rollback.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJwvKzFjBaGxrg9lv8favoWVUlH6KMirdf7K8RePVGlL iwe-server-config-deploy@github-actions"
    ];
    tseren = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM4q8Z+S8CK16KKRRTyr8X6/OP3WFtew+2pud2tUO9DX tserenov1972@gmail.com"
    ];
  };

  # SSH-ключи команды — bus factor ≥2 к 1 июня 2026.
  # Добавить публичный ключ Андрея когда пришлёт (запросить через TG).
  # Формат: "ssh-ed25519 AAAA... andrey@example.com"
  teamSshKeys = {
    root = [
      # "ssh-ed25519 AAAA...  andrey-smirnov"  # добавить ключ Андрея
    ];
  };
}
