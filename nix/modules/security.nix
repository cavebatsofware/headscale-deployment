# =============================================================================
# Shared Security Configuration for Headscale Deployment
# =============================================================================
# This module provides hardened defaults for all VMs in the deployment.
# Security settings:
# - SSH: Key-only auth, no root password login
# - Firewall: Explicit allowlist per host
# - Fail2ban: Protect against brute force
# - Auto-updates: Nightly security patches with scheduled reboot window
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.headscale-deployment.security;
in
{
  options.headscale-deployment.security = {
    enable = lib.mkEnableOption "Enable headscale deployment security hardening";

    adminIP = lib.mkOption {
      type = lib.types.str;
      default = "68.114.66.166";
      description = "Admin IP address for SSH allowlist";
    };

    enableIPAllowlist = lib.mkOption {
      type = lib.types.bool;
      default = false;  # Disabled for initial deployment - enable after Tailscale bootstrap
      description = "Whether to restrict SSH to admin IP (disable after Tailscale bootstrap)";
    };

    vcnCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.0/16";
      description = "VCN CIDR for internal communication between VMs";
    };

    tailscaleCidr = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.0/10";
      description = "Tailscale CGNAT range for SSH access";
    };

    tailscaleInterface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "Tailscale interface name for SSH fallback";
    };

    autoUpgrade = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable automatic security updates";
      };

      rebootWindowStart = lib.mkOption {
        type = lib.types.str;
        default = "03:00";
        description = "Start of reboot window (24h format)";
      };

      rebootWindowEnd = lib.mkOption {
        type = lib.types.str;
        default = "05:00";
        description = "End of reboot window (24h format)";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # =========================================================================
    # SSH Hardening
    # =========================================================================
    services.openssh = {
      enable = true;
      settings = {
        # Disable password authentication
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;

        # Disable root login with password (key only)
        PermitRootLogin = "prohibit-password";

        # Only allow specific key types
        PubkeyAcceptedKeyTypes = "ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256";

        # Security hardening
        X11Forwarding = false;
        AllowAgentForwarding = false;
        AllowTcpForwarding = false;

        # Connection settings
        MaxAuthTries = 3;
        LoginGraceTime = 30;
        ClientAliveInterval = 300;
        ClientAliveCountMax = 2;
      };

      # Open firewall for SSH
      openFirewall = false; # We manage this explicitly below
    };

    # =========================================================================
    # Firewall Base Configuration
    # =========================================================================
    # NixOS firewall uses the nixos-fw chain. We create a custom chain for SSH
    # filtering and insert it at the top of nixos-fw so it's evaluated first.
    # =========================================================================
    networking.firewall = {
      enable = true;
      logRefusedConnections = true;
      logRefusedPackets = false; # Too verbose

      # SSH access with IP allowlist
      extraCommands = lib.mkIf cfg.enableIPAllowlist ''
        # Create custom chain for SSH filtering
        iptables -N nixos-fw-ssh 2>/dev/null || iptables -F nixos-fw-ssh

        # Allow SSH from admin IP
        iptables -A nixos-fw-ssh -s ${cfg.adminIP} -j ACCEPT

        # Allow SSH from VCN private network (internal VM-to-VM)
        iptables -A nixos-fw-ssh -s ${cfg.vcnCidr} -j ACCEPT

        # Allow SSH from Tailscale network
        iptables -A nixos-fw-ssh -s ${cfg.tailscaleCidr} -j ACCEPT

        # Drop other SSH connections
        iptables -A nixos-fw-ssh -j DROP

        # Insert jump to SSH chain at top of nixos-fw for port 22 traffic
        iptables -I nixos-fw -p tcp --dport 22 -j nixos-fw-ssh
      '';

      extraStopCommands = lib.mkIf cfg.enableIPAllowlist ''
        iptables -D nixos-fw -p tcp --dport 22 -j nixos-fw-ssh 2>/dev/null || true
        iptables -F nixos-fw-ssh 2>/dev/null || true
        iptables -X nixos-fw-ssh 2>/dev/null || true
      '';

      # When IP allowlist is disabled, just open SSH to all
      allowedTCPPorts = lib.mkIf (!cfg.enableIPAllowlist) [ 22 ];
    };

    # =========================================================================
    # Fail2ban for SSH Protection
    # =========================================================================
    services.fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "1h";
      bantime-increment = {
        enable = true;
        maxtime = "48h";
        factor = "4";
      };

      jails = {
        sshd = {
          settings = {
            enabled = true;
            port = "ssh";
            filter = "sshd";
            maxretry = 5;
            findtime = "10m";
            bantime = "1h";
          };
        };
      };
    };

    # =========================================================================
    # Automatic Security Updates
    # =========================================================================
    system.autoUpgrade = lib.mkIf cfg.autoUpgrade.enable {
      enable = true;
      allowReboot = true;
      rebootWindow = {
        lower = cfg.autoUpgrade.rebootWindowStart;
        upper = cfg.autoUpgrade.rebootWindowEnd;
      };
      dates = "04:00"; # Check for updates at 4 AM

      # Use the same channel as the system
      channel = "https://nixos.org/channels/nixos-25.11";
    };

    # =========================================================================
    # Kernel Security Hardening
    # =========================================================================
    boot.kernel.sysctl = {
      # Network security
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;
      "net.ipv4.conf.default.secure_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;

      # Prevent IP spoofing
      "net.ipv4.conf.all.log_martians" = 1;
      "net.ipv4.conf.default.log_martians" = 1;

      # Ignore ICMP broadcasts
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;

      # SYN flood protection
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.tcp_max_syn_backlog" = 2048;
      "net.ipv4.tcp_synack_retries" = 2;
    };

    # =========================================================================
    # General Security Settings
    # =========================================================================

    # Require sudo password for wheel group
    security.sudo.wheelNeedsPassword = true;

    # Disable unnecessary services
    services.avahi.enable = false;
    services.printing.enable = false;

    # Basic audit logging
    security.auditd.enable = true;
    security.audit = {
      enable = true;
      rules = [
        "-w /etc/passwd -p wa -k passwd_changes"
        "-w /etc/shadow -p wa -k shadow_changes"
        "-w /etc/sudoers -p wa -k sudoers_changes"
      ];
    };
};
}
