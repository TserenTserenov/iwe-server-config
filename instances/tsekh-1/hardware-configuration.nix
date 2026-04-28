# SPDX-License-Identifier: Apache-2.0
#
# hardware-configuration.nix — реальная конфигурация железа tsekh-1.
# Сгенерирован nixos-generate-config 28 апр 2026 после Ф1 установки.
# Не редактировать вручную — при nixos-rebuild перезаписывается.

{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Файловые системы и swap определяются в modules/disko-zfs-mirror.nix.
  # Здесь только то, что disko не знает (платформа, CPU).

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
