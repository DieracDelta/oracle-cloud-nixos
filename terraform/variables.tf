# OCI Provider configuration
variable "oci_tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID"
}

variable "oci_user_ocid" {
  type        = string
  description = "OCI user OCID"
}

variable "oci_fingerprint" {
  type        = string
  description = "Fingerprint for the OCI API key"
}

variable "oci_private_key_path" {
  type        = string
  description = "Path to OCI API private key (must be absolute path)"
}

variable "oci_region" {
  type        = string
  description = "OCI region (e.g., us-ashburn-1)"
}

variable "compartment_id" {
  type        = string
  description = "OCI compartment OCID (defaults to tenancy OCID for root compartment)"
  default     = null
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for instance access"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to SSH private key for provisioning"
  default     = "~/.ssh/id_ed25519"
}

variable "instance_name" {
  type        = string
  description = "Name for the NixOS instance"
  default     = "nixos-oci"
}

# Oracle Cloud Free Tier offers two instance types:
#
# ARM (Ampere A1) - "arm" (default):
#   - Shape: VM.Standard.A1.Flex
#   - Up to 4 OCPUs and 24 GB RAM total (configurable)
#   - More powerful, recommended for most workloads
#
# x86 (AMD) - "x86":
#   - Shape: VM.Standard.E2.1.Micro
#   - Fixed: 1 OCPU and 1 GB RAM (2 instances allowed)
#   - Very limited, suitable only for lightweight tasks
#
variable "instance_arch" {
  type        = string
  description = "Instance architecture: 'arm' (4 OCPU, 24GB) or 'x86' (1 OCPU, 1GB micro)"
  default     = "arm"

  validation {
    condition     = contains(["arm", "x86"], var.instance_arch)
    error_message = "instance_arch must be 'arm' or 'x86'"
  }
}

# These only apply to ARM instances (VM.Standard.A1.Flex)
# x86 micro instances have fixed 1 OCPU and 1 GB RAM
variable "instance_ocpus" {
  type        = number
  description = "Number of OCPUs for ARM instance (ignored for x86)"
  default     = 4
}

variable "instance_memory_gb" {
  type        = number
  description = "Memory in GB for ARM instance (ignored for x86)"
  default     = 24
}

variable "boot_volume_gb" {
  type        = number
  description = "Boot volume size in GB (free tier: up to 200GB total)"
  default     = 100
}

# Image storage management
# Note: OCI free tier includes ~10 GiB of object storage. Each NixOS image is
# approximately 1-2 GiB. If you keep multiple images, you may exceed the free
# tier and incur charges. Set this to true to automatically delete the staging
# bucket/object after the image is imported.
variable "delete_image_after_instance" {
  type        = bool
  description = "Delete the staging bucket/object after image import to save storage"
  default     = false
}
