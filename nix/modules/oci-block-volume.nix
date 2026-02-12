# =============================================================================
# OCI Block Volume Module
# =============================================================================
# Manages an OCI block volume identified by filesystem label. On first boot
# the raw volume is identified by excluding the boot disk (which carries the
# "nixos" label from the qcow2 image). After formatting, /dev/disk/by-label/
# provides stable identification across reboots.
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.headscale-deployment.blockVolume;
in
{
  options.headscale-deployment.blockVolume = {
    enable = lib.mkEnableOption "OCI block volume mount";

    label = lib.mkOption {
      type = lib.types.str;
      description = "ext4 filesystem label";
      example = "headscale-data";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      description = "Mount point path";
      example = "/var/lib/headscale";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.block-volume-init = {
      description = "Initialize OCI block volume with label ${cfg.label}";
      wantedBy = [ "local-fs.target" ];
      before = [ "local-fs.target" ];
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      unitConfig = {
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        # Already labeled - nothing to do
        if [ -e "/dev/disk/by-label/${cfg.label}" ]; then
          echo "Block volume ${cfg.label} ready"
          exit 0
        fi

        # First boot: identify the block volume by excluding the boot disk.
        # The boot disk always has the "nixos" label from the qcow2 image.
        BOOT_PART=$(readlink -f /dev/disk/by-label/nixos)
        BOOT_DISK="''${BOOT_PART%%[0-9]*}"

        BLOCK_DEV=""
        for dev in /dev/sd[a-z]; do
          [ -b "$dev" ] || continue
          [ "$dev" = "$BOOT_DISK" ] && continue
          BLOCK_DEV="$dev"
          break
        done

        if [ -z "$BLOCK_DEV" ]; then
          echo "FATAL: No block volume found (boot disk is $BOOT_DISK)"
          exit 1
        fi

        echo "Formatting $BLOCK_DEV as ext4 with label ${cfg.label}"
        ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L "${cfg.label}" "$BLOCK_DEV"
      '';
    };

    fileSystems.${cfg.mountPoint} = {
      device = "/dev/disk/by-label/${cfg.label}";
      fsType = "ext4";
    };
  };
}