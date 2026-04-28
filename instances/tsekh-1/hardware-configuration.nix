# SPDX-License-Identifier: Apache-2.0
#
# hardware-configuration.nix — параметры конкретного железа.
#
# При первой установке через nixos-anywhere этот файл будет
# перезаписан результатом `nixos-generate-config`. Текущая версия —
# минимально достаточная для запуска (то что не выводится из disko).
#
# Связь: системная информация снята с Ubuntu 28 апр.

{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Initrd модули для NVMe и ZFS
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usb_storage"
    "sd_mod"
    "sr_mod"
  ];

  # ZFS требует initrd kernel modules
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Платформа
  nixpkgs.hostPlatform = "x86_64-linux";

  # Управление CPU частотой — power-saver на idle
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "schedutil";
}
