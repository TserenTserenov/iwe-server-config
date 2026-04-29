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

    # deploy-rs — magic rollback через scheduled timer на сервере.
    # Если CD не подтверждает успех в N секунд после `nixos-rebuild switch`,
    # сервер автоматически откатывается на предыдущую generation.
    # Покрывает кейс «SSH полностью разнесло» (без него ручной Hetzner Rescue).
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, deploy-rs, ... }@inputs: {
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

    # deploy-rs configuration: magic rollback через активацию-проверку.
    # Использование: `nix run github:serokell/deploy-rs -- .#tsekh-1`
    # Таймер: 60 сек после nixos-rebuild ждёт SSH-confirmation, иначе rollback.
    deploy.nodes.tsekh-1 = {
      hostname = "95.216.75.148";
      sshUser = "root";
      sshOpts = [ "-i" "/home/runner/.ssh/id_ed25519" ];
      profiles.system = {
        user = "root";
        path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.tsekh-1;
        # Magic rollback: после activate ждём ConfirmTimeout сек.
        # Если CD не успевает SSH-вернуться и подтвердить — сервер откатывается.
        magicRollback = true;
        # 180 сек — достаточно для SSH check + critical services check + /health smoke.
        confirmTimeout = 180;
      };
    };

    # Validation для CI: deploy-rs check — проверка что конфигурация деплоится корректно.
    checks = builtins.mapAttrs
      (system: deployLib: deployLib.deployChecks self.deploy)
      deploy-rs.lib;
  };
}
