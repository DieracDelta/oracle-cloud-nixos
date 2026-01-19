# NixOS instances on OCI (Free Tier)
resource "oci_core_instance" "nixos" {
  for_each = var.instances

  # Ensure shape compatibility is set before launching (only if we created a new image)
  depends_on = [oci_core_shape_management.nixos]

  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
  display_name        = each.key
  shape               = local.arch_to_shape[each.value.arch]

  # Only ARM (VM.Standard.A1.Flex) supports flexible shape config
  # x86 micro (VM.Standard.E2.1.Micro) has fixed 1 OCPU, 1 GB RAM
  dynamic "shape_config" {
    for_each = each.value.arch == "arm" ? [1] : []
    content {
      ocpus         = each.value.ocpus
      memory_in_gbs = each.value.memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_ids[each.value.arch]
    boot_volume_size_in_gbs = each.value.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.nixos.id
    display_name     = "${each.key}-vnic"
    assign_public_ip = true
    # OCI hostname labels can't have hyphens, so replace them
    hostname_label = replace(each.key, "-", "")
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}
