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

variable "network_name" {
  type        = string
  description = "Base name for network resources (VCN, subnet, etc.)"
  default     = "nixos-cluster"
}

# Oracle Cloud Free Tier limits:
#
# ARM (Ampere A1) - VM.Standard.A1.Flex:
#   - Up to 4 OCPUs and 24 GB RAM total (can be split across instances)
#   - Flexible shape: configurable OCPU/RAM
#
# x86 (AMD) - VM.Standard.E2.1.Micro:
#   - Up to 2 instances
#   - Fixed: 1 OCPU and 1 GB RAM each
#
# Boot Volumes: Up to 200 GB total across all instances
#
variable "instances" {
  type = map(object({
    arch           = string
    ocpus          = optional(number, 4)
    memory_gb      = optional(number, 24)
    boot_volume_gb = optional(number, 50)
  }))
  description = "Map of instance configurations. Key is instance name."

  default = {
    "nixos-arm" = { arch = "arm", ocpus = 4, memory_gb = 24, boot_volume_gb = 47 }
  }

  validation {
    condition = alltrue([
      for name, config in var.instances : contains(["arm", "x86"], config.arch)
    ])
    error_message = "All instances must have arch set to 'arm' or 'x86'"
  }

  # Free tier limit: max 2 x86 micro instances
  validation {
    condition = length([for name, config in var.instances : name if config.arch == "x86"]) <= 2
    error_message = "Free tier allows max 2 x86 instances (VM.Standard.E2.1.Micro)"
  }

  # Free tier limit: max 4 OCPUs total for ARM
  validation {
    condition = sum([for name, config in var.instances : config.ocpus if config.arch == "arm"]) <= 4
    error_message = "Free tier allows max 4 OCPUs total for ARM instances"
  }

  # Free tier limit: max 24 GB RAM total for ARM
  validation {
    condition = sum([for name, config in var.instances : config.memory_gb if config.arch == "arm"]) <= 24
    error_message = "Free tier allows max 24 GB RAM total for ARM instances"
  }

  # Free tier limit: max 200 GB boot volume total
  validation {
    condition = sum([for name, config in var.instances : config.boot_volume_gb]) <= 200
    error_message = "Free tier allows max 200 GB total boot volume storage"
  }

  # x86 micro instances have fixed 1 GB RAM - memory_gb should use default (not manually set)
  validation {
    condition = alltrue([
      for name, config in var.instances : config.memory_gb == 24 if config.arch == "x86"
    ])
    error_message = "x86 instances use fixed 1 GB RAM (VM.Standard.E2.1.Micro) - don't set memory_gb"
  }

  # x86 micro instances have fixed 1 OCPU - ocpus should use default (not manually set)
  validation {
    condition = alltrue([
      for name, config in var.instances : config.ocpus == 4 if config.arch == "x86"
    ])
    error_message = "x86 instances use fixed 1 OCPU (VM.Standard.E2.1.Micro) - don't set ocpus"
  }

  # OCI minimum boot volume size is 47 GB
  validation {
    condition = alltrue([
      for name, config in var.instances : config.boot_volume_gb >= 47
    ])
    error_message = "OCI requires minimum 47 GB boot volume size"
  }

  # ARM instances need at least 1 OCPU and 1 GB RAM per OCPU
  validation {
    condition = alltrue([
      for name, config in var.instances : config.ocpus >= 1 && config.memory_gb >= config.ocpus if config.arch == "arm"
    ])
    error_message = "ARM instances need at least 1 OCPU and minimum 1 GB RAM per OCPU"
  }
}

# Image storage management
# Note: OCI free tier includes ~10 GiB of object storage. Each NixOS image is
# approximately 1-2 GiB. If you keep multiple images, you may exceed the free
# tier and incur charges. Set this to true to automatically delete the staging
# bucket/object after the image is imported.
variable "delete_image_after_instance" {
  type        = bool
  description = "Delete the staging bucket/object after image import to save storage"
  default     = true
}
