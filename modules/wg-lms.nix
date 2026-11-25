# SPDX-License-Identifier: Apache-2.0
#
# modules/wg-lms.nix — исходящий туннель WireGuard к базе LMS (WP-542 Ф11).
#
# Цех звонит на сервер LMS, туннель ведёт только до одного адреса базы
# (allowedIPs ограничен им и внутренним адресом туннеля), весь остальной
# трафик идёт как раньше. Закрытый ключ лежит на сервере в файле, в репозиторий
# не попадает.

{ config, lib, ... }:

let
  cfg = config.tsekh.wgLms;
in
{
  options.tsekh.wgLms = {
    enable = lib.mkEnableOption "туннель WireGuard к базе LMS";
    privateKeyFile = lib.mkOption { type = lib.types.str; };
    address = lib.mkOption { type = lib.types.str; description = "адрес Цеха внутри туннеля с маской"; };
    peerPublicKey = lib.mkOption { type = lib.types.str; };
    endpoint = lib.mkOption { type = lib.types.str; description = "адрес:порт (UDP) конца LMS"; };
    allowedIPs = lib.mkOption { type = lib.types.listOf lib.types.str; };
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.interfaces.wg-lms = {
      ips = [ cfg.address ];
      privateKeyFile = cfg.privateKeyFile;
      peers = [{
        publicKey = cfg.peerPublicKey;
        endpoint = cfg.endpoint;
        allowedIPs = cfg.allowedIPs;
        persistentKeepalive = 25;
      }];
    };
  };
}
