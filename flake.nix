{
  description = "NixOS on Oracle Cloud Infrastructure - Free Tier ARM deployment";

  inputs = {
    # Using nixpkgs master. Note: PR #480105 adds oci.copyChannel option which
    # can reduce image size by ~300-400MB when merged. Once merged, you can
    # enable it in oci-hardware.nix to skip copying the nixpkgs channel.
    nixpkgs.url = "github:nixos/nixpkgs/master";
  };

  outputs = { self, nixpkgs }:
    let
      # Support both x86_64-linux (for local dev/terraform) and aarch64-linux (for OCI ARM)
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      # Reusable NixOS module for OCI ARM hardware support
      # Use this in your own NixOS configurations for OCI deployment
      nixosModules.oci-hardware = ./modules/oci-hardware.nix;

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          # Cleanup old OCI custom images (keep max 3)
          cleanup-images = pkgs.writeShellApplication {
            name = "cleanup-images";
            runtimeInputs = with pkgs; [ oci-cli jq coreutils ];
            text = builtins.readFile ./scripts/cleanup-images.sh;
          };

          # Generic OCI base image - vanilla NixOS with OCI hardware support
          # No application config - SSH keys come from OCI instance metadata
          oci-base-image = let
            nixos = nixpkgs.lib.nixosSystem {
              # Always build for aarch64-linux (OCI ARM free tier)
              system = "aarch64-linux";
              modules = [
                # OCI image module from nixpkgs (includes fetch-ssh-keys service)
                "${nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
                "${nixpkgs}/nixos/modules/virtualisation/oci-options.nix"
                # OCI ARM hardware support (iSCSI boot, Mellanox drivers)
                ./modules/oci-hardware.nix
                ({ config, lib, pkgs, ... }: {
                  system.stateVersion = "25.11";
                  networking.hostName = "nixos-oci";

                  # Disable documentation to reduce image size
                  documentation.enable = false;

                  # Enable flakes and nix-command
                  nix.settings.experimental-features = [ "nix-command" "flakes" ];

                  # Minimal packages for administration
                  environment.systemPackages = with pkgs; [
                    vim
                    git
                    htop
                  ];
                })
              ];
            };
          in nixos.config.system.build.OCIImage;
        }
      );

      apps = forAllSystems (system: {
        cleanup-images = {
          type = "app";
          program = "${self.packages.${system}.cleanup-images}/bin/cleanup-images";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          pkgsWithTerraform = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [
              "terraform"
            ];
          };
          # Wrapper so terraform always targets the terraform/ directory
          # Uses FLAKE_ROOT env var which is set by direnv at runtime
          terraformWrapper = pkgs.writeShellScriptBin "terraform" ''
            if [ -z "$FLAKE_ROOT" ]; then
              echo "error: FLAKE_ROOT not set. Are you in the devShell?" >&2
              exit 1
            fi
            exec ${pkgsWithTerraform.terraform}/bin/terraform -chdir="$FLAKE_ROOT/terraform" "$@"
          '';
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              direnv
              oci-cli
              openssl
              terraformWrapper
            ];

            shellHook = ''
              # Source .env file if it exists (for TF_VAR_* variables)
              if [ -f .env ]; then
                set -a
                source .env
                set +a
              fi
            '';
          };
        }
      );
    };
}
