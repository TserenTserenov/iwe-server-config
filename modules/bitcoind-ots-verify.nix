# SPDX-License-Identifier: Apache-2.0
#
# modules/bitcoind-ots-verify.nix — pruned Bitcoin Core, только для локальной
# независимой верификации OpenTimestamps-якорей WP-455 (Ф11 hardening,
# 2026-07-27).
#
# Проблема: `ots verify` (opentimestamps-client) требует Bitcoin RPC-ноду,
# чтобы независимо, без доверия к календарным серверам, сверить merkle-root
# аттестации с реальным блоком (getblockhash/getblockheader). Без ноды
# `verified_at` в public.ots_anchors не проставляется НИКОГДА — календарные
# серверы вкладывают в proof `BitcoinBlockHeaderAttestation`, но локальный
# `ots verify` не может её подтвердить (падает "Could not connect to Bitcoin
# node"). Подробности и рассмотренные альтернативы (сторонний RPC-провайдер,
# Esplora-шим, ослабление семантики verified_at) →
# DS-my-strategy/inbox/WP-455/WP-455.md, секция «Продолжение 27.07».
#
# RPC не публикуется наружу: rpcbind/rpcallowip = 127.0.0.1 only, listen=0
# (не принимаем входящие P2P — нужна только исходящая синхронизация).
# Кошелёк отключён (не нужен для verify).
#
# Секрет: passwordHMAC ниже — НЕ пароль, а его односторонний HMAC-SHA256
# (формат bitcoind rpcauth, безопасно коммитить). Сам plaintext-пароль и
# итоговый RPC URL — в общем /etc/iwe/env (WP455_BITCOIN_RPC_URL), той же
# схемой, что и остальные секреты этого хоста (не в git).
#
# Первичная синхронизация (IBD) — часы, полная история цепи скачивается и
# валидируется даже при последующем prune. Место на диске после prune —
# единицы ГБ (prune=550 MiB target), диск tsekh-1 (411G свободно) не проблема.

{ config, pkgs, ... }:

{
  services.bitcoind.ots-verify = {
    enable = true;
    prune = 550; # MiB — минимальный prune target, verify нужны только заголовки+недавние блоки
    dbCache = 4000; # MiB — ускоряет первичную валидацию (62G RAM на хосте)

    rpc.users.tseren.passwordHMAC =
      "5e7fd1b9adcee684$6cd95383d47bbf8fdc21f937af522b283cabb27f3c1d96f4c394777f85f30bb4";

    extraConfig = ''
      disablewallet=1
      listen=0
      rpcbind=127.0.0.1
      rpcallowip=127.0.0.1/32
    '';
  };
}
