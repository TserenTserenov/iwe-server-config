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

  # Файловые системы — ZFS датасеты (дублирует disko, нужно для nixos-rebuild)
  fileSystems."/" =
    { device = "rpool/root"; fsType = "zfs"; };
  fileSystems."/nix" =
    { device = "rpool/nix"; fsType = "zfs"; };
  fileSystems."/var" =
    { device = "rpool/var"; fsType = "zfs"; };
  fileSystems."/var/log" =
    { device = "rpool/var/log"; fsType = "zfs"; };
  fileSystems."/home" =
    { device = "rpool/home"; fsType = "zfs"; };
  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/7b401059-7965-4654-a867-b620600045b1";
      fsType = "ext4"; };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/3c343c9a-7329-47f8-af87-8dfb2aa5c2e3"; } ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
