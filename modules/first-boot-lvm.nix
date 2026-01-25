# First-boot LVM setup module
#
# This module automatically sets up LVM on first boot when:
# 1. The boot volume has an LVM partition (partition 3)
# 2. A block volume is attached
# 3. LVM is not already configured
#
# After setup, it migrates /nix to the LVM volume and triggers a rebuild.

{ config, lib, pkgs, ... }:

let
  cfg = config.oci.firstBootLVM;

  setupScript = pkgs.writeShellScript "first-boot-lvm-setup" ''
    set -euo pipefail

    # Configuration
    VG_NAME="datavg"
    LV_NAME="datalv"
    FS_LABEL="nixos-data"
    MARKER_FILE="/var/lib/first-boot-lvm-done"

    log() {
      echo "[first-boot-lvm] $1"
      ${pkgs.util-linux}/bin/logger -t first-boot-lvm "$1" 2>/dev/null || true
    }

    # Check if already done
    if [[ -f "$MARKER_FILE" ]]; then
      log "LVM setup already completed (marker file exists)"
      exit 0
    fi

    # Check if VG already exists
    if ${pkgs.lvm2.bin}/bin/vgs "$VG_NAME" &>/dev/null; then
      log "Volume group $VG_NAME already exists, marking as done"
      touch "$MARKER_FILE"
      exit 0
    fi

    # Dynamically detect devices
    # Boot volume: the disk with an ESP partition (partition 1 with type C12A7328-...)
    # Block volume: a disk with no partitions
    log "Detecting devices..."
    BOOT_DISK=""
    BLOCK_VOL=""

    for disk in /dev/sd?; do
      if [[ ! -b "$disk" ]]; then continue; fi

      # Check if disk has partitions
      part_count=$(${pkgs.util-linux}/bin/lsblk -n -o NAME "$disk" | wc -l)

      if [[ $part_count -eq 1 ]]; then
        # No partitions - this is the block volume
        BLOCK_VOL="$disk"
        log "Found block volume: $BLOCK_VOL (no partitions)"
      else
        # Has partitions - check if partition 1 is ESP (boot volume)
        if [[ -b "''${disk}1" ]]; then
          part_type=$(${pkgs.util-linux}/bin/blkid -s PARTUUID -o value "''${disk}1" 2>/dev/null || true)
          # Check if it's the boot disk by looking for the EFI partition label
          if ${pkgs.util-linux}/bin/blkid "''${disk}1" 2>/dev/null | grep -q 'LABEL="ESP"'; then
            BOOT_DISK="$disk"
            log "Found boot disk: $BOOT_DISK (has ESP partition)"
          fi
        fi
      fi
    done

    BOOT_LVM_PART="''${BOOT_DISK}3"

    # Check if boot disk was found
    if [[ -z "$BOOT_DISK" ]]; then
      log "Boot disk not found (no disk with ESP partition), skipping setup"
      exit 0
    fi

    # Check if boot LVM partition exists
    if [[ ! -b "$BOOT_LVM_PART" ]]; then
      log "Boot LVM partition $BOOT_LVM_PART not found, skipping setup"
      exit 0
    fi

    # Check if block volume exists
    if [[ -z "$BLOCK_VOL" ]]; then
      log "Block volume not found, waiting..."
      # Wait up to 60 seconds for block volume
      for i in {1..12}; do
        sleep 5
        for disk in /dev/sd?; do
          if [[ ! -b "$disk" ]]; then continue; fi
          part_count=$(${pkgs.util-linux}/bin/lsblk -n -o NAME "$disk" | wc -l)
          if [[ $part_count -eq 1 ]]; then
            BLOCK_VOL="$disk"
            log "Block volume appeared after $((i * 5)) seconds: $BLOCK_VOL"
            break 2
          fi
        done
      done
      if [[ -z "$BLOCK_VOL" ]]; then
        log "Block volume not found after 60s, skipping LVM setup"
        exit 0
      fi
    fi

    log "Starting LVM setup..."
    log "Boot LVM partition: $BOOT_LVM_PART"
    log "Block volume: $BLOCK_VOL"

    # Grow the boot LVM partition to fill remaining space
    # OCI may expand the boot volume beyond the original image size
    log "Growing boot LVM partition to fill disk..."
    ${pkgs.cloud-utils}/bin/growpart "$BOOT_DISK" 3 || log "growpart: partition already at max size or error"

    # Create physical volumes
    log "Creating physical volumes..."
    ${pkgs.lvm2.bin}/bin/pvcreate -f "$BOOT_LVM_PART"
    ${pkgs.lvm2.bin}/bin/pvcreate -f "$BLOCK_VOL"

    # Create volume group
    log "Creating volume group $VG_NAME..."
    ${pkgs.lvm2.bin}/bin/vgcreate "$VG_NAME" "$BOOT_LVM_PART" "$BLOCK_VOL"

    # Create logical volume
    log "Creating logical volume $LV_NAME..."
    ${pkgs.lvm2.bin}/bin/lvcreate -l 100%FREE -n "$LV_NAME" "$VG_NAME"

    # Format as btrfs
    log "Formatting as btrfs..."
    ${pkgs.btrfs-progs}/bin/mkfs.btrfs -L "$FS_LABEL" "/dev/$VG_NAME/$LV_NAME"

    # Create subvolumes
    log "Creating btrfs subvolumes..."
    MOUNT_POINT=$(mktemp -d)
    ${pkgs.util-linux}/bin/mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"
    ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$MOUNT_POINT/@nix"
    ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$MOUNT_POINT/@home"

    # Migrate /nix data
    log "Migrating /nix to LVM (this may take a while)..."
    ${pkgs.rsync}/bin/rsync -aAX --info=progress2 /nix/ "$MOUNT_POINT/@nix/"

    # Migrate /home data if any
    if [[ -d /home && "$(ls -A /home 2>/dev/null)" ]]; then
      log "Migrating /home to LVM..."
      ${pkgs.rsync}/bin/rsync -aAX --info=progress2 /home/ "$MOUNT_POINT/@home/"
    fi

    ${pkgs.util-linux}/bin/umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"

    # Mark as done
    touch "$MARKER_FILE"

    log "LVM setup complete!"
    log "Volume group: $VG_NAME"
    log "Logical volume: /dev/$VG_NAME/$LV_NAME"
    log ""
    log "IMPORTANT: System needs to be reconfigured to use the new mounts."
    log "Add the following to your NixOS configuration and run nixos-rebuild switch:"
    log ""
    log "  fileSystems.\"/nix\" = {"
    log "    device = \"/dev/datavg/datalv\";"
    log "    fsType = \"btrfs\";"
    log "    options = [ \"subvol=@nix\" \"compress=zstd\" \"noatime\" ];"
    log "  };"
    log ""
    log "  fileSystems.\"/home\" = {"
    log "    device = \"/dev/datavg/datalv\";"
    log "    fsType = \"btrfs\";"
    log "    options = [ \"subvol=@home\" \"compress=zstd\" \"noatime\" ];"
    log "  };"
  '';
in
{
  options.oci.firstBootLVM = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable automatic first-boot LVM setup";
    };

    autoRebuild = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Automatically run nixos-rebuild after LVM setup.
        Requires the system to have a flake configuration.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Systemd service for first-boot LVM setup
    systemd.services.first-boot-lvm = {
      description = "First-boot LVM setup for OCI";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "network.target" ];
      before = [ "nix-daemon.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = setupScript;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };

      # Only run once
      unitConfig = {
        ConditionPathExists = "!/var/lib/first-boot-lvm-done";
      };
    };

    # Ensure required packages are available
    environment.systemPackages = with pkgs; [
      lvm2
      btrfs-progs
      rsync
      cloud-utils  # for growpart
      util-linux   # for logger, lsblk, blkid
    ];
  };
}
