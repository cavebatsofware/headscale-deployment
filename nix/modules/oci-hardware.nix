# =============================================================================
# OCI Hardware Configuration for NixOS VMs
# =============================================================================
# Filesystem layout matching nixos-generators qcow format.
# Required for nixos-rebuild on deployed VMs.
# =============================================================================

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Root filesystem on /dev/sda2 (partition layout from qcow format)
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Boot partition (BIOS boot doesn't need a separate /boot mount for GRUB)
  # but the partition exists for GRUB to install to

  # Swap (if needed - cloud VMs typically don't use swap)
  swapDevices = [ ];

  # Hardware settings for OCI/QEMU
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Let DHCP configure networking (cloud-init handles this)
  # networking.useDHCP is set in oci-base.nix
}
