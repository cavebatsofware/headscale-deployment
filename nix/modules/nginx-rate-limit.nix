# =============================================================================
# Nginx Rate Limiting Module
# =============================================================================
# Shared rate limiting configuration for nginx virtual hosts.
# Whitelists internal networks (VCN, Tailscale, localhost) from rate limiting
# and creates a named rate limit zone.
#
# Usage in host configs:
#
#   imports = [ ../modules/nginx-rate-limit.nix ];
#
#   headscale-deployment.nginx.rateLimit = {
#     enable = true;
#     zoneName = "headscale";  # or "keycloak"
#   };
#
# Then in nginx location blocks:
#   limit_req zone=headscale burst=50 nodelay;
#   limit_req_status 429;
# =============================================================================

{ config, lib, ... }:

let
  cfg = config.headscale-deployment.nginx.rateLimit;

  whitelistEntries = lib.concatMapStringsSep "\n        "
    (cidr: "${cidr} 1;  # ${
      if cidr == "127.0.0.1" then "Localhost"
      else if lib.hasPrefix "10." cidr then "VCN internal network"
      else if lib.hasPrefix "100.64." cidr then "Tailscale CGNAT range"
      else "Custom"
    }")
    cfg.whitelistCidrs;
in
{
  options.headscale-deployment.nginx.rateLimit = {
    enable = lib.mkEnableOption "nginx rate limiting with internal network whitelist";

    zoneName = lib.mkOption {
      type = lib.types.str;
      description = "Name for the nginx rate limit zone (e.g., 'headscale', 'keycloak')";
    };

    rate = lib.mkOption {
      type = lib.types.str;
      default = "10r/s";
      description = "Request rate limit per IP";
    };

    sharedMemory = lib.mkOption {
      type = lib.types.str;
      default = "10m";
      description = "Shared memory size for rate limit zone";
    };

    whitelistCidrs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/16"
        "100.64.0.0/10"
        "127.0.0.1"
      ];
      description = "CIDRs exempt from rate limiting (VCN, Tailscale, localhost by default)";
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx.appendHttpConfig = ''
      # Whitelist internal networks from rate limiting
      geo $rate_limit_exempt {
        default 0;
        ${whitelistEntries}
      }

      # Map exempt status to rate limit key (empty key = no rate limiting)
      map $rate_limit_exempt $limit_key {
        0 $binary_remote_addr;
        1 "";
      }

      # Rate limit zone: ${cfg.zoneName} (${cfg.sharedMemory} shared memory, ${cfg.rate})
      limit_req_zone $limit_key zone=${cfg.zoneName}:${cfg.sharedMemory} rate=${cfg.rate};
    '';
  };
}
