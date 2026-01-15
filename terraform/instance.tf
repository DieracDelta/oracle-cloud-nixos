# NixOS instance on OCI (Free Tier)
resource "oci_core_instance" "nixos" {
  # Ensure shape compatibility is set before launching (only if we created a new image)
  depends_on = [oci_core_shape_management.nixos]

  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
  display_name        = var.instance_name
  shape               = local.shape_name

  # Only ARM (VM.Standard.A1.Flex) supports flexible shape config
  # x86 micro (VM.Standard.E2.1.Micro) has fixed 1 OCPU, 1 GB RAM
  dynamic "shape_config" {
    for_each = local.is_flexible ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.nixos.id
    display_name     = "${var.instance_name}-vnic"
    assign_public_ip = true
    hostname_label   = var.instance_name
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}
