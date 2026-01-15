{
  description = "NixOS on Oracle Cloud Infrastructure - Free Tier ARM deployment";

  inputs = {
    # Using nixpkgs master. Note: PR #480105 adds oci.copyChannel option which
    # can reduce image size by ~300-400MB when merged. Once merged, you can
    # enable it in oci-hardware.nix to skip copying the nixpkgs channel.
    nixpkgs.url = "github:nixos/nixpkgs/master";

    flake-parts.url = "github:hercules-ci/flake-parts";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        ./flake-module.nix
      ];

      # treefmt configuration
      perSystem =
        { config, pkgs, ... }:
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              # Nix formatter
              nixfmt.enable = true;
              # Terraform formatter
              terraform.enable = true;
            };
          };
        };

      flake = {
        # Reusable NixOS module for OCI ARM hardware support
        nixosModules.oci-hardware = ./modules/oci-hardware.nix;
      };
    };
}
