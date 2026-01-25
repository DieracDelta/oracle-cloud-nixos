# Block Volume for shared LVM storage (Free Tier)
#
# This creates a 100GB block volume with 0 VPUs (Lower Cost tier).
# Combined with the boot volume's LVM partition, this provides ~179GB
# of shared storage for /nix and /home.
#
# Free Tier Limits:
# - Total block storage: 200GB (boot + block combined)
# - VPUs: 0 is valid for block volumes (not boot volumes)
# - Cost: $0 for storage, $0 for VPUs

variable "enable_block_volume" {
  type        = bool
  default     = true
  description = "Enable the additional 100GB block volume for LVM shared storage"
}

variable "block_volume_size_gb" {
  type        = number
  default     = 100
  description = "Size of the block volume in GB (max 100 to stay in free tier with 100GB boot)"
}

# 100GB block volume with 0 VPUs (FREE)
resource "oci_core_volume" "data" {
  count = var.enable_block_volume ? 1 : 0

  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
  display_name        = "nixos-data-volume"
  size_in_gbs         = var.block_volume_size_gb
  vpus_per_gb         = 0  # "Lower Cost" option - FREE (no VPU charges)

  freeform_tags = {
    purpose     = "lvm-shared-storage"
    managed_by  = "terraform"
  }
}

# Attach the block volume to the NixOS instance
# Using paravirtualized attachment (simpler, appears as /dev/sdb)
resource "oci_core_volume_attachment" "data" {
  count = var.enable_block_volume ? 1 : 0

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.nixos["nixos-arm"].id
  volume_id       = oci_core_volume.data[0].id
  display_name    = "nixos-data-attachment"
  is_read_only    = false
  is_shareable    = false

  # Use consistent device path for reliable /etc/fstab entries
  device = "/dev/oracleoci/oraclevdb"
}

# Output the block volume details
output "data_volume_id" {
  value       = var.enable_block_volume ? oci_core_volume.data[0].id : null
  description = "OCID of the data block volume"
}

output "data_volume_device" {
  value       = var.enable_block_volume ? oci_core_volume_attachment.data[0].device : null
  description = "Device path for the block volume (use this in LVM setup)"
}

output "data_volume_iqn" {
  value       = var.enable_block_volume ? oci_core_volume_attachment.data[0].iqn : null
  description = "iSCSI IQN (only relevant for iSCSI attachments, null for paravirtualized)"
}
