# =============================================================================
# OCI Base Configuration for NixOS VMs
# =============================================================================
# Common settings for all OCI compute instances.
# Handles cloud-init, OCI metadata, and base system configuration.
# =============================================================================

{ config, lib, pkgs, modulesPath, ... }:

{
  # Note: qcow-efi format already imports qemu-guest.nix

  config = {
    # =========================================================================
    # Boot Configuration for OCI
    # =========================================================================
    boot = {
      kernelPackages = pkgs.linuxPackages_latest;

      initrd = {
        systemd.enable = true;
        availableKernelModules = [
          "virtio_scsi"
          "virtio_balloon"
        ];
      };

      # Use GRUB for BIOS boot on OCI x86_64
      loader.grub = {
        enable = true;
        device = "/dev/sda";
      };

      # Serial console for OCI console connection
      kernelParams = [ "console=ttyS0,115200" "console=tty1" ];
    };

    # =========================================================================
    # Cloud-Init for OCI
    # =========================================================================
    # Let OCI cloud-init handle networking via Oracle datasource
    services.cloud-init = {
      enable = true;
      network.enable = true;

      settings = {
        # Preserve hostname set by Terraform
        preserve_hostname = true;

        # SSH key injection from OCI metadata
        datasource_list = [ "Oracle" "None" ];

        datasource.Oracle = {
          # Let OCI cloud-init configure networking
          apply_network_config = true;
        };

        # Cloud-init modules
        cloud_init_modules = [
          "seed_random"
          "bootcmd"
          "write-files"
          "growpart"
          "resizefs"
          "set_hostname"
          "update_hostname"
          "users-groups"
          "ssh"
        ];

        cloud_config_modules = [
          "runcmd"
          "ssh-import-id"
          "locale"
          "set-passwords"
          "timezone"
        ];

        cloud_final_modules = [
          "scripts-user"
          "phone-home"
          "final-message"
        ];
      };
    };

    # =========================================================================
    # Networking for OCI
    # =========================================================================
    # Cloud-init Oracle datasource handles network configuration via IMDS
    # NixOS should not also attempt to configure networking
    networking = {
      # Disable NixOS DHCP - cloud-init configures networking
      useDHCP = false;

      # Host-level firewall (complements OCI Security Lists)
      firewall.enable = true;
    };

    # =========================================================================
    # Time and Locale
    # =========================================================================
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

    # =========================================================================
    # Base Packages
    # =========================================================================
    environment.systemPackages = with pkgs; [
      # OCI
      cloud-init
      cloud-utils
      oci-cli

      # Networking
      curl
      wget
      iproute2
      dnsutils
      netcat
      tcpdump
      iftop

      # System
      htop
      iotop
      tmux
      jq
      git
      vim
    ];

    # =========================================================================
    # System Services
    # =========================================================================

    # Enable serial console for OCI console connection
    systemd.services."serial-getty@ttyS0" = {
      enable = true;
      wantedBy = [ "getty.target" ];
    };

    # Journal to disk for persistence
    services.journald = {
      extraConfig = ''
        Storage=persistent
        SystemMaxUse=500M
        MaxRetentionSec=7day
      '';
    };

    # NTP via systemd-timesyncd
    services.timesyncd.enable = true;

    # =========================================================================
    # Shell Environment
    # =========================================================================
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      histSize = 10000;
      histFile = "$HOME/.zsh_history";
      shellAliases = {
        lsa = "ls -la";
      };
    };

    # Set zsh as default shell for root
    users.defaultUserShell = pkgs.zsh;

    # =========================================================================
    # Nix Configuration
    # =========================================================================
    nix = {
      settings = {
        experimental-features = [ "nix-command" "flakes" ];
        auto-optimise-store = true;
      };

      # Garbage collection
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 1d";
      };
    };

    # Allow unfree packages (for some OCI-specific tools if needed)
    nixpkgs.config.allowUnfree = true;

    # =========================================================================
    # System State Version
    # =========================================================================
    system.stateVersion = "25.11";
  };
}
