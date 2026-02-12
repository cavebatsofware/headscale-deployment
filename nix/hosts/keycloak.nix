# =============================================================================
# Keycloak + PostgreSQL Host Configuration
# =============================================================================
# NixOS configuration for Keycloak identity provider and PostgreSQL database.
# Runs on OCI E4.Flex (AMD64) in the public subnet.
#
# Uses native NixOS services (no containers).
#
# Services:
# - Keycloak (v26.5.0) - OIDC identity provider
# - PostgreSQL - Database for Keycloak and Headscale
# - nginx - Reverse proxy with automatic TLS via ACME
#
# Ports:
# - 443/TCP  - HTTPS (nginx -> Keycloak)
# - 80/TCP   - HTTP (ACME challenges, redirects to HTTPS)
# - 5432/TCP - PostgreSQL (VCN internal only, not public)
# - 22/TCP   - SSH (restricted)
#
# References:
# - https://wiki.nixos.org/wiki/Keycloak
# - https://mynixos.com/nixpkgs/options/services.keycloak
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.headscale-deployment.config;
  postgresql = pkgs.postgresql_16;

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
    networking.hostName = "keycloak";

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
      zoneName = "keycloak";
    };

    # ===========================================================================
    # Firewall - Keycloak specific ports
    # ===========================================================================
    networking.firewall = {
      allowedTCPPorts = [
        80   # HTTP (ACME + redirect)
        443  # HTTPS
      ];

      # PostgreSQL only from VCN (headscale VM)
      # Must use nixos-fw chain (not INPUT) because NixOS firewall processes
      # packets in nixos-fw and rejects non-allowed ports before INPUT rules.
      extraCommands = ''
        # Create custom chain for PostgreSQL filtering
        iptables -N nixos-fw-pgsql 2>/dev/null || iptables -F nixos-fw-pgsql

        # Allow PostgreSQL from VCN
        iptables -A nixos-fw-pgsql -s ${cfg.vcnCidr} -j ACCEPT

        # Drop PostgreSQL from everywhere else
        iptables -A nixos-fw-pgsql -j DROP

        # Insert jump to PostgreSQL chain at top of nixos-fw for port 5432
        iptables -I nixos-fw -p tcp --dport 5432 -j nixos-fw-pgsql
      '';

      extraStopCommands = ''
        iptables -D nixos-fw -p tcp --dport 5432 -j nixos-fw-pgsql 2>/dev/null || true
        iptables -F nixos-fw-pgsql 2>/dev/null || true
        iptables -X nixos-fw-pgsql 2>/dev/null || true
      '';
    };

    # ===========================================================================
    # Nginx Reverse Proxy
    # ===========================================================================
    # Using raw nginx config for Keycloak-specific rate limits (10r/s, burst=50)

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

      virtualHosts."${cfg.keycloakFqdn}" = {
        forceSSL = true;
        enableACME = true;

        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          extraConfig = ''
            limit_req zone=keycloak burst=50 nodelay;
            limit_req_status 429;
          '';
        };
      };
    };

    # ===========================================================================
    # PostgreSQL Database
    # ===========================================================================
    services.postgresql = {
      enable = true;
      package = postgresql;

      # Listen on all interfaces for VCN access
      enableTCPIP = true;

      # Data directory on block volume
      dataDir = "/var/lib/postgresql/16";

      # Authentication - allow VCN access
      authentication = lib.mkForce ''
        # Local unix socket connections (peer auth)
        local   all             all                                     peer
        # IPv4 localhost - no SSL needed for local connections
        hostnossl  all          all             127.0.0.1/32            scram-sha-256
        # IPv6 localhost - no SSL needed for local connections
        hostnossl  all          all             ::1/128                 scram-sha-256
        # VCN access (headscale VM) - TODO: require SSL (hostssl) once certs configured
        host    ${cfg.headscaleDbName}  ${cfg.headscaleDbUser}  ${cfg.vcnCidr}  scram-sha-256
      '';

      # Create databases
      ensureDatabases = [ "keycloak" cfg.headscaleDbName ];

      # Create users
      ensureUsers = [
        {
          name = "keycloak";
          ensureDBOwnership = true;
        }
        {
          name = cfg.headscaleDbUser;
          ensureDBOwnership = true;
        }
      ];

      # PostgreSQL settings
      settings = {
        # Connection settings
        listen_addresses = "*";
        port = cfg.postgresPort;
        max_connections = 100;

        # Memory settings (for 4GB VM)
        shared_buffers = "512MB";
        effective_cache_size = "2GB";
        work_mem = "16MB";
        maintenance_work_mem = "128MB";

        # WAL settings
        wal_buffers = "16MB";
        min_wal_size = "1GB";
        max_wal_size = "2GB";

        # Logging - store on block volume with data
        log_destination = "stderr";
        logging_collector = true;
        log_directory = "/var/lib/postgresql/logs";
        log_filename = "postgresql-%Y-%m-%d.log";
        log_rotation_age = "1d";
        log_rotation_size = "100MB";

        # Performance
        random_page_cost = 1.1; # SSD storage
        effective_io_concurrency = 200;
      };
    };

    # Create PostgreSQL log directory on block volume
    systemd.tmpfiles.rules = [
      "d /var/lib/postgresql/logs 0750 postgres postgres -"
    ];

    # ===========================================================================
    # Keycloak Service (Native NixOS)
    # ===========================================================================
    services.keycloak = {
      enable = true;

      # Use Unix socket with peer authentication (no password needed)
      # Per NixOS docs: https://nixos.org/manual/nixos/stable/index.html#module-services-keycloak
      database = {
        type = "postgresql";
        createLocally = false; # We manage PostgreSQL ourselves
        host = "/run/postgresql";  # Unix socket directory for peer auth
        name = "keycloak";
        username = "keycloak";
        # No passwordFile needed - peer auth authenticates via system user
      };

      # Required plugins for Unix socket support
      plugins = with pkgs.keycloak.plugins; [
        junixsocket-common
        junixsocket-native-common
      ];

      settings = {
        # Hostname configuration
        hostname = cfg.keycloakFqdn;
        hostname-strict = true;
        hostname-strict-https = true;

        # Disable clustering - single instance deployment
        # This prevents Infinispan from listening on ports 7800/57800
        cache = "local";

        # HTTP settings (behind nginx proxy)
        http-enabled = true;
        http-host = "127.0.0.1";
        http-port = 8080;

        # Proxy configuration (nginx terminates TLS)
        proxy-headers = "xforwarded";
        http-relative-path = "/";

        # HTTPS disabled (nginx handles TLS termination)
        https-port = 8443;

        # Health endpoints
        health-enabled = true;
        metrics-enabled = true;

        # Logging
        log-level = "INFO";
        log-format = "default";
      };

      # Don't set initialAdminPassword here - we'll use environment variable
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
        ExecStart = "${pkgs.systemd}/bin/systemctl --no-block start acme-order-renew-${cfg.keycloakFqdn}.service";
      };
    };

    # Keycloak uses Unix socket peer auth for database (no password needed)
    # Admin password is loaded from OCI Vault secret via environment variable
    systemd.services.keycloak = {
      after = [ "postgresql.service" "secrets-init.service" ];
      requires = [ "postgresql.service" "secrets-init.service" ];
      serviceConfig = {
        # Load admin password from secrets file into environment
        EnvironmentFile = "/run/secrets/keycloak-admin-env";
      };
    };

    # ===========================================================================
    # Block Volume (for persistent PostgreSQL data)
    # ===========================================================================
    headscale-deployment.blockVolume = {
      enable = true;
      label = "keycloak-data";
      mountPoint = "/var/lib/postgresql";
    };

    # ===========================================================================
    # Secrets Initialization (fetch from OCI Vault)
    # ===========================================================================
    systemd.services.secrets-init = {
      description = "Fetch database secrets from OCI Vault";
      wantedBy = [ "multi-user.target" ];
      before = [ "postgresql.service" "keycloak.service" ];
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

        fetch_secret headscale_db_secret_id /run/secrets/headscale-db-password root:postgres 0640

        # Keycloak admin password as systemd EnvironmentFile
        fetch_secret keycloak_admin_secret_id /run/secrets/keycloak-admin-raw root:root
        if [ -f /run/secrets/keycloak-admin-raw ]; then
          ADMIN_PASS=$(cat /run/secrets/keycloak-admin-raw)
          echo "KC_BOOTSTRAP_ADMIN_USERNAME=admin" > /run/secrets/keycloak-admin-env
          echo "KC_BOOTSTRAP_ADMIN_PASSWORD=$ADMIN_PASS" >> /run/secrets/keycloak-admin-env
          chmod 600 /run/secrets/keycloak-admin-env
          rm /run/secrets/keycloak-admin-raw
        fi

        echo "Secrets initialization complete"
      '';
    };

    # ===========================================================================
    # Database Password Setup (Headscale only)
    # ===========================================================================
    # Keycloak uses Unix socket peer auth (no password needed).
    # Headscale connects over TCP from another VM, so needs a password.
    systemd.services.postgresql-password-setup = {
      description = "Set PostgreSQL user passwords for remote access";
      after = [ "postgresql.service" "secrets-init.service" ];
      requires = [ "postgresql.service" "secrets-init.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        # Re-run when secrets-init restarts (e.g., after vault secret update)
        PartOf = [ "secrets-init.service" ];
      };
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
      };
      script = ''
        # Wait for PostgreSQL to be ready
        until ${postgresql}/bin/pg_isready -q; do
          sleep 1
        done

        # Set headscale password (needed for TCP connections from VCN)
        # Use head -n1 to match how NixOS headscale module reads the password file
        if [ -f /run/secrets/headscale-db-password ]; then
          HS_PASS=$(head -n1 /run/secrets/headscale-db-password)
          ${postgresql}/bin/psql -c "ALTER USER ${cfg.headscaleDbUser} WITH PASSWORD '$HS_PASS';"
          echo "Headscale database password configured"
        else
          echo "ERROR: /run/secrets/headscale-db-password not found - secrets-init may have failed"
          exit 1
        fi
      '';
    };

    # ===========================================================================
    # Health Check Scripts
    # ===========================================================================
    environment.systemPackages = with pkgs; [
      (writeShellScriptBin "keycloak-health" ''
        #!/bin/bash
        curl -sf http://localhost:8080/health/ready || exit 1
        echo "Keycloak is healthy"
      '')
      (writeShellScriptBin "postgres-health" ''
        #!/bin/bash
        sudo -u postgres ${postgresql}/bin/pg_isready || exit 1
        echo "PostgreSQL is healthy"
      '')
      (writeShellScriptBin "service-status" ''
        #!/bin/bash
        echo "=== PostgreSQL Status ==="
        systemctl status postgresql
        echo ""
        echo "=== Keycloak Status ==="
        systemctl status keycloak
        echo ""
        echo "=== Recent Keycloak Logs ==="
        journalctl -u keycloak -n 20 --no-pager
      '')
    ];

  };
}
