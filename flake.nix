{
  description = "Headscale Deployment - Infrastructure and NixOS Configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # For building OCI-compatible images
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Headplane - Admin UI for Headscale
    headplane = {
      url = "github:tale/headplane/v0.6.2-beta.4";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      nixos-generators,
      headplane,
      ...
    }@inputs:
    let
      # Supported systems for dev shell
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Helper to generate attrs for each system
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # ===========================================================================
      # Deployment Configuration
      # ===========================================================================
      # Values loaded from nix/deployment-config.json
      # Update that file with your domain, email, IPs, etc.
      deploymentConfig = builtins.fromJSON (builtins.readFile ./nix/deployment-config.json);

      # ===========================================================================
      # NixOS Module for deployment config injection
      # ===========================================================================
      deploymentConfigModule =
        { lib, ... }:
        {
          headscale-deployment.config = {
            domain = deploymentConfig.domain;
            acmeEmail = deploymentConfig.acmeEmail;
            adminIP = deploymentConfig.adminIP;
            vcnCidr = deploymentConfig.vcnCidr;
            keycloakPrivateIP = deploymentConfig.keycloakPrivateIP;
            enableSecondaryRegion = deploymentConfig.enableSecondaryRegion;
            enableIPAllowlist = deploymentConfig.enableIPAllowlist;
          };
        };

    in
    {
      # ===========================================================================
      # Formatter
      # ===========================================================================
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      # ===========================================================================
      # NixOS Configurations
      # ===========================================================================
      nixosConfigurations = {
        # Headscale control plane (AMD64 - E2.1.Micro)
        headscale = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/modules/oci-hardware.nix
            ./nix/hosts/headscale.nix
            headplane.nixosModules.headplane
            deploymentConfigModule
            # Add headplane packages to pkgs via overlay
            {
              nixpkgs.overlays = [ headplane.overlays.default ];
            }
          ];
        };

        # Keycloak + PostgreSQL (AMD64 - E4.Flex)
        keycloak = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/modules/oci-hardware.nix
            ./nix/hosts/keycloak.nix
            deploymentConfigModule
          ];
        };

        # DERP East (AMD64 - E2.1.Micro)
        derp-east = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/modules/oci-hardware.nix
            ./nix/hosts/derp.nix
            deploymentConfigModule
            {
              networking.hostName = "derp-east";
              headscale-deployment.derp = {
                hostname = "derp-east.${deploymentConfig.domain}";
                regionName = "OCI Ashburn";
                regionCode = "oci-east";
              };
            }
          ];
        };

        # DERP West (AMD64 - E2.1.Micro) - Optional secondary region
        derp-west = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/modules/oci-hardware.nix
            ./nix/hosts/derp.nix
            deploymentConfigModule
            {
              networking.hostName = "derp-west";
              headscale-deployment.derp = {
                hostname = "derp-west.${deploymentConfig.domain}";
                regionName = "OCI Phoenix";
                regionCode = "oci-west";
              };
            }
          ];
        };
      };

      # ===========================================================================
      # OCI Image Builds (via nixos-generators)
      # ===========================================================================
      # Build with: nix build .#oci-headscale-image
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # AMD64 image for Headscale (E2.1.Micro)
          oci-headscale-image = nixos-generators.nixosGenerate {
            system = "x86_64-linux";
            format = "qcow"; # OCI x86_64 uses BIOS boot
            modules = [
              ./nix/hosts/headscale.nix
              headplane.nixosModules.headplane
              deploymentConfigModule
              {
                nixpkgs.overlays = [ headplane.overlays.default ];
              }
            ];
          };

          # AMD64 image for Keycloak (E4.Flex)
          oci-keycloak-image = nixos-generators.nixosGenerate {
            system = "x86_64-linux";
            format = "qcow"; # OCI x86_64 uses BIOS boot
            modules = [
              ./nix/hosts/keycloak.nix
              deploymentConfigModule
            ];
          };

          # AMD64 image for DERP East (E2.1.Micro)
          oci-derp-east-image = nixos-generators.nixosGenerate {
            system = "x86_64-linux";
            format = "qcow"; # OCI x86_64 uses BIOS boot
            modules = [
              ./nix/hosts/derp.nix
              deploymentConfigModule
              {
                networking.hostName = "derp-east";
                headscale-deployment.derp = {
                  hostname = "derp-east.${deploymentConfig.domain}";
                  regionName = "OCI Ashburn";
                  regionCode = "oci-east";
                };
              }
            ];
          };

          # AMD64 image for DERP West (E2.1.Micro)
          oci-derp-west-image = nixos-generators.nixosGenerate {
            system = "x86_64-linux";
            format = "qcow"; # OCI x86_64 uses BIOS boot
            modules = [
              ./nix/hosts/derp.nix
              deploymentConfigModule
              {
                networking.hostName = "derp-west";
                headscale-deployment.derp = {
                  hostname = "derp-west.${deploymentConfig.domain}";
                  regionName = "OCI Phoenix";
                  regionCode = "oci-west";
                };
              }
            ];
          };
        }
      );

      # ===========================================================================
      # Development Shell
      # ===========================================================================
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            name = "headscale-deployment";

            buildInputs = with pkgs; [
              # Shell
              zsh

              # Infrastructure as Code
              opentofu

              # Cloud CLIs
              awscli2
              oci-cli

              # JSON/YAML processing
              jq
              yq
              fx # Interactive JSON viewer

              # Network debugging
              curl
              wget
              dnsutils # dig, nslookup
              netcat-gnu
              nmap
              tcpdump
              whois
              mtr # Better traceroute
              iproute2 # ip command
              iftop # Network traffic monitor
              nethogs # Per-process network usage

              # SSH and security
              openssh
              gnupg
              sshpass # For automated SSH (use carefully)
              openssl # TLS debugging

              # File and text tools
              ripgrep
              fd
              bat # Better cat
              eza # Better ls
              tree
              file
              less
              watch
              htop
              hexdump # Hex viewer
              xxd # Hex dump/reverse

              # System debugging
              lsof # List open files
              strace # System call tracer
              ncdu # Disk usage analyzer
              pv # Pipe viewer (progress)
              psmisc # pstree, killall, fuser

              # Git tools
              git
              gh # GitHub CLI
              delta # Better git diff

              # Development tools
              pre-commit
              shellcheck
              nixpkgs-fmt # Nix formatter
              go # For building oci-image-builder

              # QEMU for local image testing
              qemu
              OVMF # UEFI firmware for QEMU

              # Misc utilities
              tmux
              direnv
              envsubst
              getopt
              unzip
              gzip
              pigz # Parallel gzip
            ];

            shellHook = ''
              # Set environment before potentially switching to zsh
              export OCI_CLI_CONFIG_FILE="''${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
              export HEADSCALE_DEV=1

              # Use zsh with user's config if available
              if [ -z "$ZSH_VERSION" ] && [ -z "$IN_NIX_SHELL_ZSH" ]; then
                if command -v zsh &> /dev/null; then
                  export IN_NIX_SHELL_ZSH=1
                  exec zsh -i
                fi
              fi

              # Welcome message (shows in zsh via .zshrc sourcing)
              if [ -n "$ZSH_VERSION" ]; then
                echo ""
                echo "╔══════════════════════════════════════════════════════════════╗"
                echo "║         Headscale Deployment Environment                     ║"
                echo "╠══════════════════════════════════════════════════════════════╣"
                echo "║  Infrastructure: tofu (tf), aws, oci                         ║"
                echo "║  Debugging:      dig, nmap, mtr, tcpdump, htop               ║"
                echo "║  Tools:          jq, yq, rg, fd, bat, eza                    ║"
                echo "╠══════════════════════════════════════════════════════════════╣"
                echo "║  Image builds:                                               ║"
                echo "║    nix build .#oci-headscale-image                           ║"
                echo "║    nix build .#oci-keycloak-image                            ║"
                echo "║    nix build .#oci-derp-east-image                           ║"
                echo "║                                                              ║"
                echo "║  Image builder:                                              ║"
                echo "║    ./tools/oci-image-builder/oci-image-builder all           ║"
                echo "╚══════════════════════════════════════════════════════════════╝"
                echo ""
              fi

              # Aliases (work in both bash and zsh)
              alias terraform=tofu
              alias tf=tofu
              alias tfa='tofu apply'
              alias tfp='tofu plan'
              alias tfd='tofu destroy'
              alias lsa='eza -la'
              alias lt='eza -laT'  # Tree view
              alias cat='bat --paging=never'
              alias grep='rg'
              alias find='fd'
            '';
          };
        }
      );
    };
}
