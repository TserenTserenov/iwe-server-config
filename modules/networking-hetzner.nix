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
# Связь: системная информация снята со старого Ubuntu 28 апр.

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

      interfaces.${cfg.interface} = {
        ipv4.addresses = [{
          address = cfg.ipv4.address;
          prefixLength = cfg.ipv4.prefixLength;
        }];
        ipv6.addresses = [{
          address = cfg.ipv6.address;
          prefixLength = cfg.ipv6.prefixLength;
        }];
      };

      defaultGateway = {
        address = cfg.ipv4.gateway;
        interface = cfg.interface;
      };
      defaultGateway6 = {
        address = cfg.ipv6.gateway;
        interface = cfg.interface;
      };

      # DNS — Cloudflare + Google как резерв (нейтральные провайдеры)
      nameservers = [
        "1.1.1.1"
        "1.0.0.1"
        "8.8.8.8"
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];
    };

    # systemd-networkd: для Hetzner с /32 IPv4 и /64 IPv6 нужен явный onlink маршрут.
    systemd.network.networks."10-${cfg.interface}" = {
      matchConfig.Name = cfg.interface;
      networkConfig = {
        IPv6AcceptRA = false;
      };
      routes = [
        {
          routeConfig = {
            Gateway = cfg.ipv4.gateway;
            GatewayOnLink = true; # Hetzner требует onlink (gateway вне /32)
          };
        }
      ];
    };
  };
}
