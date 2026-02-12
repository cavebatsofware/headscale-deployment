# NixOS Configuration Reference

## Deployment Config Options

This is a detailed description of all major deployment resources/services, configuration options, and default service configurations. 

All hosts share a central config defined in `nix/modules/deployment-config.nix`. Values are loaded from `nix/deployment-config.json` at evaluation time.

### Required

| Option               | Description                              |
|----------------------|------------------------------------------|
| `domain`             | Base domain (e.g., `example.com`)        |
| `acmeEmail`          | Email for Let's Encrypt registration     |
| `keycloakPrivateIP`  | Private IP of the Keycloak/PostgreSQL VM |

### Optional (with defaults)

| Option                  | Default                 | Description                      |
|-------------------------|-------------------------|----------------------------------|
| `headscaleFqdn`         | `headscale.${domain}`   | Headscale FQDN                   |
| `keycloakFqdn`          | `keycloak.${domain}`    | Keycloak FQDN                    |
| `derpEastFqdn`          | `derp-east.${domain}`   | DERP East FQDN                   |
| `derpWestFqdn`          | `derp-west.${domain}`   | DERP West FQDN                   |
| `tailnetDomain`         | `tail.${domain}`        | Magic DNS base domain            |
| `adminIP`               | `1.2.3.4`               | SSH allowlist IP                 |
| `vcnCidr`               | `10.0.0.0/16`           | Internal network CIDR            |
| `oidcClientId`          | `headscale`             | Keycloak OIDC client ID          |
| `oidcRealm`             | `headscale`             | Keycloak realm name              |
| `postgresPort`          | `5432`                  | PostgreSQL port                  |
| `headscaleDbName`       | `headscale`             | Headscale database name          |
| `headscaleDbUser`       | `headscale`             | Headscale database user          |
| `derpRegionId`          | `900`                   | Custom DERP region ID            |
| `derpRegionCode`        | `oci`                   | DERP region code prefix          |
| `enableSecondaryRegion` | `false`                 | Enable DERP West                 |
| `enableIPAllowlist`     | `true`                  | Restrict SSH to `adminIP`        |

## Host Configurations

Each host is in `nix/hosts/` and imports the shared modules it needs.

### headscale.nix

Headscale control plane + Headplane admin UI.

- **nginx** reverse proxy with ACME TLS
  - `/` proxies to Headscale (port 8080) with WebSocket support
  - `/admin` proxies to Headplane (port 3000)
  - `/api/` returns 403 (management API blocked from public access; Headplane connects directly to localhost)
- **Headscale** - bound to 127.0.0.1:8080, gRPC on 0.0.0.0:50443
- **Headplane** - bound to 127.0.0.1:3000, OIDC auth via Keycloak
- **secrets-init** - fetches DB password, OIDC secret, and Headplane cookie secret from OCI Vault
- **headscale-api-key-init** - generates/restores Headplane API key and agent pre-auth key
- **Block volume** mounted at `/var/lib/headscale`

### keycloak.nix

Keycloak identity provider + PostgreSQL.

- **nginx** reverse proxy with ACME TLS, proxies to Keycloak (port 8080)
- **PostgreSQL 16** - listens on all interfaces, VCN-only access for Headscale DB, Unix socket peer auth for Keycloak
- **Keycloak** - OIDC provider, connects to PostgreSQL via Unix socket (no password)
- **secrets-init** - fetches Headscale DB password and Keycloak admin credentials from OCI Vault
- **postgresql-password-setup** - sets the Headscale DB user password for remote TCP access
- **Firewall** - port 5432 allowed from VCN only (custom iptables chain)
- **Block volume** mounted at `/var/lib/postgresql`

### derp.nix

DERP relay server + optional Tailscale exit node.

- **derper** - Tailscale DERP relay with built-in Let's Encrypt (no nginx, handles its own TLS)
- **Tailscale client** - joins the tailnet as an exit node
- **secrets-init** - fetches pre-auth key from OCI Vault (skipped if Tailscale is already registered)
- **DERP-specific options** - `hostname`, `regionName`, `regionCode` (set per-instance in `flake.nix`)

## Shared Modules

### security.nix

`headscale-deployment.security`

- SSH hardened: key-only auth, no root password login, admin IP allowlist (optional)
- fail2ban with SSH jail
- Automatic security updates with configurable reboot window
- Tailscale CGNAT range allowed for SSH as fallback

### nginx-rate-limit.nix

`headscale-deployment.nginx.rateLimit`

- Rate limit zone with configurable rate (default: 10r/s)
- Internal networks (VCN, Tailscale, localhost) whitelisted from rate limiting

### oci-base.nix

Base OCI VM configuration: GRUB boot, cloud-init, serial console, NTP, and common system packages.

### oci-hardware.nix

Hardware configuration for OCI QCOW2 images: filesystem layout and kernel modules. This is only needed for nixos-rebuild switch remote deployments.

### oci-block-volume.nix

`headscale-deployment.blockVolume`

Auto-detects and formats an uninitialized OCI block volume on first boot, then mounts by filesystem label on subsequent boots.

## Secrets

All VMs fetch secrets at boot from OCI Vault using instance principal authentication. The shared function in `nix/lib/fetch-secret.sh` handles the fetch lifecycle:

1. Skip if the secret file already exists
2. Get the secret OCID from OCI instance metadata
3. Fetch and base64-decode the secret from OCI Vault
4. Write with specified ownership and permissions

Secret files are written to `/run/secrets/` (tmpfs, cleared on reboot).