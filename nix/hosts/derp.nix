# =============================================================================
# DERP Relay Server Configuration
# =============================================================================
# NixOS configuration for Tailscale DERP relay server.
# Runs on OCI E2.1.Micro (AMD64) in the public subnet.
#
# Uses tailscale derper binary directly (not NixOS module) because the module
# has issues with certificate management. Derper handles its own ACME via
# built-in Let's Encrypt support.
#
# Also runs as a Tailscale client to provide exit node functionality.
#
# Services:
# - Tailscale derper - DERP relay for NAT traversal (handles own TLS)
# - Tailscale client - Exit node for tailnet (optional)
#
# Ports:
# - 443/TCP   - HTTPS (DERP protocol with built-in TLS)
# - 80/TCP    - HTTP (ACME challenges, handled by derper)
# - 3478/UDP  - STUN for NAT discovery
# - 41641/UDP - Tailscale WireGuard (when exit node enabled)
# - 22/TCP    - SSH (restricted)
#
# Note: DERP servers should NOT be behind a load balancer or HTTP proxy.
# The DERP protocol switches from HTTP to a custom binary protocol inside TLS.
#
# References:
# - https://tailscale.com/kb/1232/derp-servers
# - https://github.com/tailscale/tailscale/tree/main/cmd/derper
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.headscale-deployment.config;
  # Allow overriding hostname for east/west via this option
  derpHostname = config.headscale-deployment.derp.hostname;
in
{
  imports = [
    ../modules/oci-base.nix
    ../modules/security.nix
    ../modules/deployment-config.nix
  ];

  # ===========================================================================
  # DERP-specific options
  # ===========================================================================
  options.headscale-deployment.derp = {
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "FQDN for this DERP server (e.g., derp-east.example.com)";
    };

    regionName = lib.mkOption {
      type = lib.types.str;
      default = "OCI East";
      description = "Human-readable region name";
    };

    regionCode = lib.mkOption {
      type = lib.types.str;
      default = "oci-east";
      description = "Region code for DERP map";
    };
  };

  config = {
    # ===========================================================================
    # Host-specific settings
    # ===========================================================================
    networking.hostName = lib.mkDefault "derp";

    # ===========================================================================
    # Security Configuration
    # ===========================================================================
    headscale-deployment.security = {
      enable = true;
      adminIP = cfg.adminIP;
      vcnCidr = cfg.vcnCidr;
      enableIPAllowlist = cfg.enableIPAllowlist;
      autoUpgrade.enable = true;
    };

    # ===========================================================================
    # Firewall - DERP specific ports
    # ===========================================================================
    networking.firewall = {
      allowedTCPPorts = [
        80   # HTTP (ACME challenges)
        443  # HTTPS (DERP)
      ];
      allowedUDPPorts = [
        3478  # STUN
        41641 # Tailscale WireGuard (for exit node)
      ];
    };

    # ===========================================================================
    # Tailscale DERP Server (manual systemd service)
    # ===========================================================================
    # Using manual service because NixOS module has issues with certdir config.
    # Derper has built-in Let's Encrypt support - no external cert management needed.

    users.users.derper = {
      isSystemUser = true;
      group = "derper";
      description = "DERP server user";
    };
    users.groups.derper = {};

    systemd.services.derper = {
      description = "Tailscale DERP relay server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        # Run as root initially for port 80/443 binding, derper drops privileges
        ExecStart = ''
          ${pkgs.tailscale.derper}/bin/derper \
            -hostname=${derpHostname} \
            -a=:443 \
            -http-port=80 \
            -stun-port=3478 \
            -certmode=letsencrypt \
            -certdir=/var/lib/derper \
            -verify-clients=false
        '';
        Restart = "always";
        RestartSec = "5s";

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/derper" ];

        # State directory for ACME certs
        StateDirectory = "derper";
        StateDirectoryMode = "0700";
      };
    };

    # ===========================================================================
    # Tailscale Client (Exit Node)
    # ===========================================================================
    # The DERP server also runs as a Tailscale client to provide exit node
    # functionality. This allows tailnet devices to route internet traffic
    # through this server.
    #
    # Setup requirements:
    # 1. Create a pre-auth key on Headscale (single-use, no expiration)
    # 2. Store it in OCI Vault
    # 3. Pass the secret OCID via instance metadata (derp_preauth_secret_id)
    # 4. After DERP joins tailnet, enable route in Headscale:
    #    headscale routes enable -r <route-id>
    #
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";  # Enable IP forwarding for exit node
      authKeyFile = "/run/secrets/derp-preauth-key";
      extraUpFlags = [
        "--login-server=https://${cfg.headscaleFqdn}"
        "--advertise-exit-node"
        "--accept-dns=false"  # DERP uses its own DNS
      ];
    };

    # Tailscale needs secrets-init to provide the pre-auth key
    systemd.services.tailscaled = {
      after = [ "network-online.target" "secrets-init.service" ];
      wants = [ "network-online.target" ];
      requires = [ "secrets-init.service" ];
    };

    # ===========================================================================
    # Secrets Initialization (fetch pre-auth key from OCI Vault)
    # ===========================================================================
    systemd.services.secrets-init = {
      description = "Fetch DERP pre-auth key from OCI Vault";
      wantedBy = [ "multi-user.target" ];
      before = [ "tailscaled.service" ];
      after = [ "local-fs.target" "network-online.target" ];
      requires = [ "local-fs.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.curl pkgs.jq pkgs.oci-cli ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        mkdir -p /run/secrets
        chmod 755 /run/secrets
        IMDS_BASE="http://169.254.169.254/opc/v2"

        ${builtins.readFile ../lib/fetch-secret.sh}

        # Pre-auth key is only needed on first boot (initial tailscale registration).
        # On subsequent boots, tailscale reconnects using stored state.
        if [ -f /var/lib/tailscale/tailscaled.state ]; then
          echo "Tailscale already registered, skipping pre-auth key fetch"
        else
          fetch_secret derp_preauth_secret_id /run/secrets/derp-preauth-key root:root || \
            echo "WARNING: Pre-auth key not available - tailscale exit node will not be configured"
        fi

        echo "Secrets initialization complete"
      '';
    };

    # ===========================================================================
    # Health Check Scripts
    # ===========================================================================
    environment.systemPackages = with pkgs; [
      (writeShellScriptBin "derp-health" ''
        #!/bin/bash
        # Check if DERP is listening on 443
        ${netcat}/bin/nc -z localhost 443 || { echo "DERP not listening on 443"; exit 1; }
        # Check if STUN is listening on 3478
        ${netcat}/bin/nc -zu localhost 3478 || { echo "STUN not listening on 3478"; exit 1; }
        echo "DERP server is healthy"
      '')
      (writeShellScriptBin "derp-status" ''
        #!/bin/bash
        echo "=== DERP Service Status ==="
        systemctl status derper
        echo ""
        echo "=== DERP Certificates ==="
        ls -la /var/lib/derper/ 2>/dev/null || echo "No state directory yet"
        echo ""
        echo "=== Listening Ports ==="
        ss -tlnp | grep -E ':(443|80|3478)'
        echo ""
        echo "=== Tailscale Status ==="
        tailscale status 2>/dev/null || echo "Tailscale not connected"
        echo ""
        echo "=== Recent DERP Logs ==="
        journalctl -u derper -n 20 --no-pager
      '')
      netcat
      openssl
      tailscale         # Tailscale CLI for exit node management
      tailscale.derper  # For derper binary
    ];

  };
}
