# =============================================================================
# Headscale Host Configuration
# =============================================================================
# NixOS configuration for the Headscale control plane server.
# Runs on OCI E2.1.Micro (AMD64) in the public subnet.
#
# Uses native NixOS services.headscale module (no containers).
#
# Services:
# - Headscale - Native NixOS service
# - Headplane - Admin UI for Headscale (at /admin path)
# - nginx - Reverse proxy with automatic TLS via ACME
#
# Ports:
# - 443/TCP   - HTTPS (nginx -> Headscale API + Headplane)
# - 80/TCP    - HTTP (ACME challenges, redirects to HTTPS)
# - 50443/TCP - gRPC (direct for Tailscale clients)
# - 3000/TCP  - Headplane (internal, proxied via nginx)
# - 22/TCP    - SSH (restricted)
#
# References:
# - https://mynixos.com/options/services.headscale
# - https://carlosvaz.com/posts/setting-up-headscale-on-nixos/
# - https://headplane.net/
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.headscale-deployment.config;

in
{
  imports = [
    ../modules/oci-base.nix
    ../modules/oci-block-volume.nix
    ../modules/security.nix
    ../modules/deployment-config.nix
    ../modules/nginx-rate-limit.nix
  ];

  config = {
    # ===========================================================================
    # Host-specific settings
    # ===========================================================================
    networking.hostName = "headscale";

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
    # Rate Limiting
    # ===========================================================================
    headscale-deployment.nginx.rateLimit = {
      enable = true;
      zoneName = "headscale";
    };

    # ===========================================================================
    # Firewall - Headscale specific ports
    # ===========================================================================
    networking.firewall = {
      allowedTCPPorts = [
        80    # HTTP (ACME + redirect)
        443   # HTTPS
        50443 # Headscale gRPC
      ];
    };

    # ===========================================================================
    # Nginx Reverse Proxy
    # ===========================================================================
    # Using raw nginx config for complex routing (Headplane + Headscale)
    # Path-based routing: /admin -> Headplane, everything else -> Headscale API

    # ACME certificate management
    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.acmeEmail;
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;

      # WebSocket connection upgrade mapping
      appendHttpConfig = ''
        map $http_upgrade $connection_upgrade {
          default upgrade;
          "" close;
        }
      '';

      virtualHosts."${cfg.headscaleFqdn}" = {
        forceSSL = true;
        enableACME = true;

        # Block management API from public access
        # Headplane connects directly to localhost:8080, bypassing nginx
        locations."/api/" = {
          return = "403";
        };

        # Headplane admin UI at /admin
        locations."/admin" = {
          proxyPass = "http://127.0.0.1:3000";
          extraConfig = ''
            limit_req zone=headscale burst=50 nodelay;
            limit_req_status 429;

            # Security headers
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          '';
        };

        # Default: Headscale API with WebSocket support
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          extraConfig = ''
            limit_req zone=headscale burst=50 nodelay;
            limit_req_status 429;

            # Security headers
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;

            # WebSocket support for Tailscale control protocol
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_buffering off;
            proxy_redirect http:// https://;
            proxy_read_timeout 7d;
            proxy_send_timeout 7d;
          '';
        };
      };
    };

    # ===========================================================================
    # Headscale Service (Native NixOS)
    # ===========================================================================
    services.headscale = {
      enable = true;
      address = "127.0.0.1";  # Bind to localhost - nginx proxies to this
      port = 8080;

      settings = {
        # Server URL - clients use this to connect
        server_url = "https://${cfg.headscaleFqdn}";

        # gRPC for Tailscale client communication
        grpc_listen_addr = "0.0.0.0:50443";
        grpc_allow_insecure = false;

        # IP prefixes for Tailscale network
        prefixes = {
          v4 = "100.64.0.0/10";
          v6 = "fd7a:115c:a1e0::/48";
        };

        # Database - PostgreSQL on Keycloak VM
        database = {
          type = "postgres";
          postgres = {
            host = cfg.keycloakPrivateIP;
            port = cfg.postgresPort;
            name = cfg.headscaleDbName;
            user = cfg.headscaleDbUser;
            password_file = "/run/secrets/headscale-db-password";
            ssl = false; # Internal VCN traffic
          };
        };

        # DERP relay configuration
        derp = {
          server = {
            enabled = false; # Using dedicated DERP servers
          };
          urls = [ ]; # Don't use public DERP servers
          paths = [ "/etc/headscale/derp.yaml" ];
          auto_update_enabled = false;
        };

        # DNS configuration for Magic DNS
        dns = {
          magic_dns = true;
          base_domain = cfg.tailnetDomain;
          nameservers = {
            global = [
              "1.1.1.1"
              "1.0.0.1"
            ];
          };
        };

        # OIDC configuration (Keycloak)
        oidc = {
          only_start_if_oidc_is_available = true;
          issuer = "https://${cfg.keycloakFqdn}/realms/${cfg.oidcRealm}";
          client_id = cfg.oidcClientId;
          client_secret_path = "/run/secrets/headscale-oidc-secret";
          scope = [ "openid" "profile" "email" ];
          allowed_groups = [ ];
          # PKCE required by Keycloak
          pkce = {
            enabled = true;
            method = "S256";
          };
        };

        # Logging
        log = {
          format = "text";
          level = "info";
        };

        # Metrics endpoint
        metrics_listen_addr = "127.0.0.1:9090";

        # Disable update checks (we manage updates via NixOS)
        disable_check_updates = true;

        # Disable built-in telemetry
        logtail = {
          enabled = false;
        };
      };
    };

    # ===========================================================================
    # Headplane Admin UI
    # ===========================================================================
    # Headplane provides a web UI for managing Headscale.
    # Uses the same OIDC client as Headscale for authentication.
    # Access at: https://${cfg.headscaleFqdn}/admin
    services.headplane = {
      enable = true;

      settings = {
        server = {
          host = "127.0.0.1";
          port = 3000;
          cookie_secret_path = "/run/secrets/headplane-cookie-secret";
          cookie_secure = true;
        };

        headscale = {
          url = "http://127.0.0.1:8080";
          config_path = "/etc/headscale/config.yaml";
          public_url = "https://${cfg.headscaleFqdn}";
        };

        oidc = {
          issuer = "https://${cfg.keycloakFqdn}/realms/${cfg.oidcRealm}";
          client_id = cfg.oidcClientId;
          client_secret_path = "/run/secrets/headscale-oidc-secret";
          redirect_uri = "https://${cfg.headscaleFqdn}/admin/oidc/callback";
          headscale_api_key_path = "/run/secrets/headplane-api-key";
          disable_api_key_login = true;
        };

        integration = {
          # Use proc integration (reads headscale state from process)
          proc.enabled = true;
          # Enable agent integration for node info display
          agent = {
            enabled = true;
            pre_authkey_path = "/run/secrets/headplane-agent-preauth";
            host_name = "headplane-agent";
          };
        };
      };
    };

    # Trigger ACME certificate renewal shortly after boot
    # NixOS ACME generates a self-signed minica cert at boot so nginx can start,
    # then relies on a timer (randomized, up to 24h) for the real Let's Encrypt cert.
    # This service triggers the real ACME challenge 30s after nginx starts.
    systemd.services.acme-boot-renew = {
      description = "Trigger ACME certificate renewal after boot";
      after = [ "nginx.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "nginx.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 30";
        ExecStart = "${pkgs.systemd}/bin/systemctl --no-block start acme-order-renew-${cfg.headscaleFqdn}.service";
      };
    };

    # Headscale needs secrets-init to create OIDC secret before starting
    # Also wait for network-online since secrets-init fetches from OCI Vault
    systemd.services.headscale = {
      after = [ "network-online.target" "secrets-init.service" ];
      wants = [ "network-online.target" ];
      requires = [ "secrets-init.service" ];
    };

    # Headplane depends on headscale-api-key-init for API key
    systemd.services.headplane = {
      after = [ "network-online.target" "secrets-init.service" "headscale.service" "headscale-api-key-init.service" ];
      wants = [ "network-online.target" ];
      requires = [ "secrets-init.service" "headscale-api-key-init.service" ];
    };

    # Generate Headplane API key and agent pre-auth key after Headscale starts
    # For manual setup, create /var/lib/headscale/headplane-api-key with your API key
    systemd.services.headscale-api-key-init = {
      description = "Generate API key and pre-auth key for Headplane";
      after = [ "headscale.service" ];
      requires = [ "headscale.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.headscale pkgs.curl ];
      script = ''
        set -euo pipefail

        # Restore a key from persistent storage, or return 1 to signal generation needed
        restore_key() {
          local name="$1"
          if [ -f "/var/lib/headscale/$name" ]; then
            cp "/var/lib/headscale/$name" "/run/secrets/$name"
            echo "Restored $name from persistent storage"
            return 0
          fi
          return 1
        }

        # Save a key to both runtime and persistent storage
        save_key() {
          local name="$1" value="$2"
          for path in "/run/secrets/$name" "/var/lib/headscale/$name"; do
            echo "$value" > "$path"
            chmod 600 "$path"
            chown headscale:headscale "$path"
          done
        }

        # Wait for Headscale to be ready
        echo "Waiting for Headscale to be ready..."
        for i in $(seq 1 30); do
          if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
            echo "Headscale is ready"
            break
          fi
          sleep 2
        done

        # API key for Headplane to manage Headscale
        if ! restore_key "headplane-api-key"; then
          echo "Generating Headplane API key..."
          KEY=$(headscale apikeys create --expiration 365d 2>/dev/null | tail -1)
          [ -n "$KEY" ] || { echo "ERROR: Failed to generate API key"; exit 1; }
          save_key "headplane-api-key" "$KEY"
          echo "Generated headplane-api-key"
        fi

        # Pre-auth key for Headplane agent to join tailnet
        if ! restore_key "headplane-agent-preauth"; then
          headscale users create headplane 2>/dev/null || true

          USER_ID=$(headscale users list -o json | ${pkgs.jq}/bin/jq -r '.[] | select(.name == "headplane") | .id')
          [ -n "$USER_ID" ] || { echo "ERROR: Could not find headplane user ID"; exit 1; }

          echo "Generating pre-auth key for headplane agent..."
          PREAUTH_JSON=$(headscale preauthkeys create --user "$USER_ID" --reusable --expiration 8760h -o json 2>&1)
          KEY=$(echo "$PREAUTH_JSON" | ${pkgs.jq}/bin/jq -r '.key // empty' 2>/dev/null || true)
          [ -n "$KEY" ] || { echo "ERROR: Failed to generate pre-auth key"; exit 1; }
          save_key "headplane-agent-preauth" "$KEY"
          echo "Generated headplane-agent-preauth"
        fi

        echo "Headplane initialization complete"
      '';
    };

    # ===========================================================================
    # DERP Map Configuration
    # ===========================================================================
    environment.etc."headscale/derp.yaml" = {
      mode = "0644";
      text = ''
        # Custom DERP servers
        regions:
          ${toString cfg.derpRegionId}:
            regionid: ${toString cfg.derpRegionId}
            regioncode: ${cfg.derpRegionCode}-east
            regionname: OCI Ashburn
            nodes:
              - name: derp-east
                regionid: ${toString cfg.derpRegionId}
                hostname: ${cfg.derpEastFqdn}
                stunport: 3478
                stunonly: false
                derpport: 443
      '' + lib.optionalString cfg.enableSecondaryRegion ''
          ${toString (cfg.derpRegionId + 1)}:
            regionid: ${toString (cfg.derpRegionId + 1)}
            regioncode: ${cfg.derpRegionCode}-west
            regionname: OCI Phoenix
            nodes:
              - name: derp-west
                regionid: ${toString (cfg.derpRegionId + 1)}
                hostname: ${cfg.derpWestFqdn}
                stunport: 3478
                stunonly: false
                derpport: 443
      '';
    };

    # ===========================================================================
    # Block Volume (for persistent Headscale data)
    # ===========================================================================
    headscale-deployment.blockVolume = {
      enable = true;
      label = "headscale-data";
      mountPoint = "/var/lib/headscale";
    };

    # ===========================================================================
    # Secrets Initialization (fetch from OCI Vault)
    # ===========================================================================
    systemd.services.secrets-init = {
      description = "Fetch headscale and headplane secrets from OCI Vault";
      wantedBy = [ "multi-user.target" ];
      before = [ "headscale.service" "headplane.service" ];
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

        fetch_secret headscale_db_secret_id     /run/secrets/headscale-db-password    headscale:headscale
        fetch_secret headscale_oidc_secret_id   /run/secrets/headscale-oidc-secret    headscale:headscale
        fetch_secret headplane_cookie_secret_id /run/secrets/headplane-cookie-secret  headscale:headscale

        echo "Secrets initialization complete"
      '';
    };

    # ===========================================================================
    # Health Check Scripts
    # ===========================================================================
    environment.systemPackages = with pkgs; [
      (writeShellScriptBin "headscale-health" ''
        #!/bin/bash
        curl -sf http://localhost:8080/health || exit 1
        echo "Headscale is healthy"
      '')
      (writeShellScriptBin "headscale-status" ''
        #!/bin/bash
        echo "=== Headscale Service Status ==="
        systemctl status headscale
        echo ""
        echo "=== Recent Logs ==="
        journalctl -u headscale -n 20 --no-pager
      '')
    ];

  };
}
