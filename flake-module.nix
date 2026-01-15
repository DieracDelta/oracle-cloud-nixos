# Flake module for oracle-cloud-nixos
#
# This module can be imported by end users to customize the package set
# and terraform version used by the devShell and packages.
#
# Usage in your flake.nix:
#
#   inputs.oracle-cloud-nixos.url = "github:johnrichardrinehart/oracle-cloud-nixos";
#
#   outputs = inputs@{ flake-parts, ... }:
#     flake-parts.lib.mkFlake { inherit inputs; } {
#       imports = [ inputs.oracle-cloud-nixos.flakeModule ];
#
#       perSystem = { ... }: {
#         oracle-cloud-nixos = {
#           # Use a custom nixpkgs
#           pkgs = import inputs.nixpkgs-custom { inherit system; };
#           # Use a specific terraform version
#           terraform = pkgs.terraform_1_5;
#         };
#       };
#     };
#
{
  self,
  inputs,
  lib,
  flake-parts-lib,
  ...
}:

let
  inherit (lib) mkOption types;
  inherit (flake-parts-lib) mkPerSystemOption;
in
{
  options = {
    flake.flakeModule = mkOption {
      type = types.deferredModule;
      description = "The flake module that can be imported by downstream flakes";
      readOnly = true;
    };

    perSystem = mkPerSystemOption (
      {
        config,
        system,
        pkgs,
        ...
      }:
      {
        options.oracle-cloud-nixos = {
          pkgs = mkOption {
            type = types.lazyAttrsOf types.raw;
            default = pkgs;
            defaultText = lib.literalExpression "pkgs";
            description = ''
              The nixpkgs package set to use for building packages and the devShell.
              Override this to use a custom nixpkgs or add overlays.
            '';
          };

          terraform = mkOption {
            type = types.package;
            default =
              let
                pkgsWithTerraform = import inputs.nixpkgs {
                  inherit system;
                  config.allowUnfreePredicate =
                    pkg:
                    builtins.elem (config.oracle-cloud-nixos.pkgs.lib.getName pkg) [
                      "terraform"
                    ];
                };
              in
              pkgsWithTerraform.terraform;
            defaultText = lib.literalExpression "pkgs.terraform (with allowUnfree)";
            description = ''
              The terraform package to use in the devShell.
              Override this to use a specific terraform version.
            '';
          };

          extraDevShellPackages = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = ''
              Additional packages to include in the devShell.
            '';
          };

          ociImage = {
            hostname = mkOption {
              type = types.str;
              default = "nixos-oci";
              description = "Hostname for the NixOS OCI image";
            };

            stateVersion = mkOption {
              type = types.str;
              default = "25.11";
              description = "NixOS state version for the OCI image";
            };

            extraModules = mkOption {
              type = types.listOf types.deferredModule;
              default = [ ];
              description = ''
                Additional NixOS modules to include in the OCI base image.
              '';
            };
          };
        };
      }
    );
  };

  config = {
    # Export this module for downstream flakes to import
    flake.flakeModule = {
      imports = [ ./flake-module.nix ];
    };

    perSystem =
      { config, system, ... }:
      let
        cfg = config.oracle-cloud-nixos;
        pkgs = cfg.pkgs;

        # Wrapper so terraform always targets the terraform/ directory
        terraformWrapper = pkgs.writeShellScriptBin "terraform" ''
          if [ -z "$FLAKE_ROOT" ]; then
            echo "error: FLAKE_ROOT not set. Are you in the devShell?" >&2
            exit 1
          fi
          exec ${cfg.terraform}/bin/terraform -chdir="$FLAKE_ROOT/terraform" "$@"
        '';

        # Helper function to build OCI image for a given target system
        # Can use cross-compilation when targetSystem differs from system
        mkOciImage =
          targetSystem:
          let
            nixos = inputs.nixpkgs.lib.nixosSystem {
              system = targetSystem;
              modules = [
                # OCI image module from nixpkgs (includes fetch-ssh-keys service)
                "${inputs.nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
                "${inputs.nixpkgs}/nixos/modules/virtualisation/oci-options.nix"
                # OCI hardware support (iSCSI boot, network drivers)
                ./modules/oci-hardware.nix
                (
                  { lib, pkgs, ... }:
                  {
                    system.stateVersion = cfg.ociImage.stateVersion;
                    networking.hostName = cfg.ociImage.hostname;

                    # Disable documentation to reduce image size
                    documentation.enable = false;

                    # Enable flakes and nix-command
                    nix.settings.experimental-features = [
                      "nix-command"
                      "flakes"
                    ];

                    # Minimal packages for administration
                    environment.systemPackages = with pkgs; [
                      vim
                      git
                      htop
                    ];
                  }
                )
              ]
              ++ cfg.ociImage.extraModules;
            };
          in
          nixos.config.system.build.OCIImage;
      in
      {
        packages = {
          # Cleanup old OCI custom images (keep max 3)
          cleanup-images = pkgs.writeShellApplication {
            name = "cleanup-images";
            runtimeInputs = with pkgs; [
              oci-cli
              jq
              coreutils
            ];
            text = builtins.readFile ./scripts/cleanup-images.sh;
          };

          # Generic OCI base image - vanilla NixOS with OCI hardware support
          # Build for the target architecture matching the perSystem's system
          # (aarch64-linux builds ARM image, x86_64-linux builds x86 image)
          oci-base-image = mkOciImage system;
        }
        # Cross-compiled image: build for the opposite architecture
        # On x86_64-linux: provides oci-base-image-aarch64-cross (ARM)
        # On aarch64-linux: provides oci-base-image-x86_64-cross (x86)
        // lib.optionalAttrs (system == "x86_64-linux") {
          oci-base-image-aarch64-cross = mkOciImage "aarch64-linux";
        }
        // lib.optionalAttrs (system == "aarch64-linux") {
          oci-base-image-x86_64-cross = mkOciImage "x86_64-linux";
        };

        apps.cleanup-images = {
          type = "app";
          program = "${config.packages.cleanup-images}/bin/cleanup-images";
        };

        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              direnv
              oci-cli
              openssl
              terraformWrapper
            ]
            ++ cfg.extraDevShellPackages;

          shellHook = ''
            # Source .env file if it exists (for TF_VAR_* variables)
            if [ -f .env ]; then
              set -a
              source .env
              set +a
            fi
          '';
        };
      };
  };
}
