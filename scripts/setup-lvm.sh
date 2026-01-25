#!/usr/bin/env bash
#
# First-boot LVM setup script for NixOS on OCI
#
# This script sets up LVM to combine the boot volume's LVM partition
# with the attached block volume into a single volume group.
#
# Prerequisites:
# - Boot volume partitioned with efi+lvm layout (partition 3 is LVM PV)
# - Block volume attached as paravirtualized device
# - LVM tools installed (included in the NixOS image)
#
# Usage:
#   sudo ./setup-lvm.sh
#
# After running this script, update your NixOS configuration to mount
# the LVM volumes and run `nixos-rebuild switch`.

set -euo pipefail

# Configuration
BOOT_LVM_PART="/dev/sda3"      # Third partition on boot volume (LVM PV)
BLOCK_VOL="/dev/sdb"           # Block volume (whole disk)
VG_NAME="datavg"               # Volume group name
LV_NAME="datalv"               # Logical volume name
FS_LABEL="nixos-data"          # Btrfs filesystem label

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Show current block devices
log_info "Current block devices:"
lsblk
echo

# Check if devices exist
if [[ ! -b "$BOOT_LVM_PART" ]]; then
    log_error "Boot volume LVM partition not found: $BOOT_LVM_PART"
    log_error "Make sure you're using the efi+lvm partition layout"
    exit 1
fi

if [[ ! -b "$BLOCK_VOL" ]]; then
    log_error "Block volume not found: $BLOCK_VOL"
    log_error "Make sure the block volume is attached via terraform"
    exit 1
fi

# Check if VG already exists
if vgs "$VG_NAME" &>/dev/null; then
    log_warn "Volume group '$VG_NAME' already exists"
    log_info "Current VG status:"
    vgs "$VG_NAME"
    lvs "$VG_NAME"
    echo
    read -p "Do you want to skip LVM setup and just show status? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        exit 0
    fi
    log_warn "Proceeding will destroy existing data in the VG!"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    # Remove existing VG
    log_info "Removing existing volume group..."
    lvremove -f "$VG_NAME" || true
    vgremove -f "$VG_NAME" || true
    pvremove -f "$BOOT_LVM_PART" || true
    pvremove -f "$BLOCK_VOL" || true
fi

# Create LVM physical volumes
log_info "Creating LVM physical volumes..."
pvcreate -f "$BOOT_LVM_PART"
pvcreate -f "$BLOCK_VOL"

# Show PV status
log_info "Physical volumes created:"
pvs

# Create volume group spanning both PVs
log_info "Creating volume group '$VG_NAME'..."
vgcreate "$VG_NAME" "$BOOT_LVM_PART" "$BLOCK_VOL"

# Show VG status
log_info "Volume group created:"
vgs "$VG_NAME"

# Create logical volume using all available space
log_info "Creating logical volume '$LV_NAME'..."
lvcreate -l 100%FREE -n "$LV_NAME" "$VG_NAME"

# Show LV status
log_info "Logical volume created:"
lvs "$VG_NAME"

# Format as btrfs
log_info "Formatting as btrfs..."
mkfs.btrfs -L "$FS_LABEL" "/dev/$VG_NAME/$LV_NAME"

# Create btrfs subvolumes
log_info "Creating btrfs subvolumes..."
MOUNT_POINT=$(mktemp -d)
mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"

btrfs subvolume create "$MOUNT_POINT/@nix"
btrfs subvolume create "$MOUNT_POINT/@home"

log_info "Subvolumes created:"
btrfs subvolume list "$MOUNT_POINT"

umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

# Show final status
echo
log_info "=========================================="
log_info "LVM setup complete!"
log_info "=========================================="
echo
log_info "Summary:"
echo "  Volume Group: $VG_NAME"
echo "  Logical Volume: /dev/$VG_NAME/$LV_NAME"
echo "  Filesystem: btrfs (label: $FS_LABEL)"
echo "  Subvolumes: @nix, @home"
echo
log_info "Total space available:"
vgs "$VG_NAME" --units g

echo
log_info "Next steps:"
echo "1. Backup current /nix contents if needed"
echo "2. Add the following to your NixOS configuration:"
echo
cat << 'EOF'
  fileSystems."/nix" = {
    device = "/dev/datavg/datalv";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" ];
  };

  fileSystems."/home" = {
    device = "/dev/datavg/datalv";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "noatime" ];
  };
EOF
echo
echo "3. Run: nixos-rebuild switch"
echo "4. Reboot and verify mounts"
