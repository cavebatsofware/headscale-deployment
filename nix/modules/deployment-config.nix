# =============================================================================
# Deployment Configuration Module
# =============================================================================
# Central configuration for deployment-specific values.
# Override these options in your deployment to set domains, IPs, etc.
#
# Usage in your deployment flake:
#
#   nixosConfigurations.headscale = nixpkgs.lib.nixosSystem {
#     modules = [
#       ./nix/hosts/headscale.nix
#       {
#         headscale-deployment.config = {
#           domain = "example.com";
#           headscaleFqdn = "headscale.example.com";
#           keycloakFqdn = "keycloak.example.com";
#           derpEastFqdn = "derp-east.example.com";
#           acmeEmail = "admin@example.com";
#           adminIP = "1.2.3.4";
#           keycloakPrivateIP = "10.0.1.10";
#         };
#       }
#     ];
#   };
# =============================================================================

{ config, lib, pkgs, ... }:

let
  cfg = config.headscale-deployment.config;
in
{
  options.headscale-deployment.config = {
    # =========================================================================
    # Domain Configuration
    # =========================================================================
    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = "Base domain for the deployment";
    };

    headscaleFqdn = lib.mkOption {
      type = lib.types.str;
      default = "headscale.${cfg.domain}";
      example = "headscale.example.com";
      description = "FQDN for the Headscale server";
    };

    keycloakFqdn = lib.mkOption {
      type = lib.types.str;
      default = "keycloak.${cfg.domain}";
      example = "keycloak.example.com";
      description = "FQDN for the Keycloak server";
    };

    derpEastFqdn = lib.mkOption {
      type = lib.types.str;
      default = "derp-east.${cfg.domain}";
      example = "derp-east.example.com";
      description = "FQDN for the DERP East server";
    };

    derpWestFqdn = lib.mkOption {
      type = lib.types.str;
      default = "derp-west.${cfg.domain}";
      example = "derp-west.example.com";
      description = "FQDN for the DERP West server (optional secondary region)";
    };

    tailnetDomain = lib.mkOption {
      type = lib.types.str;
      default = "tail.${cfg.domain}";
      example = "tail.example.com";
      description = "Base domain for Tailscale Magic DNS";
    };

    # =========================================================================
    # ACME / Let's Encrypt
    # =========================================================================
    acmeEmail = lib.mkOption {
      type = lib.types.str;
      example = "admin@example.com";
      description = "Email for Let's Encrypt certificate registration";
    };

    # =========================================================================
    # Network Configuration
    # =========================================================================
    adminIP = lib.mkOption {
      type = lib.types.str;
      default = "1.2.3.4";
      description = "Admin IP address for SSH allowlist";
    };

    vcnCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.0/16";
      description = "OCI VCN CIDR block for internal communication";
    };

    keycloakPrivateIP = lib.mkOption {
      type = lib.types.str;
      example = "10.0.1.10";
      description = "Private IP of the Keycloak/PostgreSQL VM (for DB connection)";
    };

    # =========================================================================
    # OIDC Configuration
    # =========================================================================
    oidcClientId = lib.mkOption {
      type = lib.types.str;
      default = "headscale";
      description = "OIDC client ID for Headscale in Keycloak";
    };

    oidcRealm = lib.mkOption {
      type = lib.types.str;
      default = "headscale";
      description = "Keycloak realm name for Headscale";
    };

    # =========================================================================
    # Database Configuration
    # =========================================================================
    postgresPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "PostgreSQL port";
    };

    headscaleDbName = lib.mkOption {
      type = lib.types.str;
      default = "headscale";
      description = "PostgreSQL database name for Headscale";
    };

    headscaleDbUser = lib.mkOption {
      type = lib.types.str;
      default = "headscale";
      description = "PostgreSQL user for Headscale";
    };

    # =========================================================================
    # DERP Configuration
    # =========================================================================
    derpRegionId = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = "Region ID for custom DERP servers";
    };

    derpRegionCode = lib.mkOption {
      type = lib.types.str;
      default = "oci";
      description = "Region code prefix for DERP servers";
    };

    # =========================================================================
    # Feature Flags
    # =========================================================================
    enableSecondaryRegion = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable secondary region (DERP West)";
    };

    enableIPAllowlist = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to restrict SSH to admin IP (disable after Tailscale bootstrap)";
    };
  };

  # No config block - this is just options definition
  # The actual usage happens in the host modules
}
