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

# Oracle Cloud Free Tier ARM (Ampere A1):
# - Up to 4 OCPUs and 24 GB RAM total
# - Can be one VM or split across multiple
variable "instance_ocpus" {
  type        = number
  description = "Number of OCPUs for the instance"
  default     = 4
}

variable "instance_memory_gb" {
  type        = number
  description = "Memory in GB for the instance"
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
