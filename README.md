# Headscale Deployment

Self-hosted [Headscale](https://github.com/juanfont/headscale) (Tailscale control plane) on OCI with [Keycloak](https://www.keycloak.org/) OIDC authentication, [Headplane](https://headplane.net/) admin UI, and custom DERP relay servers.

All VMs run NixOS with native services (no containers). Images are built with Nix and deployed to OCI as custom images.

> **Note:** This repository reflects a specific deployment for a specific environment. It is not a turnkey solution. Every use case has different needs - different cloud providers, instance shapes, DNS setups, and security requirements. Review the flake inputs, NixOS modules, and Terraform modules carefully. Remove what you don't need, add what you do, and adapt the configuration to fit your infrastructure.

## Architecture

```
        ┌─────────┐          ┌──────────┐          ┌──────────┐
        │Headscale│   DB     │ Keycloak │          │   DERP   │
        │  + UI   │◄────────►│+ Postgres|          │  + Exit  │
        └─────────┘          └──────────┘          └──────────┘
```

- **Headscale** - Control plane + Headplane admin UI (nginx, ACME TLS)
- **Keycloak** - OIDC identity provider + PostgreSQL (serves both Keycloak and Headscale databases)
- **DERP** - Tailscale relay for NAT traversal + optional exit node (one or two regions)

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled
- OCI account with compute instances and a vault for secrets

## Quick Start

**1. Clone and enter the dev shell:**

```sh
git clone <repo-url> && cd headscale-deployment
nix develop
```

**2. Create your deployment config:**

```sh
cp nix/deployment-config.json.example nix/deployment-config.json
```

Edit `deployment-config.json` with your domain, email, IPs, etc. See [docs/NIXOS.md](docs/NIXOS.md) for all options.

**3. Provision infrastructure with Terraform/OpenTofu:**

```sh
cp infra/terraform/environments/prod/terraform.tfvars.example \
   infra/terraform/environments/prod/terraform.tfvars
# Edit terraform.tfvars, then:
cd infra/terraform/environments/prod
tofu init
tofu plan -out dev.tfplan
tofu apply dev.tfplan
```

**4. Build and deploy NixOS images:**

```sh
# Build all images, upload to OCI Object Storage, and import as custom images:
cd tools/oci-image-builder
go build -o oci-image-builder ./
# From deploy root
./tools/oci-image-builder/oci-image-builder all

# Or build individual images with nix directly:
nix build .#oci-headscale-image
nix build .#oci-keycloak-image
nix build .#oci-derp-east-image
```

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the full deployment walkthrough.

## Repository Layout

```
nix/
  hosts/              Per-host NixOS configurations (headscale, keycloak, derp)
  modules/            Reusable modules (security, nginx rate limiting, OCI base, etc.)
  lib/                Shared shell helpers (secret fetching)
  deployment-config.json   Your deployment values (not checked in)
infra/terraform/      OCI infrastructure (network, compute, vault) + DNS
tools/oci-image-builder/   CLI to build, upload, and import NixOS images to OCI
docs/                 Deployment guide and NixOS configuration reference
```

## Available Images

| Flake output | Host | Description |
|---|---|---|
| `oci-headscale-image` | headscale | Headscale + Headplane + nginx |
| `oci-keycloak-image` | keycloak | Keycloak + PostgreSQL + nginx |
| `oci-derp-east-image` | derp-east | DERP relay + Tailscale exit node |
| `oci-derp-west-image` | derp-west | Optional second DERP region |

## Further Reading

- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) - Deployment walkthrough
- [docs/NIXOS.md](docs/NIXOS.md) - NixOS modules and configuration reference