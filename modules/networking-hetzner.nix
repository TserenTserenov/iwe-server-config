# SPDX-License-Identifier: Apache-2.0
#
# modules/networking-hetzner.nix — статическая сеть для Hetzner dedicated.
#
# Hetzner выдаёт каждому серверу:
#   - IPv4 /32 + статический gateway (например 95.216.75.129 для подсети ...148/26)
#   - IPv6 /64 + link-local gateway fe80::1
#   - Один Ethernet порт (обычно enp0s31f6 на Intel I219-LM)
#
# Конкретные значения (IP, gateway, имя интерфейса) — в instances/<name>/values.nix.
#
# Вся конфигурация через systemd-networkd напрямую (один .network файл),
# без networking.interfaces — иначе NixOS генерирует второй файл 40-<iface>.network,
# который не совпадает с нашим 10-<iface>.network по приоритету → IP не назначается.

{ config, lib, ... }:

let
  cfg = config.tsekh.network;
in
{
  options.tsekh.network = {
    interface = lib.mkOption {
      type = lib.types.str;
      default = "enp0s31f6";
      description = "Имя сетевого интерфейса (Hetzner Xeon E3 = enp0s31f6)";
    };
    ipv4 = {
      address = lib.mkOption {
        type = lib.types.str;
        description = "IPv4 адрес (например 95.216.75.148)";
      };
      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 32;
        description = "Префикс /32 для Hetzner point-to-point";
      };
      gateway = lib.mkOption {
        type = lib.types.str;
        description = "IPv4 gateway (например 95.216.75.129)";
      };
    };
    ipv6 = {
      address = lib.mkOption {
        type = lib.types.str;
        description = "IPv6 адрес (например 2a01:4f9:2b:bc3::2)";
      };
      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 64;
        description = "IPv6 префикс /64 от Hetzner";
      };
      gateway = lib.mkOption {
        type = lib.types.str;
        default = "fe80::1";
        description = "IPv6 link-local gateway (стандарт Hetzner)";
      };
    };
  };

  config = {
    networking = {
      useDHCP = false;
      useNetworkd = true;
      nameservers = [ "1.1.1.1" "1.0.0.1" "8.8.8.8" ];
    };

    # Один .network файл — полная конфигурация интерфейса.
    # Не используем networking.interfaces чтобы NixOS не генерировал конкурирующий файл.
    systemd.network.networks."10-${cfg.interface}" = {
      matchConfig.Name = cfg.interface;
      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = false;
      };
      addresses = [
        { addressConfig.Address = "${cfg.ipv4.address}/${toString cfg.ipv4.prefixLength}"; }
        { addressConfig.Address = "${cfg.ipv6.address}/${toString cfg.ipv6.prefixLength}"; }
      ];
      routes = [
        # IPv4: Hetzner /32 — gateway вне подсети, нужен onlink маршрут
        {
          routeConfig = {
            Gateway = cfg.ipv4.gateway;
            GatewayOnLink = true;
          };
        }
        # IPv6: link-local gateway тоже через onlink
        {
          routeConfig = {
            Gateway = cfg.ipv6.gateway;
            GatewayOnLink = true;
          };
        }
      ];
    };
  };
}
