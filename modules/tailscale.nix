# SPDX-License-Identifier: Apache-2.0
#
# modules/tailscale.nix — приватная сеть Tailscale для доступа с личных
# устройств (телефон, ноутбук) к сервисам tsekh-1, не выставленным в интернет.
#
# Ничего не открывает в публичный интернет: узел присоединяется к частной
# сети пилота (WireGuard-меш), трафик идёт между устройствами, у которых
# есть учётная запись в том же tailnet. Первое включение требует интерактивного
# входа («tailscale up» печатает ссылку, пилот открывает её в браузере и
# подтверждает узел) — это не автоматизируется из этого модуля намеренно,
# учётные данные пилота не хранятся в репозитории.
#
# Связь: WP-389 (личный помощник «Секретарь»), табло здоровья/календаря на
# телефон без публичного сервера.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.tailscale;
in
{
  options.tsekh.tailscale = {
    enable = lib.mkEnableOption "Tailscale (приватная сеть устройств пилота)";
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    # Loose reverse-path только для tailscale0 (ядро берёт максимум из "all"
    # и интерфейсного значения, поэтому обычные интерфейсы остаются строгими).
    # Глобальный checkReversePath = "loose" ослабил бы защиту от спуфинга и на
    # публичном eth0 — holiday review этой правки (peer-session 2026-10-11).
    boot.kernel.sysctl."net.ipv4.conf.tailscale0.rp_filter" = 2;

    # Явный порт вместо trustedInterfaces (который открыл бы на tailscale0
    # вообще всё, включая случайный сервис, слушающий 0.0.0.0): только то,
    # что `tailscale serve` реально использует для проксирования HTTPS.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
  };
}
