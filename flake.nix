# SPDX-License-Identifier: Apache-2.0
#
# flake.nix — entry point конфигурации «Цех».
# Описывает inputs (зависимости nixpkgs, модули) и outputs (конфигурации систем).
#
# Связь: WP-138, см. docs/architecture.md.

{
  description = "iwe-server-config — NixOS configuration for Tseren's «Цех» (tsekh-1)";

  inputs = {
    # Nixpkgs 24.11 — текущий stable. Содержит NixOS modules, пакеты.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # disko — декларативная разметка дисков (ZFS-зеркало двух NVMe).
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix — управление секретами (PGP/age шифрование, секреты в Git зашифрованными).
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, ... }@inputs: {
    # Конфигурация инстанса tsekh-1.
    # При создании новых инстансов (например, для других пилотов в Q3-Q4) —
    # добавляются новые ключи в этом attrset.
    nixosConfigurations.tsekh-1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./instances/tsekh-1
      ];
    };
  };
}
