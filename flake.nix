{
  description = "NixOS on Oracle Cloud Infrastructure - Free Tier ARM deployment";

  inputs = {
    # Using nixpkgs master with local overlay for virtiofsd patch
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

        # NixOS configuration for remote rebuilds on the deployed VM
        nixosConfigurations.nixos-arm = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${inputs.nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
            "${inputs.nixpkgs}/nixos/modules/virtualisation/oci-options.nix"
            ./modules/oci-hardware.nix
            (
              { pkgs, ... }:
              {
                system.stateVersion = "25.11";
                networking.hostName = "nixos-arm";

                documentation.enable = false;

                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];

                environment.systemPackages = with pkgs; [
                  vim
                  git
                  htop
                ];

                users.users.jrestivo = {
                  isNormalUser = true;
                  extraGroups = [ "wheel" ];
                  openssh.authorizedKeys.keys = [
                    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5qlN93RBt99GVy6YDP3OMb7Yu4zwELvT5kvdTRnPzE9txmdxKiMM8eHGw4vBwcbmwY7y1wa+ijXwiT0PbwDUOQvVu8CzWHxBF0pz8LVy7XsBuQr9UtxXVV6D9KBKJJEQjpKgF0LTGOC3LSdHKqlH/4zUaUpE2ZPOaoS01S8YwNfRbr30XDeilMDD5rY0AVlydKFRZIbf/96fdo4HURKcjRMapTdYrdkj++FINCl4IDOId3UQR7Z8qDmx2IC6rOikMNMGwEFvgueCDHDuieqNfHn9LVv8gzCPZ0QtX5Ap+6FPNiUfBXuG1IK7RzeDicGUSXWfKFQImwo6pppArqvtqizEFY6WDBSso5XTveg3Z/gH5/jfMigElVAh8xob/NAW2lv6lHEjXtFVmk3N2Fz425SfXQp2qyaYOPGYohWt1ZwlMdkHYfYGtskaoUd9XCM3GC+aSSLkMPuaXtLS3aJ9R7jcz4sfXdU0s3Vd+jQl7c9n3lGYlZ59aKruUj50QtAs= jrestivo@jrestivo.local"
                  ];
                };
                security.sudo.wheelNeedsPassword = false;
              }
            )
          ];
        };
      };
    };
}
